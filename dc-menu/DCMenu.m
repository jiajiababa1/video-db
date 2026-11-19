// DCMenu.m — Dead Cells (Bilibili v3.5.13) floating menu tweak for LiveContainer
// Minimal v1: floating ball + panel + hot-update channel ONLY.
// Feature definitions (title / badge / notice / feature list) come from a
// remote JSON; updating that JSON changes the menu with no file replacement.
// Remote config: https://api.github.com/repos/jiajiababa1/video-db/contents/dc-menu/menu.json
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString * const kDCConfigURL = @"https://raw.githubusercontent.com/jiajiababa1/video-db/main/dc-menu/menu.json";
static NSString * const kDCBundledBadge = @"版本 A";
// Hot-switchable login-fix mode, driven by remote config key "fix_mode":
// 0 = off (pure observation), 1 = addiction-verify switches forced off,
// 2 = real-name state forced verified, 3 = both.
static NSInteger gFixMode = 0;

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
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *diagLabel;
@property (nonatomic, strong) NSDictionary *config;
@property (nonatomic, strong) NSMutableArray<NSString *> *events;
@property (nonatomic, strong) NSMutableSet<NSString *> *onceKeys;
@property (nonatomic, assign) BOOL probesInstalled;
@property (nonatomic, assign) BOOL setupDone;
+ (instancetype)shared;
- (void)setup;
- (void)fetchConfig;
- (void)logEvent:(NSString *)name;
- (void)logEventOnce:(NSString *)key text:(NSString *)text;
- (void)installProbes;
@end

@implementation DCMenu

+ (instancetype)shared {
    static DCMenu *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [DCMenu new]; });
    return inst;
}

- (void)setup {
    if (self.setupDone) return;
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return;
    self.setupDone = YES;

    CGRect bounds = [UIScreen mainScreen].bounds;
    DCPassWindow *win;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = nil;
        for (UIScene *s in app.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                (s.activationState == UISceneActivationStateForegroundActive ||
                 s.activationState == UISceneActivationStateForegroundInactive)) {
                scene = (UIWindowScene *)s;
                break;
            }
        }
        if (scene) {
            win = [[DCPassWindow alloc] initWithWindowScene:scene];
            bounds = scene.coordinateSpace.bounds;
        } else {
            win = [[DCPassWindow alloc] initWithFrame:bounds];
        }
    } else {
        win = [[DCPassWindow alloc] initWithFrame:bounds];
    }
    win.frame = bounds;
    win.windowLevel = UIWindowLevelAlert + 100;
    win.backgroundColor = [UIColor clearColor];
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = [UIColor clearColor];
    win.rootViewController = root;
    win.hidden = NO;
    self.window = win;

    // Floating ball
    UIButton *ball = [UIButton buttonWithType:UIButtonTypeCustom];
    ball.frame = CGRectMake(bounds.size.width - 70, bounds.size.height * 0.35, 56, 56);
    ball.layer.cornerRadius = 28;
    ball.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.85];
    [ball setTitle:@"菜单" forState:UIControlStateNormal];
    ball.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [ball setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [ball addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [ball addGestureRecognizer:pan];
    [root.view addSubview:ball];
    self.ball = ball;

    // Panel
    CGFloat pw = MIN(320, bounds.size.width - 40);
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake((bounds.size.width - pw) / 2.0, bounds.size.height * 0.16, pw, 400)];
    panel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.88];
    panel.layer.cornerRadius = 16;
    panel.hidden = YES;
    [root.view addSubview:panel];
    self.panel = panel;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 14, pw - 32, 24)];
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:17];
    title.text = @"重生细胞 · 悬浮菜单";
    [panel addSubview:title];
    self.titleLabel = title;

    UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(16, 48, pw - 32, 44)];
    badge.textColor = [UIColor systemYellowColor];
    badge.font = [UIFont boldSystemFontOfSize:30];
    badge.text = kDCBundledBadge;
    [panel addSubview:badge];
    self.badgeLabel = badge;

    UILabel *notice = [[UILabel alloc] initWithFrame:CGRectMake(16, 100, pw - 32, 60)];
    notice.textColor = [UIColor lightGrayColor];
    notice.font = [UIFont systemFontOfSize:13];
    notice.numberOfLines = 0;
    notice.text = @"热更新通道验证版";
    [panel addSubview:notice];
    self.noticeLabel = notice;

    UILabel *status = [[UILabel alloc] initWithFrame:CGRectMake(16, 168, pw - 32, 36)];
    status.textColor = [UIColor systemGreenColor];
    status.font = [UIFont systemFontOfSize:12];
    status.numberOfLines = 0;
    status.text = @"本地版 · 正在检查更新…";
    [panel addSubview:status];
    self.statusLabel = status;

    UILabel *diag = [[UILabel alloc] initWithFrame:CGRectMake(16, 208, pw - 32, 96)];
    diag.textColor = [UIColor systemCyanColor];
    diag.font = [UIFont systemFontOfSize:11];
    diag.numberOfLines = 0;
    diag.text = @"登录诊断：等待事件…";
    [panel addSubview:diag];
    self.diagLabel = diag;

    UIButton *refresh = [UIButton buttonWithType:UIButtonTypeSystem];
    refresh.frame = CGRectMake(16, 316, (pw - 48) / 2.0, 44);
    refresh.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    refresh.layer.cornerRadius = 10;
    [refresh setTitle:@"检查更新" forState:UIControlStateNormal];
    [refresh setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [refresh addTarget:self action:@selector(fetchConfig) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:refresh];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(32 + (pw - 48) / 2.0, 316, (pw - 48) / 2.0, 44);
    close.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    close.layer.cornerRadius = 10;
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [close addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:close];

    [self fetchConfig];
    [self installProbes];
}

- (void)logEvent:(NSString *)name {
    if (!self.events) self.events = [NSMutableArray array];
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"%@ %@", [fmt stringFromDate:[NSDate date]], name];
    [self.events addObject:line];
    while (self.events.count > 6) [self.events removeObjectAtIndex:0];
    NSString *text = [@"登录诊断：\n" stringByAppendingString:[self.events componentsJoinedByString:@"\n"]];
    if ([NSThread isMainThread]) {
        self.diagLabel.text = text;
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ self.diagLabel.text = text; });
    }
}

- (void)logEventOnce:(NSString *)key text:(NSString *)text {
    if (!self.onceKeys) self.onceKeys = [NSMutableSet set];
    if ([self.onceKeys containsObject:key]) return;
    [self.onceKeys addObject:key];
    [self logEvent:text];
}

typedef void (*ImpV)(id, SEL);
typedef void (*ImpV1)(id, SEL, id);
typedef void (*ImpV2)(id, SEL, id, id);
typedef void (*ImpV2B)(id, SEL, id, id, BOOL);
static ImpV   orig_didInitSDKSuccess;
static ImpV2  orig_didLoginSuccessKey;
static ImpV1  orig_didLoginSuccessResult;
static ImpV1  orig_didGetUserInfoOK;
static ImpV1  orig_didGetUserInfoFail;
static ImpV1  orig_didLoginFailure;
static ImpV2B orig_onGameAddiction;

static void rep_didInitSDKSuccess(id s, SEL c) { [[DCMenu shared] logEvent:@"SDK 初始化成功"]; if (orig_didInitSDKSuccess) orig_didInitSDKSuccess(s, c); }
static void rep_didLoginSuccessKey(id s, SEL c, id a, id b) { [[DCMenu shared] logEvent:@"登录成功 (AccessKey)"]; if (orig_didLoginSuccessKey) orig_didLoginSuccessKey(s, c, a, b); }
static void rep_didLoginSuccessResult(id s, SEL c, id a) { [[DCMenu shared] logEvent:@"登录成功 (Result)"]; if (orig_didLoginSuccessResult) orig_didLoginSuccessResult(s, c, a); }
static void rep_didGetUserInfoOK(id s, SEL c, id a) { [[DCMenu shared] logEvent:@"用户信息已拿到"]; if (orig_didGetUserInfoOK) orig_didGetUserInfoOK(s, c, a); }
static void rep_didGetUserInfoFail(id s, SEL c, id a) { [[DCMenu shared] logEvent:@"用户信息获取失败"]; if (orig_didGetUserInfoFail) orig_didGetUserInfoFail(s, c, a); }
static void rep_didLoginFailure(id s, SEL c, id a) { [[DCMenu shared] logEvent:@"登录失败回调"]; if (orig_didLoginFailure) orig_didLoginFailure(s, c, a); }
static void rep_onGameAddiction(id s, SEL c, id a, id b, BOOL f) { [[DCMenu shared] logEvent:@"防沉迷回调到达"]; if (orig_onGameAddiction) orig_onGameAddiction(s, c, a, b, f); }

#pragma mark - Login-fix hooks (behavior switched live by gFixMode)

typedef BOOL (*ImpB)(id, SEL);

#define DC_ADDICTION_HOOK(name) \
  static ImpB orig_##name; \
  static BOOL rep_##name(id s, SEL c) { \
    BOOL v = orig_##name ? orig_##name(s, c) : YES; \
    if ((gFixMode == 1 || gFixMode == 3) && v) { \
      [[DCMenu shared] logEventOnce:@"fix-addiction" text:@"已拦截 · 防沉迷校验开关"]; \
      return NO; \
    } \
    return v; \
  }

#define DC_REALNAME_HOOK(name) \
  static ImpB orig_##name; \
  static BOOL rep_##name(id s, SEL c) { \
    BOOL v = orig_##name ? orig_##name(s, c) : NO; \
    if ((gFixMode == 2 || gFixMode == 3) && !v) { \
      [[DCMenu shared] logEventOnce:@"fix-realname" text:@"已拦截 · 实名状态"]; \
      return YES; \
    } \
    return v; \
  }

DC_ADDICTION_HOOK(add_GSBaseApi)
DC_ADDICTION_HOOK(add_GSCHttpRequestDo)
DC_ADDICTION_HOOK(add_GSCHttpRequest)
DC_ADDICTION_HOOK(add_GSCHttpLinesRequest)
DC_ADDICTION_HOOK(add_req_GSCHttpLinesRequest)
DC_ADDICTION_HOOK(add_BGSRequest)
DC_ADDICTION_HOOK(add_BGSChangeLineRequest)
DC_ADDICTION_HOOK(add_HeartbeatApi)
DC_REALNAME_HOOK(rn_GSSDK)
DC_REALNAME_HOOK(rn_GSSDKLogin)

typedef void (*ImpPresent)(id, SEL, UIViewController *, BOOL, id);
static ImpPresent orig_presentVC;
static void rep_presentVC(id s, SEL c, UIViewController *vc, BOOL animated, id completion) {
    [[DCMenu shared] logEvent:[NSString stringWithFormat:@"弹出界面: %@", NSStringFromClass([vc class])]];
    if (orig_presentVC) orig_presentVC(s, c, vc, animated, completion);
}

static int DCProbe(Class cls, SEL sel, IMP rep, IMP *store) {
    if (!cls) return 0;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return 0;
    *store = method_setImplementation(m, rep);
    return 1;
}

- (void)installProbes {
    if (self.probesInstalled) return;
    Class impl = NSClassFromString(@"BilibiliSDKImpl");
    Class addiction = NSClassFromString(@"GSCGameAddictionManager");
    int n = 0;
    n += DCProbe(impl, @selector(didInitSDKSuccess), (IMP)rep_didInitSDKSuccess, (IMP *)&orig_didInitSDKSuccess);
    n += DCProbe(impl, @selector(didLoginSuccessWithAccessKey:uid:), (IMP)rep_didLoginSuccessKey, (IMP *)&orig_didLoginSuccessKey);
    n += DCProbe(impl, @selector(didLoginSuccessWithResult:), (IMP)rep_didLoginSuccessResult, (IMP *)&orig_didLoginSuccessResult);
    n += DCProbe(impl, @selector(didGetUserInfoSuccessWithBLAuth:), (IMP)rep_didGetUserInfoOK, (IMP *)&orig_didGetUserInfoOK);
    n += DCProbe(impl, @selector(didGetUserInfoFailureWithError:), (IMP)rep_didGetUserInfoFail, (IMP *)&orig_didGetUserInfoFail);
    n += DCProbe(impl, @selector(didLoginFailureWithError:), (IMP)rep_didLoginFailure, (IMP *)&orig_didLoginFailure);
    n += DCProbe(addiction, @selector(onGameAddiction:data:appRestrictFirst:), (IMP)rep_onGameAddiction, (IMP *)&orig_onGameAddiction);
    int p = DCProbe([UIViewController class], @selector(presentViewController:animated:completion:), (IMP)rep_presentVC, (IMP *)&orig_presentVC);
    if (p > 0) [self logEvent:@"界面探针已装"];
    int f = 0;
    f += DCProbe(NSClassFromString(@"GSBaseApi"), @selector(openAddictionVerification), (IMP)rep_add_GSBaseApi, (IMP *)&orig_add_GSBaseApi);
    f += DCProbe(NSClassFromString(@"GSCHttpRequestDo"), @selector(openAddictionVerification), (IMP)rep_add_GSCHttpRequestDo, (IMP *)&orig_add_GSCHttpRequestDo);
    f += DCProbe(NSClassFromString(@"GSCHttpRequest"), @selector(openAddictionVerification), (IMP)rep_add_GSCHttpRequest, (IMP *)&orig_add_GSCHttpRequest);
    f += DCProbe(NSClassFromString(@"GSCHttpLinesRequest"), @selector(openAddictionVerification), (IMP)rep_add_GSCHttpLinesRequest, (IMP *)&orig_add_GSCHttpLinesRequest);
    f += DCProbe(NSClassFromString(@"GSCHttpLinesRequest"), @selector(reqAddictionVerification), (IMP)rep_add_req_GSCHttpLinesRequest, (IMP *)&orig_add_req_GSCHttpLinesRequest);
    f += DCProbe(NSClassFromString(@"BGSRequest"), @selector(openAddictionVerify), (IMP)rep_add_BGSRequest, (IMP *)&orig_add_BGSRequest);
    f += DCProbe(NSClassFromString(@"BGSChangeLineRequest"), @selector(openAddictionVerify), (IMP)rep_add_BGSChangeLineRequest, (IMP *)&orig_add_BGSChangeLineRequest);
    f += DCProbe(NSClassFromString(@"HeartbeatApi"), @selector(openAddictionVerification), (IMP)rep_add_HeartbeatApi, (IMP *)&orig_add_HeartbeatApi);
    f += DCProbe(NSClassFromString(@"GSSDK"), @selector(isRealnameAuth), (IMP)rep_rn_GSSDK, (IMP *)&orig_rn_GSSDK);
    f += DCProbe(NSClassFromString(@"GSSDKLogin"), @selector(isRealnameAuth), (IMP)rep_rn_GSSDKLogin, (IMP *)&orig_rn_GSSDKLogin);
    if (f > 0) [self logEvent:[NSString stringWithFormat:@"修复钩子已装 %d/10", f]];
    if (n > 0) {
        self.probesInstalled = YES;
        [self logEvent:[NSString stringWithFormat:@"探针已装 %d/7", n]];
    }
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.window];
    CGPoint c = self.ball.center;
    c.x += t.x; c.y += t.y;
    self.ball.center = c;
    [g setTranslation:CGPointZero inView:self.window];
}

- (void)togglePanel {
    self.panel.hidden = !self.panel.hidden;
    if (!self.panel.hidden) [self fetchConfig];
}

- (void)applyConfig:(NSDictionary *)cfg {
    self.config = cfg;
    NSString *title = cfg[@"title"];
    if ([title isKindOfClass:[NSString class]] && title.length) self.titleLabel.text = title;
    NSString *badge = cfg[@"badge"];
    if ([badge isKindOfClass:[NSString class]] && badge.length) self.badgeLabel.text = badge;
    NSString *notice = cfg[@"notice"];
    if ([notice isKindOfClass:[NSString class]] && notice.length) self.noticeLabel.text = notice;
    NSNumber *fm = cfg[@"fix_mode"];
    if ([fm isKindOfClass:[NSNumber class]] && fm.integerValue != gFixMode) {
        gFixMode = fm.integerValue;
        [self logEvent:[NSString stringWithFormat:@"修复模式已切到 %ld", (long)gFixMode]];
    }
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"HH:mm:ss";
    self.statusLabel.text = [NSString stringWithFormat:@"已连上更新通道 · %@", [fmt stringFromDate:[NSDate date]]];
    NSString *appliedBadge = cfg[@"badge"];
    if ([appliedBadge isKindOfClass:[NSString class]] && appliedBadge.length) {
        [self logEvent:[NSString stringWithFormat:@"远程配置已应用: %@", appliedBadge]];
    }
}

- (void)fetchConfig {
    NSURL *url = [NSURL URLWithString:kDCConfigURL];
    if (!url) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData
                                                   timeoutInterval:15];
    [req setValue:@"DCMenu/1.0" forHTTPHeaderField:@"User-Agent"];
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                     completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            DCMenu *self_ = weakSelf;
            if (!self_) return;
            NSHTTPURLResponse *http = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;
            if (err || !data || (http && http.statusCode != 200)) {
                self_.statusLabel.text = http ? [NSString stringWithFormat:@"更新检查失败 (HTTP %ld) · 显示本地版", (long)http.statusCode]
                                              : @"更新检查失败 · 显示本地版";
                return;
            }
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            // Only a payload that really carries our badge counts as a config.
            if ([json isKindOfClass:[NSDictionary class]] &&
                [json[@"badge"] isKindOfClass:[NSString class]] && [json[@"badge"] length]) {
                [self_ applyConfig:json];
                return;
            }
            self_.statusLabel.text = @"更新内容无效 · 显示本地版";
        });
    }] resume];
}

@end

#pragma mark - Entry

__attribute__((constructor))
static void DCMenuInit(void) {
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        [[DCMenu shared] setup];
    }];
    // Fallback in case the tweak is loaded after launch finished
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (![DCMenu shared].setupDone) [[DCMenu shared] setup];
    });
}
