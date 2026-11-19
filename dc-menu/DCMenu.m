// DCMenu.m — Dead Cells (Apple Arcade v3.3.15, Playdigious) floating menu
// tweak for LiveContainer. v2.0: clean shell for the Arcade build —
// floating ball + draggable panel + hot-update channel + save recon.
// NO SDK probes, NO network swizzles (the v1.9 crash suspects are gone).
// Feature definitions (title / badge / notice / features) come from a
// remote JSON; updating that JSON changes the menu with no file swap.
// Remote config: https://raw.githubusercontent.com/jiajiababa1/video-db/main/dc-menu/menu.json
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <fcntl.h>
#import <stdio.h>
#import <dlfcn.h>
#import <string.h>
#import <stdarg.h>
#import <sys/types.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <mach/mach.h>

static NSString * const kDCConfigURL = @"https://raw.githubusercontent.com/jiajiababa1/video-db/main/dc-menu/menu.json";
static NSString * const kDCBundledBadge = @"版本 A";
static NSString * const kDCMenuVersion = @"v2.6.2";

#pragma mark - Passthrough window

@interface DCPassWindow : UIWindow
@end

@implementation DCPassWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}
@end

#pragma mark - Menu controller

@interface DCMenu : NSObject
@property (nonatomic, strong) DCPassWindow *window;
@property (nonatomic, strong) UIButton *ball;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *badgeLabel;
@property (nonatomic, strong) UILabel *noticeLabel;
@property (nonatomic, strong) UILabel *featuresLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) NSDictionary *config;
@property (nonatomic, strong) NSMutableArray<NSString *> *events;
@property (nonatomic, assign) BOOL setupDone;
@property (nonatomic, assign) NSInteger retries;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UILabel *> *stepValLabels;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIButton *> *toggleBtns;
@property (nonatomic, strong) UILabel *fileStateLabel;
@property (nonatomic, assign) double aEnemyHealth;
@property (nonatomic, assign) double aEnemyDamage;
@property (nonatomic, assign) double aTrapDamage;
@property (nonatomic, assign) NSInteger aContinue;
@property (nonatomic, assign) BOOL aParry;
@property (nonatomic, assign) BOOL aTrap;
@property (nonatomic, assign) BOOL aMap;
@property (nonatomic, assign) BOOL aHeal;
@property (nonatomic, assign) BOOL aDoors;
@property (nonatomic, assign) BOOL aSlow;
+ (instancetype)shared;
- (void)setup;
- (void)fetchConfig;
- (void)logEvent:(NSString *)text;
- (void)runRecon;
- (void)runLiveRecon;
- (void)applyAssistBoost;
- (void)restoreAssist;
- (void)loadAssistPrefs;
- (void)saveAssistPrefs;
- (void)refreshAssistUI;
- (void)refreshFileState;
- (void)addStepper:(UIView *)panel x:(CGFloat)x y:(CGFloat)y name:(NSString *)name key:(NSString *)key idx:(NSInteger)idx;
- (void)notePakPath:(NSString *)path;
@end

#pragma mark - Live recon (HashLink runtime, read-only probe)

// Static layout of the game's HashLink tables (verified offline against
// the Arcade binary; VAs assume preferred base 0x100000000):
//   hl_type     : 32B { i32 kind; void *obj @+8; ... }   kind 11 = HOBJ
//   hl_type_obj : { i32 nfields @0; i32 nproto @4; name @+16; super @+24;
//                   fields @+32; proto @+40; rt @+72 }
//   hl_obj_field: 24B { uchar *name; hl_type *t; i32 hash }
// Object layout follows hl_get_obj_rt: parent fields first, each field
// aligned to its natural alignment, offsets from object start (incl.
// the 8-byte type header).

static const int DC_TSIZES[24] = {0,1,2,4,8,4,8,1,8,8,8,8,8,8,8,8,8,8,8,8,8,8,0,8};
static int dc_align_of(int kind) {
    switch (kind) {
        case 1: case 7: return 1;
        case 2: return 2;
        case 3: case 5: return 4;
        default: return 8;
    }
}

static uintptr_t dc_g_slide = 0;
static uintptr_t dc_g_textLo = 0, dc_g_textHi = 0;
static uintptr_t dc_g_typesLo = 0, dc_g_typesHi = 0;
static NSMutableArray<NSValue *> *dc_g_dataSpans = nil; // {ptr,len} pairs

static BOOL dc_readable(uintptr_t addr, size_t n) {
    vm_address_t a = (vm_address_t)addr;
    vm_size_t sz = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj;
    kern_return_t kr = vm_region_64(mach_task_self(), &a, &sz, VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_t)&info, &cnt, &obj);
    if (kr != KERN_SUCCESS) return NO;
    BOOL ok = addr >= a && addr + n <= a + sz && (info.protection & VM_PROT_READ);
    if (obj != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), obj);
    return ok;
}

// Mapped readable regions of this task, collected once (fast in-memory
// checks afterwards; no per-candidate mach calls, no port leaks).
#define DC_MAX_REGIONS 16384
static uintptr_t dc_g_regions[DC_MAX_REGIONS][2];
static NSInteger dc_g_nregions = 0;

static void dc_build_regions(void) {
    if (dc_g_nregions) return;
    vm_address_t addr = 0;
    while (dc_g_nregions < DC_MAX_REGIONS) {
        vm_size_t sz = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        kern_return_t kr = vm_region_64(mach_task_self(), &addr, &sz, VM_REGION_BASIC_INFO_64,
                                        (vm_region_info_t)&info, &cnt, &obj);
        if (kr != KERN_SUCCESS) break;
        if (obj != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), obj);
        if (sz == 0) break;
        if (info.protection & VM_PROT_READ) {
            dc_g_regions[dc_g_nregions][0] = addr;
            dc_g_regions[dc_g_nregions][1] = addr + sz;
            dc_g_nregions++;
        }
        addr += sz;
    }
}

static BOOL dc_readable2(uintptr_t addr, size_t n) {
    for (NSInteger i = 0; i < dc_g_nregions; i++) {
        if (addr >= dc_g_regions[i][0] && addr + n <= dc_g_regions[i][1]) return YES;
    }
    return NO;
}

// Allocation-free dedupe set for scan candidates (open addressing).
#define DC_SEEN_BITS 19
#define DC_SEEN_SIZE (1 << DC_SEEN_BITS)
#define DC_SEEN_MASK (DC_SEEN_SIZE - 1)
static uintptr_t dc_seen_table[DC_SEEN_SIZE];

static BOOL dc_seen_add(uintptr_t v) {
    size_t h = (size_t)((v >> 3) & DC_SEEN_MASK);
    while (dc_seen_table[h]) {
        if (dc_seen_table[h] == v) return NO;
        h = (h + 1) & DC_SEEN_MASK;
    }
    dc_seen_table[h] = v;
    return YES;
}

static BOOL dc_in_spans(uintptr_t addr, size_t n) {
    for (NSDictionary *span in dc_g_dataSpans) {
        uintptr_t lo = (uintptr_t)[span[@"ptr"] pointerValue];
        uintptr_t hi = lo + [span[@"len"] unsignedLongValue];
        if (addr >= lo && addr + n <= hi) return YES;
    }
    return NO;
}

static NSString *dc_stage_path(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/dcmenu_stage.log"];
}

static void dc_stage(NSString *s) {
    NSString *line = [s stringByAppendingString:@"\n"];
    NSData *bytes = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:dc_stage_path()];
    if (!fh) {
        [bytes writeToFile:dc_stage_path() atomically:YES];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:bytes];
    [fh closeFile];
}

static NSString *dc_u16str(uintptr_t addr) {
    if (addr < dc_g_textLo || addr >= dc_g_textHi) return nil;
    NSInteger maxN = (NSInteger)((dc_g_textHi - addr) / 2);
    if (maxN > 100) maxN = 100;
    const uint16_t *p = (const uint16_t *)addr;
    uint16_t buf[101];
    NSInteger n = 0;
    for (NSInteger i = 0; i < maxN; i++) {
        uint16_t c = p[i];
        if (c == 0) break;
        if (c < 0x21 || c > 0x7E) return nil; // printable, no spaces
        buf[n++] = c;
    }
    if (n == 0) return nil;
    return [[NSString alloc] initWithBytes:buf length:(NSUInteger)(n * 2)
                                  encoding:NSUTF16LittleEndianStringEncoding];
}

@interface DCLayout : NSObject
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *offsets;
@property (nonatomic, assign) NSInteger size;
@property (nonatomic, assign) NSInteger padSize;
@property (nonatomic, assign) NSInteger largest;
@end
@implementation DCLayout
@end

@interface DCClassInfo : NSObject
@property (nonatomic, strong) NSString *name;
@property (nonatomic, assign) uintptr_t objBase;
@property (nonatomic, assign) uintptr_t typeAddr;
@property (nonatomic, assign) uintptr_t fields;
@property (nonatomic, assign) NSInteger nfields;
@property (nonatomic, assign) uintptr_t superType;
@property (nonatomic, strong) DCLayout *layout;
@property (nonatomic, assign) BOOL layoutBusy;
@end
@implementation DCClassInfo
@end

static NSMutableDictionary<NSString *, DCClassInfo *> *dc_g_classes = nil;
static NSMutableDictionary<NSNumber *, DCClassInfo *> *dc_g_byType = nil;

static DCClassInfo *dc_class_for_type(uintptr_t type) {
    if (!type) return nil;
    DCClassInfo *ci = dc_g_byType[@(type)];
    if (ci) return ci;
    if (type < dc_g_typesLo || type >= dc_g_typesHi) return nil;
    if (*(const int *)type != 11) return nil;
    uintptr_t obj = *(const uintptr_t *)(type + 8);
    if (!obj || !dc_in_spans(obj, 80)) return nil;
    NSString *nm = dc_u16str(*(const uintptr_t *)(obj + 16));
    if (!nm) return nil;
    ci = dc_g_classes[nm];
    if (ci) {
        if (!ci.typeAddr) ci.typeAddr = type;
        dc_g_byType[@(type)] = ci;
    }
    return ci;
}

static DCLayout *dc_layout_rec(DCClassInfo *ci) {
    if (ci.layout) return ci.layout;
    if (ci.layoutBusy) return nil;
    ci.layoutBusy = YES;
    DCLayout *lay = [[DCLayout alloc] init];
    lay.offsets = [NSMutableDictionary dictionary];
    NSInteger size = 8, largest = 8;
    if (ci.superType) {
        DCClassInfo *sup = dc_class_for_type(ci.superType);
        DCLayout *pl = sup ? dc_layout_rec(sup) : nil;
        if (pl) {
            [lay.offsets addEntriesFromDictionary:pl.offsets];
            size = pl.size - pl.padSize;
            largest = pl.largest;
        }
    }
    const uintptr_t *recs = (const uintptr_t *)ci.fields;
    for (NSInteger k = 0; k < ci.nfields; k++) {
        uintptr_t namePtr = recs[k * 3];
        uintptr_t t = recs[k * 3 + 1];
        if (!t || t < dc_g_typesLo || t >= dc_g_typesHi) continue;
        NSString *fname = dc_u16str(namePtr);
        if (!fname) continue;
        int kind = *(const int *)t;
        if (kind == 22) { // HPACKED: inline sub-struct
            uintptr_t tparam = *(const uintptr_t *)(t + 8);
            DCClassInfo *sub = dc_class_for_type(tparam);
            DCLayout *sl = sub ? dc_layout_rec(sub) : nil;
            NSInteger large = sl ? sl.largest : 8;
            NSInteger pad = size % large;
            if (pad) size += large - pad;
            if (large > largest) largest = large;
            lay.offsets[fname] = @(size);
            size += sl ? sl.size : 0;
            continue;
        }
        NSInteger al = dc_align_of(kind);
        size += (-size) & (al - 1);
        lay.offsets[fname] = @(size);
        NSInteger sz = (kind >= 0 && kind < 24) ? DC_TSIZES[kind] : 8;
        size += sz;
        if (sz > largest) largest = sz;
    }
    NSInteger padSize = 0;
    if (largest > 0) {
        NSInteger pad = size % largest;
        if (pad) { padSize = largest - pad; size += padSize; }
    }
    lay.size = size; lay.padSize = padSize; lay.largest = largest;
    ci.layout = lay;
    ci.layoutBusy = NO;
    return lay;
}

// Find the game image, set up ranges, build the static class registry.
static BOOL dc_live_init(DCMenu *menu) {
    if (dc_g_classes) return YES;
    const struct mach_header_64 *hdr = NULL;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (nm && strstr(nm, "DeadCells")) {
            hdr = (const struct mach_header_64 *)_dyld_get_image_header(i);
            dc_g_slide = (uintptr_t)_dyld_get_image_vmaddr_slide(i);
            break;
        }
    }
    if (!hdr) { [menu logEvent:@"实时侦查：没找到游戏镜像"]; return NO; }
    unsigned long sz = 0;
    const uint8_t *text = getsegmentdata(hdr, "__TEXT", &sz);
    if (text) { dc_g_textLo = (uintptr_t)text; dc_g_textHi = dc_g_textLo + sz; }
    dc_g_dataSpans = [NSMutableArray array];
    const uint8_t *data = getsegmentdata(hdr, "__DATA", &sz);
    if (data) [dc_g_dataSpans addObject:@{@"ptr": [NSValue valueWithPointer:data], @"len": @(sz)}];
    const uint8_t *dcon = getsegmentdata(hdr, "__DATA_CONST", &sz);
    if (dcon) [dc_g_dataSpans addObject:@{@"ptr": [NSValue valueWithPointer:dcon], @"len": @(sz)}];
    dc_g_typesLo = dc_g_slide + 0x101d26360;
    dc_g_typesHi = dc_g_slide + 0x101e59f50;
    dc_g_classes = [NSMutableDictionary dictionary];
    dc_g_byType = [NSMutableDictionary dictionary];
    for (NSDictionary *span in dc_g_dataSpans) {
        uintptr_t lo = (uintptr_t)[span[@"ptr"] pointerValue];
        uintptr_t hi = lo + [span[@"len"] unsignedLongValue];
        for (uintptr_t b = lo; b + 80 <= hi; b += 8) {
            const int *ip = (const int *)b;
            NSInteger nf = ip[0], np = ip[1];
            if (nf < 1 || nf > 1500 || np < 0 || np > 2000) continue;
            uintptr_t namePtr = *(const uintptr_t *)(b + 16);
            uintptr_t sup = *(const uintptr_t *)(b + 24);
            uintptr_t fields = *(const uintptr_t *)(b + 32);
            uintptr_t proto = *(const uintptr_t *)(b + 40);
            if (!fields || proto != fields + (uintptr_t)nf * 24) continue;
            if (!dc_in_spans(fields, (size_t)nf * 24)) continue;
            if (sup && (sup < dc_g_typesLo || sup >= dc_g_typesHi)) continue;
            NSString *nm = dc_u16str(namePtr);
            if (!nm || [nm containsString:@"/"] || [nm hasSuffix:@".hx"]) continue;
            uintptr_t fn = *(const uintptr_t *)fields;
            uintptr_t ft = *(const uintptr_t *)(fields + 8);
            if (!dc_u16str(fn)) continue;
            if (ft < dc_g_typesLo || ft >= dc_g_typesHi) continue;
            DCClassInfo *ci = [[DCClassInfo alloc] init];
            ci.name = nm; ci.objBase = b; ci.fields = fields;
            ci.nfields = nf; ci.superType = sup;
            if (!dc_g_classes[nm]) dc_g_classes[nm] = ci;
        }
    }
    // Wire types: scan the types window for qwords pointing at an obj base
    // (the obj pointer lives at hl_type + 8 once the game has wired it).
    NSMutableDictionary<NSNumber *, DCClassInfo *> *byObj = [NSMutableDictionary dictionary];
    for (DCClassInfo *ci in dc_g_classes.allValues) byObj[@(ci.objBase)] = ci;
    const uintptr_t *tp = (const uintptr_t *)dc_g_typesLo;
    const uintptr_t *tend = (const uintptr_t *)dc_g_typesHi;
    for (const uintptr_t *p = tp; p < tend; p++) {
        DCClassInfo *ci = byObj[@(*p)];
        if (ci && !ci.typeAddr) {
            uintptr_t t = (uintptr_t)p - 8;
            if (*(const int *)t == 11) { ci.typeAddr = t; dc_g_byType[@(t)] = ci; }
        }
    }
    dc_stage([NSString stringWithFormat:@"阶段：类登记完成 %lu 个", (unsigned long)dc_g_classes.count]);
    [menu logEvent:[NSString stringWithFormat:@"实时侦查：类登记 %lu 个，slide 0x%lx",
                    (unsigned long)dc_g_classes.count, (unsigned long)dc_g_slide]];
    return YES;
}


@implementation DCMenu

+ (instancetype)shared {
    static DCMenu *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[DCMenu alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _events = [NSMutableArray array];
        _stepValLabels = [NSMutableDictionary dictionary];
        _toggleBtns = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark Logging (state mutation serialized; render on main thread)

- (void)logEvent:(NSString *)text {
    if (!text) return;
    NSString *line;
    @synchronized (self) {
        NSDateFormatter *f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"HH:mm:ss";
        line = [NSString stringWithFormat:@"%@ %@", [f stringFromDate:[NSDate date]], text];
        [self.events addObject:line];
        while (self.events.count > 150) [self.events removeObjectAtIndex:0];
    }
    dispatch_async(dispatch_get_main_queue(), ^{ [self renderLog]; });
}

- (void)renderLog {
    if (!self.logView) return;
    NSArray *snapshot;
    @synchronized (self) { snapshot = [self.events copy]; }
    self.logView.text = [snapshot componentsJoinedByString:@"\n"];
    if (self.logView.text.length > 0) {
        [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length - 1, 1)];
    }
}

#pragma mark Setup

- (void)setup {
    if (self.setupDone) return;
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *key = nil;
    for (UIScene *scene in app.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { key = w; break; }
            }
            if (!key && ((UIWindowScene *)scene).windows.count) key = ((UIWindowScene *)scene).windows.firstObject;
        }
        if (key) break;
    }
    if (!key) {
        if (++self.retries <= 30) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self setup]; });
        }
        return;
    }
    self.setupDone = YES;

    UIWindowScene *ws = key.windowScene;
    DCPassWindow *win = ws ? [[DCPassWindow alloc] initWithWindowScene:ws]
                           : [[DCPassWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    win.frame = [UIScreen mainScreen].bounds;
    win.windowLevel = UIWindowLevelAlert + 100;
    win.backgroundColor = [UIColor clearColor];
    win.rootViewController = [[UIViewController alloc] init];
    win.rootViewController.view.backgroundColor = [UIColor clearColor];
    win.hidden = NO;
    self.window = win;
    UIView *root = win.rootViewController.view;

    // Floating ball (draggable)
    UIButton *ball = [UIButton buttonWithType:UIButtonTypeCustom];
    CGRect scr = [UIScreen mainScreen].bounds;
    ball.frame = CGRectMake(scr.size.width - 66, scr.size.height * 0.4, 56, 56);
    ball.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.9];
    ball.layer.cornerRadius = 28;
    [ball setTitle:@"菜单" forState:UIControlStateNormal];
    [ball setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    ball.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [ball addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [ball addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragBall:)]];
    [root addSubview:ball];
    self.ball = ball;

    [self buildPanel:root];

    NSBundle *mb = [NSBundle mainBundle];
    [self logEvent:[NSString stringWithFormat:@"菜单 %@ 已加载", kDCMenuVersion]];
    NSString *prevStage = [NSString stringWithContentsOfFile:dc_stage_path()
                                                    encoding:NSUTF8StringEncoding error:nil];
    if (prevStage.length) {
        [self logEvent:[NSString stringWithFormat:@"上次侦查阶段记录（死在哪看最后行）：\n%@",
                        [prevStage stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]]]];
    }
    [self logEvent:[NSString stringWithFormat:@"目标：%@ %@",
                    mb.bundleIdentifier ?: @"?",
                    [mb objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?"]];
    [self fetchConfig];
}

- (void)buildPanel:(UIView *)root {
    // Fit inside the actual screen (the game runs landscape: ~932x430pt).
    // The old fixed 340x470 panel overflowed the 430pt height and pushed
    // the bottom buttons off-screen.
    CGRect sb = [UIScreen mainScreen].bounds;
    CGFloat pw = MIN(620.0, sb.size.width - 24);
    CGFloat ph = MIN(392.0, sb.size.height - 16);
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake((sb.size.width - pw) / 2, (sb.size.height - ph) / 2, pw, ph)];
    panel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.88];
    panel.layer.cornerRadius = 14;
    panel.hidden = YES;
    [panel addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragPanel:)]];
    [root addSubview:panel];
    self.panel = panel;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, pw - 200, 22)];
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:15];
    title.text = @"重生细胞 · 悬浮菜单";
    [panel addSubview:title];
    self.titleLabel = title;

    UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(pw - 176, 4, 160, 30)];
    badge.textColor = [UIColor systemYellowColor];
    badge.font = [UIFont boldSystemFontOfSize:22];
    badge.textAlignment = NSTextAlignmentRight;
    badge.text = kDCBundledBadge;
    [panel addSubview:badge];
    self.badgeLabel = badge;

    UILabel *notice = [[UILabel alloc] initWithFrame:CGRectMake(16, 36, pw - 32, 28)];
    notice.textColor = [UIColor lightGrayColor];
    notice.font = [UIFont systemFontOfSize:11];
    notice.numberOfLines = 2;
    notice.text = @"正在连接热更新通道…";
    [panel addSubview:notice];
    self.noticeLabel = notice;

    UILabel *features = [[UILabel alloc] initWithFrame:CGRectMake(16, 64, pw - 32, 26)];
    features.textColor = [UIColor systemGreenColor];
    features.font = [UIFont systemFontOfSize:11];
    features.numberOfLines = 2;
    [panel addSubview:features];
    self.featuresLabel = features;

    UILabel *status = [[UILabel alloc] initWithFrame:CGRectMake(16, 90, pw - 32, 16)];
    status.textColor = [UIColor systemCyanColor];
    status.font = [UIFont systemFontOfSize:11];
    status.text = @"通道：未连接";
    [panel addSubview:status];
    self.statusLabel = status;

    // --- Custom assist section (v2.5): steppers + toggles, values persist
    // in NSUserDefaults and are written into dc_options.json on apply. ---
    UILabel *aTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, 108, pw - 32, 14)];
    aTitle.textColor = [UIColor whiteColor];
    aTitle.font = [UIFont boldSystemFontOfSize:11];
    aTitle.text = @"辅助自定义（调好点「应用辅助」，重启游戏生效）";
    [panel addSubview:aTitle];

    UILabel *fstate = [[UILabel alloc] initWithFrame:CGRectMake(16, 123, pw - 32, 14)];
    fstate.textColor = [UIColor systemCyanColor];
    fstate.font = [UIFont systemFontOfSize:10];
    fstate.text = @"文件当前：…";
    [panel addSubview:fstate];
    self.fileStateLabel = fstate;

    [self addStepper:panel x:16 y:141 name:@"敌血" key:@"enemyHealth" idx:0];
    [self addStepper:panel x:16 + (pw - 32) / 2 y:141 name:@"敌攻" key:@"enemyDamage" idx:1];
    [self addStepper:panel x:16 y:167 name:@"陷阱" key:@"trapDamage" idx:2];
    [self addStepper:panel x:16 + (pw - 32) / 2 y:167 name:@"续命" key:@"gameContinue" idx:3];

    NSArray *togs = @[@[@"弹反", @"parry"], @[@"易陷阱", @"trap"], @[@"全图", @"map"],
                      @[@"回血", @"heal"], @[@"破门", @"doors"], @[@"减速", @"slow"]];
    CGFloat tw = (pw - 32 - 5 * 6) / 6;
    for (NSInteger i = 0; i < 6; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(16 + i * (tw + 6), 195, tw, 24);
        b.layer.cornerRadius = 6;
        b.titleLabel.font = [UIFont systemFontOfSize:11];
        b.tag = 200 + i;
        [b addTarget:self action:@selector(onToggle:) forControlEvents:UIControlEventTouchUpInside];
        [panel addSubview:b];
        self.toggleBtns[togs[i][1]] = b;
        [b setTitle:togs[i][0] forState:UIControlStateNormal];
    }

    UITextView *log = [[UITextView alloc] initWithFrame:CGRectMake(12, 226, pw - 24, ph - 226 - 52)];
    log.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    log.textColor = [UIColor whiteColor];
    log.font = [UIFont systemFontOfSize:10];
    log.editable = NO;
    log.layer.cornerRadius = 8;
    [panel addSubview:log];
    self.logView = log;

    NSArray *btns = @[@[@"检查更新", @"onCheckUpdate"], @[@"存档侦查", @"onRecon"], @[@"实时侦查", @"onLiveRecon"], @[@"应用辅助", @"onApplyAssist"], @[@"恢复辅助", @"onRestoreAssist"], @[@"关闭", @"togglePanel"]];
    CGFloat bw = (pw - 32 - 40) / 6;
    for (NSInteger i = 0; i < 6; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(16 + i * (bw + 8), ph - 44, bw, 34);
        b.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
        b.layer.cornerRadius = 8;
        [b setTitle:btns[i][0] forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:13];
        [b addTarget:self action:NSSelectorFromString(btns[i][1]) forControlEvents:UIControlEventTouchUpInside];
        b.titleLabel.font = [UIFont systemFontOfSize:12];
        [panel addSubview:b];
    }
}

- (void)onLiveRecon { [self runLiveRecon]; }

#pragma mark UI actions

- (void)togglePanel {
    self.panel.hidden = !self.panel.hidden;
    if (!self.panel.hidden) {
        [self renderLog];
        [self refreshAssistUI];
        [self refreshFileState];
    }
}

- (void)addStepper:(UIView *)panel x:(CGFloat)x y:(CGFloat)y name:(NSString *)name key:(NSString *)key idx:(NSInteger)idx {
    UILabel *n = [[UILabel alloc] initWithFrame:CGRectMake(x, y, 34, 24)];
    n.textColor = [UIColor whiteColor];
    n.font = [UIFont systemFontOfSize:12];
    n.text = name;
    [panel addSubview:n];
    UIButton *minus = [UIButton buttonWithType:UIButtonTypeSystem];
    minus.frame = CGRectMake(x + 36, y, 30, 24);
    minus.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    minus.layer.cornerRadius = 6;
    [minus setTitle:@"−" forState:UIControlStateNormal];
    [minus setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    minus.tag = 100 + idx * 2;
    [minus addTarget:self action:@selector(onStepper:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:minus];
    UILabel *v = [[UILabel alloc] initWithFrame:CGRectMake(x + 68, y, 46, 24)];
    v.textColor = [UIColor systemYellowColor];
    v.font = [UIFont boldSystemFontOfSize:13];
    v.textAlignment = NSTextAlignmentCenter;
    [panel addSubview:v];
    self.stepValLabels[key] = v;
    UIButton *plus = [UIButton buttonWithType:UIButtonTypeSystem];
    plus.frame = CGRectMake(x + 116, y, 30, 24);
    plus.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    plus.layer.cornerRadius = 6;
    [plus setTitle:@"+" forState:UIControlStateNormal];
    [plus setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    plus.tag = 100 + idx * 2 + 1;
    [plus addTarget:self action:@selector(onStepper:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:plus];
}

- (void)onStepper:(UIButton *)b {
    NSInteger d = b.tag - 100;
    NSInteger idx = d / 2;
    double dir = (d % 2) ? 1 : -1;
    switch (idx) {
        case 0: self.aEnemyHealth = round(MIN(2.0, MAX(0.1, self.aEnemyHealth + dir * 0.1)) * 10) / 10; break;
        case 1: self.aEnemyDamage = round(MIN(2.0, MAX(0.0, self.aEnemyDamage + dir * 0.1)) * 10) / 10; break;
        case 2: self.aTrapDamage = round(MIN(2.0, MAX(0.0, self.aTrapDamage + dir * 0.5)) * 10) / 10; break;
        case 3: self.aContinue = MIN(99, MAX(0, self.aContinue + (NSInteger)dir)); break;
    }
    [self refreshAssistUI];
}

- (void)onToggle:(UIButton *)b {
    switch (b.tag - 200) {
        case 0: self.aParry = !self.aParry; break;
        case 1: self.aTrap = !self.aTrap; break;
        case 2: self.aMap = !self.aMap; break;
        case 3: self.aHeal = !self.aHeal; break;
        case 4: self.aDoors = !self.aDoors; break;
        case 5: self.aSlow = !self.aSlow; break;
    }
    [self refreshAssistUI];
}

- (void)dragBall:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
}

- (void)dragPanel:(UIPanGestureRecognizer *)g {
    // Only drag when the gesture starts on the panel's top strip.
    if (g.state == UIGestureRecognizerStateBegan) {
        CGPoint p = [g locationInView:self.panel];
        if (p.y > 36) { g.enabled = NO; g.enabled = YES; return; }
    }
    UIView *v = g.view;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
}

- (void)notePakPath:(NSString *)path {
    if (!path) return;
    static NSMutableSet<NSString *> *seen = nil;
    BOOL isNew = NO;
    @synchronized (self) {
        if (!seen) seen = [NSMutableSet set];
        if (![seen containsObject:path]) { [seen addObject:path]; isNew = YES; }
    }
    if (isNew) [self logEvent:[NSString stringWithFormat:@"PAK 打开：%@", path]];
}

- (void)onCheckUpdate { [self fetchConfig]; }

- (void)onRecon { [self runRecon]; }

- (void)onRestoreAssist { [self restoreAssist]; }

- (void)onApplyAssist {
    [self saveAssistPrefs];
    [self applyAssistBoost];
    [self refreshFileState];
}

#pragma mark Assist mode boost (feature: options file patch)

- (NSString *)dcOptionsPath {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/save/dc_options.json"];
}

- (void)loadAssistPrefs {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:@"dc_a_enemyHealth"] == nil) {
        self.aEnemyHealth = 0.1; self.aEnemyDamage = 0.1;
        self.aTrapDamage = 0; self.aContinue = 99;
        self.aParry = YES; self.aTrap = YES; self.aMap = YES;
        self.aHeal = YES; self.aDoors = YES; self.aSlow = YES;
        return;
    }
    self.aEnemyHealth = [d doubleForKey:@"dc_a_enemyHealth"];
    self.aEnemyDamage = [d doubleForKey:@"dc_a_enemyDamage"];
    self.aTrapDamage = [d doubleForKey:@"dc_a_trapDamage"];
    self.aContinue = [d integerForKey:@"dc_a_continue"];
    self.aParry = [d boolForKey:@"dc_a_parry"];
    self.aTrap = [d boolForKey:@"dc_a_trap"];
    self.aMap = [d boolForKey:@"dc_a_map"];
    self.aHeal = [d boolForKey:@"dc_a_heal"];
    self.aDoors = [d boolForKey:@"dc_a_doors"];
    self.aSlow = [d boolForKey:@"dc_a_slow"];
}

- (void)saveAssistPrefs {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setDouble:self.aEnemyHealth forKey:@"dc_a_enemyHealth"];
    [d setDouble:self.aEnemyDamage forKey:@"dc_a_enemyDamage"];
    [d setDouble:self.aTrapDamage forKey:@"dc_a_trapDamage"];
    [d setInteger:self.aContinue forKey:@"dc_a_continue"];
    [d setBool:self.aParry forKey:@"dc_a_parry"];
    [d setBool:self.aTrap forKey:@"dc_a_trap"];
    [d setBool:self.aMap forKey:@"dc_a_map"];
    [d setBool:self.aHeal forKey:@"dc_a_heal"];
    [d setBool:self.aDoors forKey:@"dc_a_doors"];
    [d setBool:self.aSlow forKey:@"dc_a_slow"];
    [d synchronize];
}

- (NSDictionary *)assistBlock {
    return @{@"enabled": @YES, @"continueEnabled": @YES, @"gameContinue": @(self.aContinue),
             @"easyParry": @(self.aParry), @"easyTrap": @(self.aTrap), @"revealMap": @(self.aMap),
             @"trapDamage": @(self.aTrapDamage), @"enemyHealth": @(self.aEnemyHealth),
             @"enemyDamage": @(self.aEnemyDamage),
             @"lockMimicSpawn": @NO, @"autoHeal": @(self.aHeal), @"modeAuto": @NO,
             @"autoBreakDoors": @(self.aDoors), @"slowerMobs": @(self.aSlow)};
}

- (void)refreshAssistUI {
    self.stepValLabels[@"enemyHealth"].text = [NSString stringWithFormat:@"%.1f", self.aEnemyHealth];
    self.stepValLabels[@"enemyDamage"].text = [NSString stringWithFormat:@"%.1f", self.aEnemyDamage];
    self.stepValLabels[@"trapDamage"].text = [NSString stringWithFormat:@"%.1f", self.aTrapDamage];
    self.stepValLabels[@"gameContinue"].text = [NSString stringWithFormat:@"%ld", (long)self.aContinue];
    NSDictionary *states = @{@"parry": @(self.aParry), @"trap": @(self.aTrap), @"map": @(self.aMap),
                             @"heal": @(self.aHeal), @"doors": @(self.aDoors), @"slow": @(self.aSlow)};
    NSDictionary *names = @{@"parry": @"弹反", @"trap": @"易陷阱", @"map": @"全图",
                            @"heal": @"回血", @"doors": @"破门", @"slow": @"减速"};
    for (NSString *k in self.toggleBtns) {
        UIButton *b = self.toggleBtns[k];
        BOOL on = [states[k] boolValue];
        [b setTitle:[NSString stringWithFormat:@"%@ %@", names[k], on ? @"开" : @"关"] forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.backgroundColor = on ? [[UIColor systemGreenColor] colorWithAlphaComponent:0.45]
                               : [[UIColor whiteColor] colorWithAlphaComponent:0.12];
    }
}

- (void)refreshFileState {
    if (!self.fileStateLabel) return;
    NSData *data = [NSData dataWithContentsOfFile:[self dcOptionsPath]];
    NSDictionary *root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *am = [root[@"assistMode"] isKindOfClass:[NSDictionary class]] ? root[@"assistMode"] : nil;
    if (am) {
        self.fileStateLabel.text = [NSString stringWithFormat:@"文件当前：敌血 %@ · 敌攻 %@ · 陷阱 %@ · 续命 %@ · %@",
            am[@"enemyHealth"] ?: @"?", am[@"enemyDamage"] ?: @"?", am[@"trapDamage"] ?: @"?",
            am[@"gameContinue"] ?: @"?", [am[@"enabled"] boolValue] ? @"辅助开" : @"辅助关"];
    } else {
        self.fileStateLabel.text = @"文件当前：读不到辅助块";
    }
}

// Runs in the constructor, before the game reads its options file:
// patch assistMode + savedAssistMode in place, keep every other key.
// First run saves a .bak so the panel can restore the original.
- (void)applyAssistBoost {
    [self loadAssistPrefs];
    NSString *path = [self dcOptionsPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [self logEvent:@"辅助拉满：没找到 dc_options.json，跳过"];
        return;
    }
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSDictionary *root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![root isKindOfClass:[NSDictionary class]]) {
        [self logEvent:@"辅助拉满：设置文件解析失败，跳过"];
        return;
    }
    NSString *bak = [path stringByAppendingString:@".bak"];
    if (![fm fileExistsAtPath:bak]) {
        [fm copyItemAtPath:path toPath:bak error:nil];
    }
    NSMutableDictionary *m = [root mutableCopy];
    m[@"assistMode"] = [self assistBlock];
    m[@"savedAssistMode"] = [self assistBlock];
    NSData *out = [NSJSONSerialization dataWithJSONObject:m options:0 error:nil];
    if (out && [out writeToFile:path atomically:YES]) {
        NSDictionary *back = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:nil];
        NSDictionary *am = [back[@"assistMode"] isKindOfClass:[NSDictionary class]] ? back[@"assistMode"] : nil;
        [self logEvent:[NSString stringWithFormat:@"辅助已应用并回读确认：敌血 %@ · 敌攻 %@ · 陷阱 %@ · 续命 %@（重启游戏生效）",
                        am[@"enemyHealth"] ?: @"?", am[@"enemyDamage"] ?: @"?",
                        am[@"trapDamage"] ?: @"?", am[@"gameContinue"] ?: @"?"]];
    } else {
        [self logEvent:@"辅助拉满：写入失败"];
    }
}

- (void)restoreAssist {
    NSString *path = [self dcOptionsPath];
    NSString *bak = [path stringByAppendingString:@".bak"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:bak]) {
        [fm removeItemAtPath:path error:nil];
        if ([fm copyItemAtPath:bak toPath:path error:nil]) {
            [self logEvent:@"已恢复原设置，重开游戏生效"];
        } else {
            [self logEvent:@"恢复失败：拷贝不回去"];
        }
    } else {
        [self logEvent:@"没有备份可恢复（还没拉满过）"];
    }
}

#pragma mark Live recon helpers are above the implementation (file scope).

#pragma mark Hot-update config

- (void)fetchConfig {
    NSString *urlStr = [NSString stringWithFormat:@"%@?t=%@", kDCConfigURL,
                        @((long)[[NSDate date] timeIntervalSince1970])];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithURL:url
      completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]]
                             ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        if (err || code != 200 || !data) {
            [self logEvent:[NSString stringWithFormat:@"配置拉取失败（HTTP %ld%@）",
                            (long)code, err ? @"，有错误" : @""]];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.statusLabel.text = @"通道：连接失败，点「检查更新」重试";
            });
            return;
        }
        NSDictionary *cfg = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *badge = [cfg isKindOfClass:[NSDictionary class]] ? cfg[@"badge"] : nil;
        if (![badge isKindOfClass:[NSString class]] || badge.length == 0) {
            [self logEvent:@"配置校验未过（缺 badge），已忽略"];
            return;
        }
        self.config = cfg;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.badgeLabel.text = badge;
            NSString *title = cfg[@"title"];
            if ([title isKindOfClass:[NSString class]] && title.length) self.titleLabel.text = title;
            NSString *notice = cfg[@"notice"];
            if ([notice isKindOfClass:[NSString class]]) self.noticeLabel.text = notice;
            NSArray *feats = cfg[@"features"];
            if ([feats isKindOfClass:[NSArray class]]) {
                NSMutableArray *lines = [NSMutableArray array];
                for (id f in feats) {
                    if ([f isKindOfClass:[NSString class]]) [lines addObject:[@"· " stringByAppendingString:f]];
                }
                self.featuresLabel.text = [lines componentsJoinedByString:@"\n"];
            }
            self.statusLabel.text = [NSString stringWithFormat:@"通道：已连接（配置 v%@）",
                                     cfg[@"menu_version"] ?: @"?"];
        });
        [self logEvent:[NSString stringWithFormat:@"远程配置已应用：badge=%@ v%@",
                        badge, cfg[@"menu_version"] ?: @"?"]];
    }];
    [task resume];
}

#pragma mark Save / container recon

- (void)runRecon {
    [self logEvent:@"—— 存档侦查开始 ——"];
    NSString *home = NSHomeDirectory();
    [self logEvent:[NSString stringWithFormat:@"容器：%@", home]];
    NSArray *roots = @[@"Documents", @"Library"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *hot = [NSMutableArray array];
    NSMutableArray<NSString *> *normal = [NSMutableArray array];
    for (NSString *rel in roots) {
        NSString *base = [home stringByAppendingPathComponent:rel];
        NSDirectoryEnumerator *en = [fm enumeratorAtPath:base];
        NSString *sub;
        while ((sub = [en nextObject])) {
            NSString *full = [base stringByAppendingPathComponent:sub];
            BOOL isDir = NO;
            [fm fileExistsAtPath:full isDirectory:&isDir];
            if (isDir) continue;
            NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
            unsigned long long sz = [attrs fileSize];
            NSString *low = sub.lowercaseString;
            BOOL isHot = [low containsString:@"save"] || [low containsString:@"option"] ||
                         [low containsString:@"profile"] || [low containsString:@"user"] ||
                         [low hasSuffix:@".dat"] || [low hasSuffix:@".sav"] ||
                         [low containsString:@"steam"] || [low containsString:@"settings"] ||
                         [low containsString:@"deadcells"] || [low containsString:@"progress"];
            NSString *line = [NSString stringWithFormat:@"%@/%@ (%llu)", rel, sub, sz];
            if (isHot) [hot addObject:[@"★" stringByAppendingString:line]];
            else [normal addObject:line];
        }
    }
    for (NSString *l in hot) [self logEvent:l];
    NSInteger room = 120 - (NSInteger)hot.count;
    NSInteger shown = 0;
    for (NSString *l in normal) {
        if (shown++ >= room) break;
        [self logEvent:l];
    }
    [self logEvent:[NSString stringWithFormat:@"—— 侦查完：★%ld 个，共 %ld 个文件 ——",
                    (long)hot.count, (long)(hot.count + normal.count)]];
}

#pragma mark Live recon (probe v2.6: locate pr.Game -> Hero/GameData, read back live values)

- (void)runLiveRecon {
    [self logEvent:@"—— 实时侦查开始（只读） ——"];
    [[NSFileManager defaultManager] removeItemAtPath:dc_stage_path() error:nil];
    dc_stage(@"阶段：侦查开始");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (!dc_live_init(self)) return;
        dc_stage(@"阶段：初始化完成");
        dc_build_regions();
        dc_stage([NSString stringWithFormat:@"阶段：内存区表 %ld 个", (long)dc_g_nregions]);
        for (NSString *want in @[@"pr.Game", @"en.Hero", @"tool.GameData"]) {
            DCClassInfo *ci = dc_g_classes[want];
            NSString *st = ci ? (ci.typeAddr ? @"已登记+已接线" : @"已登记、未接线")
                              : @"没登记到";
            [self logEvent:[NSString stringWithFormat:@"类 %@: %@", want, st]];
            dc_stage([NSString stringWithFormat:@"阶段：类 %@ %@", want, st]);
        }
        NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSNumber *> *first = [NSMutableDictionary dictionary];
        // 1a) Class-object route: pr.Game's global slot holds the class
        //     object; a static field (inst) may point at the live instance.
        DCClassInfo *gameCls0 = dc_g_classes[@"pr.Game"];
        if (gameCls0 && !first[@"pr.Game"]) {
            uintptr_t gv = *(const uintptr_t *)(gameCls0.objBase + 56);
            if (gv && dc_readable2(gv, 8)) {
                uintptr_t classObj = *(const uintptr_t *)gv;
                if (classObj && dc_readable2(classObj, 8)) {
                    DCClassInfo *coCi = dc_class_for_type(*(const uintptr_t *)classObj);
                    [self logEvent:[NSString stringWithFormat:@"类对象 @0x%lx（类 %@），扫它的字段找实例",
                                    (unsigned long)classObj, coCi ? coCi.name : @"?"]];
                    for (uintptr_t off = 8; off <= 1024; off += 8) {
                        if (!dc_readable2(classObj + off, 8)) break;
                        uintptr_t child = *(const uintptr_t *)(classObj + off);
                        if (child < 0x100000000 || (child & 7) || !dc_readable2(child, 16)) continue;
                        DCClassInfo *cci = dc_class_for_type(*(const uintptr_t *)child);
                        if (cci && [cci.name isEqualToString:@"pr.Game"] && !first[@"pr.Game"]) {
                            first[@"pr.Game"] = @(child);
                            counts[@"pr.Game"] = @1;
                            [self logEvent:[NSString stringWithFormat:@"类对象 +0x%lx 处就是 pr.Game 实例",
                                            (unsigned long)off]];
                        }
                    }
                }
            }
            dc_stage(@"阶段：类对象路线走完");
        }
        // 1b) Globals scan: qwords in the game's data segments that point at
        //     live HL objects (first word = hl_type* in the types window).
        //     Hardened: precomputed region table + allocation-free dedupe.
        memset(dc_seen_table, 0, sizeof(dc_seen_table));
        unsigned long candidates = 0;
        for (NSDictionary *span in dc_g_dataSpans) {
            uintptr_t lo = (uintptr_t)[span[@"ptr"] pointerValue];
            uintptr_t hi = lo + [span[@"len"] unsignedLongValue];
            for (uintptr_t s = lo; s + 8 <= hi; s += 8) {
                uintptr_t v = *(const uintptr_t *)s;
                if (v < 0x100000000 || (v & 7)) continue;
                if (v >= dc_g_textLo && v < dc_g_typesHi) continue;
                if (!dc_seen_add(v)) continue;
                candidates++;
                if ((candidates & 0xFFFF) == 0) {
                    dc_stage([NSString stringWithFormat:@"阶段：扫描中 候选 %lu、已认出 %lu 类",
                              candidates, (unsigned long)counts.count]);
                }
                if (!dc_readable2(v, 16)) continue;
                uintptr_t t = *(const uintptr_t *)v;
                DCClassInfo *ci = dc_class_for_type(t);
                if (!ci) continue;
                counts[ci.name] = @([counts[ci.name] unsignedLongLongValue] + 1);
                if (!first[ci.name]) first[ci.name] = @(v);
            }
            dc_stage([NSString stringWithFormat:@"阶段：扫完一个数据段，候选 %lu", candidates]);
        }
        dc_stage([NSString stringWithFormat:@"阶段：全局扫描完成 %lu 类", (unsigned long)counts.count]);
        [self logEvent:[NSString stringWithFormat:@"全局活对象：%lu 类 / 候选 %lu 个",
                        (unsigned long)counts.count, candidates]];
        for (NSString *want in @[@"pr.Game", @"en.Hero", @"tool.GameData"]) {
            if (first[want]) {
                [self logEvent:[NSString stringWithFormat:@"找到 %@ 实例 @0x%lx（共 %@ 个）",
                                want, (unsigned long)[first[want] unsignedLongLongValue], counts[want]]];
            } else {
                [self logEvent:[NSString stringWithFormat:@"全局里没找到 %@", want]];
            }
        }
        // 2) pr.Game -> hero / data
        DCClassInfo *gameCls = dc_g_classes[@"pr.Game"];
        NSNumber *gameAddr = first[@"pr.Game"];
        if (!gameCls || !gameAddr) {
            [self logEvent:@"实时侦查：缺 pr.Game 实例，先到此（把日志发我）"];
            return;
        }
        DCLayout *gl = dc_layout_rec(gameCls);
        uintptr_t rt = *(const uintptr_t *)(gameCls.objBase + 72);
        [self logEvent:[NSString stringWithFormat:@"pr.Game 布局 size=%ld（运行时 rt size=%d）hero@%@ data@%@",
                        (long)gl.size, rt ? *(const int *)(rt + 16) : -1,
                        gl.offsets[@"hero"], gl.offsets[@"data"]]];
        uintptr_t g = [gameAddr unsignedLongLongValue];
        if (!dc_readable(g, (size_t)gl.size)) { [self logEvent:@"Game 对象不可读"]; return; }
        uintptr_t hero = *(const uintptr_t *)(g + [gl.offsets[@"hero"] unsignedLongValue]);
        uintptr_t gdata = *(const uintptr_t *)(g + [gl.offsets[@"data"] unsignedLongValue]);
        DCClassInfo *heroCls = hero ? dc_class_for_type(*(const uintptr_t *)hero) : nil;
        DCClassInfo *dataCls = gdata ? dc_class_for_type(*(const uintptr_t *)gdata) : nil;
        [self logEvent:[NSString stringWithFormat:@"Game.hero -> %@ @0x%lx", heroCls.name ?: @"?", (unsigned long)hero]];
        [self logEvent:[NSString stringWithFormat:@"Game.data -> %@ @0x%lx", dataCls.name ?: @"?", (unsigned long)gdata]];
        if (!heroCls || !dataCls) { [self logEvent:@"子对象类名不对，先到此"]; return; }
        DCLayout *hl = dc_layout_rec(heroCls);
        DCLayout *dl = dc_layout_rec(dataCls);
        uintptr_t hrt = *(const uintptr_t *)(heroCls.objBase + 72);
        [self logEvent:[NSString stringWithFormat:@"Hero 布局 size=%ld（rt size=%d，离线算 1656）",
                        (long)hl.size, hrt ? *(const int *)(hrt + 16) : -1]];
        if (!dc_readable(hero, (size_t)hl.size) || !dc_readable(gdata, (size_t)dl.size)) {
            [self logEvent:@"Hero/GameData 不可读"]; return;
        }
        const uint8_t *hb = (const uint8_t *)hero;
        const uint8_t *db = (const uint8_t *)gdata;
        int life = *(const int *)(hb + [hl.offsets[@"life"] unsignedLongValue]);
        int maxLife = *(const int *)(hb + [hl.offsets[@"maxLife"] unsignedLongValue]);
        double pdm = *(const double *)(hb + [hl.offsets[@"powerDistMul"] unsignedLongValue]);
        int tT = *(const int *)(hb + [hl.offsets[@"tacticTier"] unsignedLongValue]);
        int bT = *(const int *)(hb + [hl.offsets[@"brutalityTier"] unsignedLongValue]);
        int sT = *(const int *)(hb + [hl.offsets[@"survivalTier"] unsignedLongValue]);
        int hCells = *(const int *)(hb + [hl.offsets[@"cells"] unsignedLongValue]);
        int money = *(const int *)(db + [dl.offsets[@"money"] unsignedLongValue]);
        int cells = *(const int *)(db + [dl.offsets[@"cells"] unsignedLongValue]);
        int heal = *(const int *)(db + [dl.offsets[@"healings"] unsignedLongValue]);
        [self logEvent:[NSString stringWithFormat:@"实时读数：生命 %d/%d · 倍率 %.2f · 卷轴 战%d 战术%d 生%d",
                        life, maxLife, pdm, bT, tT, sT]];
        [self logEvent:[NSString stringWithFormat:@"实时读数：金币 %d · 细胞 %d（Hero 侧 %d） · 血瓶 %d",
                        money, cells, hCells, heal]];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.statusLabel.text = [NSString stringWithFormat:@"实时：生命 %d/%d · 金币 %d · 细胞 %d",
                                     life, maxLife, money, cells];
        });
        dc_stage(@"阶段：读数完成（没闪退）");
        [self logEvent:@"—— 实时侦查完成 ——"];
    });
}

@end

#pragma mark - PAK open probe (data-layer recon, log-only)

static int (*dc_orig_open)(const char *, int, ...) = NULL;
static int (*dc_orig_openat)(int, const char *, int, ...) = NULL;
static FILE *(*dc_orig_fopen)(const char *, const char *) = NULL;

static void dc_resolve_orig(void) {
    if (!dc_orig_open) dc_orig_open = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open");
    if (!dc_orig_openat) dc_orig_openat = (int (*)(int, const char *, int, ...))dlsym(RTLD_NEXT, "openat");
    if (!dc_orig_fopen) dc_orig_fopen = (FILE *(*)(const char *, const char *))dlsym(RTLD_NEXT, "fopen");
}

static void dc_note_path(const char *path) {
    if (path && strstr(path, ".pak")) {
        [[DCMenu shared] notePakPath:[NSString stringWithUTF8String:path]];
    }
}

static int dc_my_open(const char *path, int oflag, ...) {
    mode_t mode = 0;
    if (oflag & O_CREAT) {
        va_list ap; va_start(ap, oflag);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }
    dc_resolve_orig();
    dc_note_path(path);
    return dc_orig_open(path, oflag, mode);
}

static int dc_my_openat(int dirfd, const char *path, int oflag, ...) {
    mode_t mode = 0;
    if (oflag & O_CREAT) {
        va_list ap; va_start(ap, oflag);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }
    dc_resolve_orig();
    dc_note_path(path);
    return dc_orig_openat(dirfd, path, oflag, mode);
}

static FILE *dc_my_fopen(const char *path, const char *mode) {
    dc_resolve_orig();
    dc_note_path(path);
    return dc_orig_fopen(path, mode);
}

#define DC_INTERPOSE(replacement, replacee) \
    __attribute__((used)) static const struct { const void *repl; const void *orig; } \
    dc_interpose_##replacee __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)replacement, (const void *)replacee }

DC_INTERPOSE(dc_my_open, open);
DC_INTERPOSE(dc_my_openat, openat);
DC_INTERPOSE(dc_my_fopen, fopen);

#pragma mark - Entry

__attribute__((constructor)) static void DCMenuInit(void) {
    // Patch the options file before the game reads it (tweak constructors
    // run during dyld init, ahead of the game's own startup).
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    if ([bid containsString:@"deadcells"]) {
        [[DCMenu shared] applyAssistBoost];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[DCMenu shared] setup];
    });
}
