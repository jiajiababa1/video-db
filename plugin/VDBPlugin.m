// VDBPlugin.m — video-db 热更新插件 (LiveContainer tweak)
// 加载时机: TweakLoader 在 guest 的 UIApplicationMain 之前 dlopen 本库, constructor 随即执行。
// 职责: 拉取签名更新包 → ECDSA 验签 → 落盘到 App 的 Documents/VDBPlugin (与 App 内桥共用)
//       → 跑 bootstrap JS 模块 → 提供一个悬浮按钮管理面板。任何异常都不许影响宿主 App。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <Security/Security.h>

static NSString * const kPluginVersion = @"1.0";
static NSString * const kBundleURL = @"https://jiajiababa1.github.io/video-db/updates/bundle.json";
// ECDSA P-256 公钥点 (与 App 内桥同一把; 私钥离线保管)
static NSString * const kPubKeyB64 = @"BJWnDYF+1uy6JOLPRd/AmshmblNQp/jPAP/ypCJPE0jMkirA9i7pIAKk5gFJq8iBcq2vvvS35i3aDOxB1x5TB/I=";

@interface VDBPlugin : NSObject
@property (nonatomic, strong) NSMutableDictionary *store;
@property (nonatomic, assign) NSInteger bundleVersion;
@property (nonatomic, copy) NSString *statusText;
@property (nonatomic, strong) NSArray *moduleNames;
@end

@implementation VDBPlugin

+ (instancetype)shared {
    static VDBPlugin *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [VDBPlugin new]; });
    return s;
}

- (NSURL *)pluginDir {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [docs stringByAppendingPathComponent:@"VDBPlugin"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [NSURL fileURLWithPath:dir];
}

- (void)start {
    @try {
        self.store = [NSMutableDictionary dictionary];
        self.moduleNames = @[];
        self.statusText = @"待检查";
        [self loadStore];
        [self writeMarker];
        [self loadLocalBundleAndRun];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [self checkUpdate];
        });
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(appLaunched)
                                                     name:UIApplicationDidFinishLaunchingNotification
                                                   object:nil];
    } @catch (NSException *e) {
        NSLog(@"[VDBPlugin] start failed: %@", e);
    }
}

- (void)writeMarker {
    NSDictionary *marker = @{@"version": kPluginVersion,
                             @"ts": @([[NSDate date] timeIntervalSince1970])};
    NSData *data = [NSJSONSerialization dataWithJSONObject:marker options:0 error:nil];
    [data writeToURL:[[self pluginDir] URLByAppendingPathComponent:@"plugin.json"] atomically:YES];
}

// ---------- 验签 ----------
- (NSData *)verifyAndExtract:(NSData *)bundleData {
    NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:bundleData options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    NSString *payloadB64 = obj[@"payload_b64"];
    NSString *sigB64 = obj[@"sig_b64"];
    if (!payloadB64 || !sigB64) return nil;
    NSData *payloadData = [[NSData alloc] initWithBase64EncodedString:payloadB64 options:0];
    NSData *sig = [[NSData alloc] initWithBase64EncodedString:sigB64 options:0];
    NSData *pubData = [[NSData alloc] initWithBase64EncodedString:kPubKeyB64 options:0];
    if (!payloadData || !sig || !pubData) return nil;
    NSDictionary *attrs = @{(__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
                            (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic,
                            (__bridge id)kSecAttrKeySizeInBits: @256};
    SecKeyRef key = SecKeyCreateWithData((__bridge CFDataRef)pubData, (__bridge CFDictionaryRef)attrs, NULL);
    if (!key) return nil;
    NSData *msg = [payloadB64 dataUsingEncoding:NSUTF8StringEncoding];
    BOOL ok = SecKeyVerifySignature(key, kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
                                    (__bridge CFDataRef)msg, (__bridge CFDataRef)sig, NULL);
    CFRelease(key);
    return ok ? payloadData : nil;
}

// ---------- 更新包 ----------
- (void)loadLocalBundleAndRun {
    NSData *data = [NSData dataWithContentsOfURL:[[self pluginDir] URLByAppendingPathComponent:@"bundle.json"]];
    if (!data) return;
    NSData *payloadData = [self verifyAndExtract:data];
    if (!payloadData) return;
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:payloadData options:0 error:nil];
    if (payload) {
        [self applyPayload:payload];
        [self runBootstrapModules:payload];
    }
}

- (void)checkUpdate {
    @try {
        NSString *urlStr = [NSString stringWithFormat:@"%@?t=%@", kBundleURL, @((NSInteger)[[NSDate date] timeIntervalSince1970])];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
        req.timeoutInterval = 20;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block NSData *result = nil;
        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            result = data;
            dispatch_semaphore_signal(sem);
        }] resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC));
        if (!result) { self.statusText = @"检查失败: 网络错误"; return; }
        NSData *payloadData = [self verifyAndExtract:result];
        if (!payloadData) { self.statusText = @"更新包验签失败, 已忽略"; return; }
        NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:payloadData options:0 error:nil];
        NSInteger version = [payload[@"version"] integerValue];
        if (version > self.bundleVersion) {
            NSURL *cur = [[self pluginDir] URLByAppendingPathComponent:@"bundle.json"];
            NSURL *prev = [[self pluginDir] URLByAppendingPathComponent:@"bundle.prev.json"];
            NSFileManager *fm = [NSFileManager defaultManager];
            if ([fm fileExistsAtPath:cur.path]) {
                [fm removeItemAtURL:prev error:nil];
                [fm copyItemAtURL:cur toURL:prev error:nil];
            }
            [result writeToURL:cur atomically:YES];
            [self applyPayload:payload];
            [self runBootstrapModules:payload];
            self.statusText = [NSString stringWithFormat:@"已更新到 v%ld", (long)version];
        } else {
            self.statusText = [NSString stringWithFormat:@"已是最新 (v%ld)", (long)self.bundleVersion];
        }
    } @catch (NSException *e) {
        self.statusText = @"检查异常";
    }
}

- (void)applyPayload:(NSDictionary *)payload {
    self.bundleVersion = [payload[@"version"] integerValue];
    NSMutableArray *names = [NSMutableArray array];
    for (NSDictionary *m in payload[@"modules"] ?: @[]) {
        if (m[@"name"]) [names addObject:[NSString stringWithFormat:@"%@ v%@", m[@"name"], m[@"version"] ?: @1]];
    }
    self.moduleNames = names;
}

// ---------- JS 模块 ----------
- (void)loadStore {
    NSData *data = [NSData dataWithContentsOfURL:[[self pluginDir] URLByAppendingPathComponent:@"store.json"]];
    if (data) {
        NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([obj isKindOfClass:[NSDictionary class]]) self.store = [obj mutableCopy];
    }
}

- (void)saveStore {
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.store options:0 error:nil];
    [data writeToURL:[[self pluginDir] URLByAppendingPathComponent:@"store.json"] atomically:YES];
}

- (NSString *)syncFetch:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return nil;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 15;
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15" forHTTPHeaderField:@"User-Agent"];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSString *out = nil;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (data) out = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_SEC));
    return out;
}

- (void)runBootstrapModules:(NSDictionary *)payload {
    for (NSDictionary *m in payload[@"modules"] ?: @[]) {
        if (![m[@"kind"] isEqualToString:@"bootstrap"] || !m[@"js"]) continue;
        @try {
            JSContext *ctx = [JSContext new];
            ctx.exceptionHandler = ^(JSContext *c, JSValue *exc) {
                NSLog(@"[VDBPlugin] module %@: %@", m[@"name"], [exc toString]);
            };
            __weak typeof(self) weakSelf = self;
            ctx[@"vdb"] = @{
                @"fetchText": ^NSString *(NSString *url) { return [weakSelf syncFetch:url] ?: @""; },
                @"log": ^(NSString *s) { NSLog(@"[vdb-module] %@", s); },
                @"store": ^(NSString *k, NSString *v) {
                    weakSelf.store[k] = v;
                    [weakSelf saveStore];
                },
                @"getStore": ^NSString *(NSString *k) { return weakSelf.store[k] ?: @""; },
            };
            [ctx evaluateScript:m[@"js"]];
        } @catch (NSException *e) {
            NSLog(@"[VDBPlugin] module run failed: %@", e);
        }
    }
}

// ---------- 悬浮面板 ----------
- (void)appLaunched {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try { [self installFloatingButton]; } @catch (NSException *e) {}
    });
}

- (UIWindow *)keyWindow {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) return w;
            return [((UIWindowScene *)scene).windows firstObject];
        }
    }
    return [UIApplication sharedApplication].windows.firstObject;
}

- (void)installFloatingButton {
    UIWindow *win = [self keyWindow];
    if (!win || [win viewWithTag:987654]) return;
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.tag = 987654;
    btn.frame = CGRectMake(win.bounds.size.width - 56, win.bounds.size.height - 170, 44, 44);
    btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    [btn setTitle:@"🧩" forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:20];
    btn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    btn.layer.cornerRadius = 22;
    [btn addTarget:self action:@selector(showPanel) forControlEvents:UIControlEventTouchUpInside];
    [win addSubview:btn];
}

- (void)showPanel {
    UIViewController *top = [self keyWindow].rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if (!top) return;
    NSString *msg = [NSString stringWithFormat:@"插件版本: v%@\n更新包版本: %@\n模块: %@\n链路自检: %@\n状态: %@",
                     kPluginVersion,
                     self.bundleVersion > 0 ? [NSString stringWithFormat:@"v%ld", (long)self.bundleVersion] : @"内置",
                     self.moduleNames.count ? [self.moduleNames componentsJoinedByString:@" · "] : @"无",
                     self.store[@"hello_ran"] ? @"JS 引擎正常 ✓" : @"等待模块运行",
                     self.statusText ?: @""];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🧩 热更新插件"
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"立即检查更新" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [self checkUpdate]; });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:alert animated:YES completion:nil];
}

@end

__attribute__((constructor)) static void VDBPluginInit(void) {
    @autoreleasepool {
        [[VDBPlugin shared] start];
    }
}
