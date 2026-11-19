// DCMenu.m — Dead Cells (Apple Arcade v3.3.15, Playdigious) floating menu
// tweak for LiveContainer. v2.0: clean shell for the Arcade build —
// floating ball + draggable panel + hot-update channel + save recon.
// NO SDK probes, NO network swizzles (the v1.9 crash suspects are gone).
// Feature definitions (title / badge / notice / features) come from a
// remote JSON; updating that JSON changes the menu with no file swap.
// Remote config: https://raw.githubusercontent.com/jiajiababa1/video-db/main/dc-menu/menu.json
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString * const kDCConfigURL = @"https://raw.githubusercontent.com/jiajiababa1/video-db/main/dc-menu/menu.json";
static NSString * const kDCBundledBadge = @"版本 A";
static NSString * const kDCMenuVersion = @"v2.3";

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
+ (instancetype)shared;
- (void)setup;
- (void)fetchConfig;
- (void)logEvent:(NSString *)text;
- (void)runRecon;
- (void)applyAssistBoost;
- (void)restoreAssist;
@end

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

    UITextView *log = [[UITextView alloc] initWithFrame:CGRectMake(12, 110, pw - 24, ph - 110 - 52)];
    log.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    log.textColor = [UIColor whiteColor];
    log.font = [UIFont systemFontOfSize:10];
    log.editable = NO;
    log.layer.cornerRadius = 8;
    [panel addSubview:log];
    self.logView = log;

    NSArray *btns = @[@[@"检查更新", @"onCheckUpdate"], @[@"存档侦查", @"onRecon"], @[@"恢复辅助", @"onRestoreAssist"], @[@"关闭", @"togglePanel"]];
    CGFloat bw = (pw - 32 - 24) / 4;
    for (NSInteger i = 0; i < 4; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(16 + i * (bw + 8), ph - 44, bw, 34);
        b.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
        b.layer.cornerRadius = 8;
        [b setTitle:btns[i][0] forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:13];
        [b addTarget:self action:NSSelectorFromString(btns[i][1]) forControlEvents:UIControlEventTouchUpInside];
        [panel addSubview:b];
    }
}

#pragma mark UI actions

- (void)togglePanel {
    self.panel.hidden = !self.panel.hidden;
    if (!self.panel.hidden) [self renderLog];
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

- (void)onCheckUpdate { [self fetchConfig]; }

- (void)onRecon { [self runRecon]; }

- (void)onRestoreAssist { [self restoreAssist]; }

#pragma mark Assist mode boost (feature: options file patch)

- (NSString *)dcOptionsPath {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/save/dc_options.json"];
}

- (NSDictionary *)assistBlock {
    return @{@"enabled": @YES, @"continueEnabled": @YES, @"gameContinue": @99,
             @"easyParry": @YES, @"easyTrap": @YES, @"revealMap": @YES,
             @"trapDamage": @0, @"enemyHealth": @0.1, @"enemyDamage": @0.1,
             @"lockMimicSpawn": @NO, @"autoHeal": @YES, @"modeAuto": @NO,
             @"autoBreakDoors": @YES, @"slowerMobs": @YES};
}

// Runs in the constructor, before the game reads its options file:
// patch assistMode + savedAssistMode in place, keep every other key.
// First run saves a .bak so the panel can restore the original.
- (void)applyAssistBoost {
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
        [self logEvent:@"辅助模式已拉满（敌血/敌攻 0.1、陷阱 0、续命 99、自动回血、全图揭示）"];
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

@end

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
