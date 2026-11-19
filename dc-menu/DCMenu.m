// DCMenu.m — Dead Cells (Bilibili v3.5.13) floating menu tweak for LiveContainer
// Minimal v1: floating ball + panel + hot-update channel ONLY.
// Feature definitions (title / badge / notice / feature list) come from a
// remote JSON; updating that JSON changes the menu with no file replacement.
// Remote config: https://api.github.com/repos/jiajiababa1/video-db/contents/dc-menu/menu.json
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <Block.h>

static NSString * const kDCConfigURL = @"https://raw.githubusercontent.com/jiajiababa1/video-db/main/dc-menu/menu.json";
static NSString * const kDCBundledBadge = @"版本 A";
// Hot-switchable login-fix mode, driven by remote config key "fix_mode":
// 0 = off (pure observation), 1 = addiction-verify switches forced off,
// 2 = real-name state forced verified, 3 = both,
// 4 = both + synthesize the addiction callback at the GSSDK facade when it
//     does not arrive within 5s of user-info (the observed stall).
static NSInteger gFixMode = 0;
static BOOL DCAddictionOn(void) { return gFixMode == 1 || gFixMode == 3 || gFixMode >= 4; }
static BOOL DCRealnameOn(void) { return gFixMode == 2 || gFixMode == 3 || gFixMode >= 4; }
static BOOL gAddictionFired = NO;
static BOOL gSynthDone = NO;
static BOOL gManagerFired = NO;
static BOOL gManagerSynthDone = NO;
static __weak id gSDKImpl = nil;
static __weak id gService = nil;

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
@property (nonatomic, strong) UITextView *diagLabel;
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
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake((bounds.size.width - pw) / 2.0, bounds.size.height * 0.16, pw, 430)];
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

    UITextView *diag = [[UITextView alloc] initWithFrame:CGRectMake(16, 204, pw - 32, 118)];
    diag.textColor = [UIColor systemCyanColor];
    diag.font = [UIFont systemFontOfSize:10];
    diag.backgroundColor = [UIColor clearColor];
    diag.editable = NO;
    diag.scrollEnabled = YES;
    diag.text = @"登录诊断：等待事件…";
    [panel addSubview:diag];
    self.diagLabel = diag;

    UIButton *refresh = [UIButton buttonWithType:UIButtonTypeSystem];
    refresh.frame = CGRectMake(16, 330, (pw - 48) / 2.0, 44);
    refresh.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    refresh.layer.cornerRadius = 10;
    [refresh setTitle:@"检查更新" forState:UIControlStateNormal];
    [refresh setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [refresh addTarget:self action:@selector(fetchConfig) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:refresh];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(32 + (pw - 48) / 2.0, 330, (pw - 48) / 2.0, 44);
    close.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    close.layer.cornerRadius = 10;
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [close addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:close];

    // Drag strip across the panel top: drag there to move the whole panel.
    UIView *dragStrip = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pw, 110)];
    dragStrip.backgroundColor = [UIColor clearColor];
    UIPanGestureRecognizer *panelPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPanelPan:)];
    [dragStrip addGestureRecognizer:panelPan];
    [panel addSubview:dragStrip];

    [self fetchConfig];
    [self installProbes];
}

- (void)onPanelPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.window];
    CGPoint c = self.panel.center;
    c.x += t.x; c.y += t.y;
    self.panel.center = c;
    [g setTranslation:CGPointZero inView:self.window];
}

- (void)logEvent:(NSString *)name {
    NSString *text = nil;
    @synchronized (self) {
        if (!self.events) self.events = [NSMutableArray array];
        static NSString *lastName = nil;
        if (lastName && [lastName isEqualToString:name]) return; // no consecutive duplicates
        lastName = [name copy];
        NSDateFormatter *fmt = [NSDateFormatter new];
        fmt.dateFormat = @"HH:mm:ss";
        NSString *line = [NSString stringWithFormat:@"%@ %@", [fmt stringFromDate:[NSDate date]], name];
        [self.events addObject:line];
        while (self.events.count > 60) [self.events removeObjectAtIndex:0];
        text = [@"登录诊断：\n" stringByAppendingString:[self.events componentsJoinedByString:@"\n"]];
    }
    void (^render)(void) = ^{
        self.diagLabel.text = text;
        if (text.length) [self.diagLabel scrollRangeToVisible:NSMakeRange(text.length - 1, 1)];
    };
    if ([NSThread isMainThread]) {
        render();
    } else {
        dispatch_async(dispatch_get_main_queue(), render);
    }
}

- (void)logEventOnce:(NSString *)key text:(NSString *)text {
    @synchronized (self) {
        if (!self.onceKeys) self.onceKeys = [NSMutableSet set];
        if ([self.onceKeys containsObject:key]) return;
        [self.onceKeys addObject:key];
    }
    [self logEvent:text];
}

typedef void (*ImpV)(id, SEL);
typedef void (*ImpV1)(id, SEL, id);
typedef void (*ImpV2)(id, SEL, id, id);
typedef void (*ImpV2B)(id, SEL, id, id, BOOL);
typedef id (*ImpObj)(id, SEL);
static ImpV   orig_didInitSDKSuccess;
static ImpV2  orig_didLoginSuccessKey;
static ImpV1  orig_didLoginSuccessResult;
static ImpV1  orig_didGetUserInfoOK;
static ImpV1  orig_didGetUserInfoFail;
static ImpV1  orig_didLoginFailure;
static ImpV2B orig_onGameAddiction;
static ImpV2B orig_addiction_GSSDK;
static ImpV2B orig_addiction_Center;
static ImpV2B orig_addiction_Service;

static void rep_didInitSDKSuccess(id s, SEL c) { [[DCMenu shared] logEvent:@"SDK 初始化成功"]; if (orig_didInitSDKSuccess) orig_didInitSDKSuccess(s, c); }
static void rep_didLoginSuccessKey(id s, SEL c, id a, id b) { gSDKImpl = s; gAddictionFired = NO; gSynthDone = NO; gManagerFired = NO; gManagerSynthDone = NO; [[DCMenu shared] logEvent:@"登录成功 (AccessKey)"]; if (orig_didLoginSuccessKey) orig_didLoginSuccessKey(s, c, a, b); }
static void rep_didLoginSuccessResult(id s, SEL c, id a) { gSDKImpl = s; [[DCMenu shared] logEvent:@"登录成功 (Result)"]; if (orig_didLoginSuccessResult) orig_didLoginSuccessResult(s, c, a); }
static void rep_didGetUserInfoOK(id s, SEL c, id a) {
    gSDKImpl = s;
    [[DCMenu shared] logEvent:@"用户信息已拿到"];
    if (orig_didGetUserInfoOK) orig_didGetUserInfoOK(s, c, a);
    if (gFixMode >= 4 && !gSynthDone) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (gAddictionFired || gSynthDone) return;
            gSynthDone = YES;
            Class sdkCls = NSClassFromString(@"GSSDK");
            id sdk = nil;
            if (sdkCls && [sdkCls respondsToSelector:@selector(sharedGSInterface)]) {
                sdk = ((id (*)(id, SEL))objc_msgSend)(sdkCls, @selector(sharedGSInterface));
            }
            if (sdk && orig_addiction_GSSDK) {
                [[DCMenu shared] logEvent:@"已补发防沉迷回调 (5秒未到)"];
                orig_addiction_GSSDK(sdk, @selector(onGameAddiction:data:appRestrictFirst:), nil, nil, NO);
            } else {
                [[DCMenu shared] logEvent:@"补发失败: 拿不到 GSSDK 实例"];
            }
        });
    }
}
static void rep_didGetUserInfoFail(id s, SEL c, id a) { [[DCMenu shared] logEvent:@"用户信息获取失败"]; if (orig_didGetUserInfoFail) orig_didGetUserInfoFail(s, c, a); }
static void rep_didLoginFailure(id s, SEL c, id a) { [[DCMenu shared] logEvent:@"登录失败回调"]; if (orig_didLoginFailure) orig_didLoginFailure(s, c, a); }
static void rep_onGameAddiction(id s, SEL c, id a, id b, BOOL f) { gAddictionFired = YES; gManagerFired = YES; [[DCMenu shared] logEvent:@"防沉迷回调@Manager"]; if (orig_onGameAddiction) orig_onGameAddiction(s, c, a, b, f); }
static void rep_addiction_GSSDK(id s, SEL c, id a, id b, BOOL f) { gAddictionFired = YES; [[DCMenu shared] logEvent:@"防沉迷回调@GSSDK"]; if (orig_addiction_GSSDK) orig_addiction_GSSDK(s, c, a, b, f); }
static void rep_addiction_Center(id s, SEL c, id a, id b, BOOL f) { gAddictionFired = YES; [[DCMenu shared] logEvent:@"防沉迷回调@Center"]; if (orig_addiction_Center) orig_addiction_Center(s, c, a, b, f); }
static void rep_addiction_Service(id s, SEL c, id a, id b, BOOL f) {
    gAddictionFired = YES;
    gService = s;
    [[DCMenu shared] logEvent:@"防沉迷回调@Service"];
    if (orig_addiction_Service) orig_addiction_Service(s, c, a, b, f);
    // The observed chain stalls after Service: the Manager hop never happens.
    // Under mode >= 4, push that last hop ourselves a moment later.
    if (gFixMode >= 4 && !gManagerSynthDone) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (gManagerFired || gManagerSynthDone) return;
            gManagerSynthDone = YES;
            id svc = gService;
            id mgr = nil;
            if (svc && [svc respondsToSelector:@selector(gameAddictionManager)]) {
                mgr = ((id (*)(id, SEL))objc_msgSend)(svc, @selector(gameAddictionManager));
            }
            if (mgr && orig_onGameAddiction) {
                [[DCMenu shared] logEvent:@"已补发防沉迷回调@Manager"];
                orig_onGameAddiction(mgr, @selector(onGameAddiction:data:appRestrictFirst:), nil, nil, NO);
            } else {
                [[DCMenu shared] logEvent:@"补发@Manager失败: 拿不到管理器"];
            }
        });
    }
}

#pragma mark - Observation probes (addiction request / heartbeat)

static ImpObj orig_api_params;
static ImpObj orig_api_url;
static id rep_api_params(id s, SEL c) { [[DCMenu shared] logEventOnce:@"api-params" text:@"防沉迷校验请求已组装"]; return orig_api_params ? orig_api_params(s, c) : nil; }
static id rep_api_url(id s, SEL c) { [[DCMenu shared] logEventOnce:@"api-url" text:@"防沉迷校验地址被读取"]; return orig_api_url ? orig_api_url(s, c) : nil; }
static ImpV orig_hb_start;
static void rep_hb_start(id s, SEL c) { [[DCMenu shared] logEventOnce:@"hb-start" text:@"防沉迷心跳已启动"]; if (orig_hb_start) orig_hb_start(s, c); }
static ImpObj orig_aniVC;
static id rep_aniVC(id s, SEL c) { [[DCMenu shared] logEventOnce:@"ani-vc" text:@"SDK防沉迷页被读取"]; return orig_aniVC ? orig_aniVC(s, c) : nil; }
typedef BOOL (*ImpBFn)(id, SEL);
static ImpBFn orig_isConnecting;
static BOOL rep_isConnecting(id s, SEL c) { [[DCMenu shared] logEventOnce:@"is-conn" text:@"游戏在查SDK连接状态"]; return orig_isConnecting ? orig_isConnecting(s, c) : NO; }
typedef void (*ImpV1Q)(id, SEL, id, long long);
static ImpV1Q orig_hb_local;
static void rep_hb_local(id s, SEL c, id a, long long q) { [[DCMenu shared] logEventOnce:@"hb-local" text:@"防沉迷心跳已上报"]; if (orig_hb_local) orig_hb_local(s, c, a, q); }

#pragma mark - Apple-login / Game-Center probes (v1.8)
// Both the LC install and a SideStore-signed install stall the same way, and
// both environments lack Apple's official capabilities. Watch the two Apple
// doors to see which one (if any) the game stands at after login.
typedef void (*ImpV3)(id, SEL, id, id, id);
static ImpV3 orig_appleLoginWithVC;
static void rep_appleLoginWithVC(id s, SEL c, id vc, id succ, id fail) { [[DCMenu shared] logEvent:@"苹果登录被启动"]; if (orig_appleLoginWithVC) orig_appleLoginWithVC(s, c, vc, succ, fail); }
typedef void (*ImpV2)(id, SEL, id, id);
static ImpV2 orig_appleModule;
static void rep_appleModule(id s, SEL c, id a, id blk) { [[DCMenu shared] logEvent:@"苹果登录模块被调用"]; if (orig_appleModule) orig_appleModule(s, c, a, blk); }
static ImpV2 orig_appleOK;
static void rep_appleOK(id s, SEL c, id ctl, id auth) { [[DCMenu shared] logEvent:@"苹果授权成功回调"]; if (orig_appleOK) orig_appleOK(s, c, ctl, auth); }
static ImpV2 orig_appleErr;
static void rep_appleErr(id s, SEL c, id ctl, id err) {
    NSString *d = @"苹果授权失败回调";
    if (err) d = [NSString stringWithFormat:@"苹果授权失败: %@/%ld", [(NSError *)err domain], (long)[(NSError *)err code]];
    [[DCMenu shared] logEvent:d];
    if (orig_appleErr) orig_appleErr(s, c, ctl, err);
}
static ImpV orig_performRequests;
static void rep_performRequests(id s, SEL c) { [[DCMenu shared] logEvent:@"苹果授权页被拉起"]; if (orig_performRequests) orig_performRequests(s, c); }
typedef void (*ImpVB)(id, SEL, id);
static ImpVB orig_gcAuth;
static void rep_gcAuth(id s, SEL c, id blk) { [[DCMenu shared] logEvent:@"GameCenter认证被调用"]; if (orig_gcAuth) orig_gcAuth(s, c, blk); }
typedef void (*ImpVBB)(id, SEL, BOOL, id);
static ImpVBB orig_gcAuthForce;
static void rep_gcAuthForce(id s, SEL c, BOOL f, id blk) { [[DCMenu shared] logEvent:@"GameCenter强制认证被调用"]; if (orig_gcAuthForce) orig_gcAuthForce(s, c, f, blk); }
static ImpVB orig_setAuthHandler;
static void rep_setAuthHandler(id s, SEL c, id handler) {
    [[DCMenu shared] logEventOnce:@"gc-handler-set" text:@"GC认证处理器已装上"];
    if (!handler) { if (orig_setAuthHandler) orig_setAuthHandler(s, c, nil); return; }
    void (^origBlock)(id, id) = (void (^)(id, id))handler;
    void (^wrapped)(id, id) = ^(id vc, id err) {
        if (err) [[DCMenu shared] logEvent:[NSString stringWithFormat:@"GC认证回调: 失败 %@/%ld", [(NSError *)err domain], (long)[(NSError *)err code]]];
        else if (vc) [[DCMenu shared] logEvent:@"GC认证回调: 要弹登录界面"];
        else [[DCMenu shared] logEvent:@"GC认证回调: 已认证通过"];
        origBlock(vc, err);
    };
    if (orig_setAuthHandler) orig_setAuthHandler(s, c, [wrapped copy]);
}

#pragma mark - Bridge remainder + network probes (v1.9)
// v1.8 result: Apple/GC probes 8/8 installed, zero Apple/GC events in the
// whole run. The post-announcement wait is elsewhere: watch every remaining
// bridge callback/call and all NSURLSession traffic (request + completion).
static ImpV orig_cb_didExit;
static void rep_cb_didExit(id s, SEL c) { [[DCMenu shared] logEvent:@"桥回调: didExit"]; if (orig_cb_didExit) orig_cb_didExit(s, c); }
static ImpV orig_cb_didGameExit;
static void rep_cb_didGameExit(id s, SEL c) { [[DCMenu shared] logEvent:@"桥回调: didGameExit"]; if (orig_cb_didGameExit) orig_cb_didGameExit(s, c); }
static ImpV orig_cb_didLogout;
static void rep_cb_didLogout(id s, SEL c) { [[DCMenu shared] logEvent:@"桥回调: didLogout"]; if (orig_cb_didLogout) orig_cb_didLogout(s, c); }
static ImpV orig_cb_didCloseCloud;
static void rep_cb_didCloseCloud(id s, SEL c) { [[DCMenu shared] logEvent:@"桥回调: 云存档界面关闭"]; if (orig_cb_didCloseCloud) orig_cb_didCloseCloud(s, c); }
static ImpV orig_cb_didCloseAgree;
static void rep_cb_didCloseAgree(id s, SEL c) { [[DCMenu shared] logEvent:@"桥回调: 协议界面关闭"]; if (orig_cb_didCloseAgree) orig_cb_didCloseAgree(s, c); }
typedef void (*ImpV1)(id, SEL, id);
static ImpV1 orig_cb_cloudFail;
static void rep_cb_cloudFail(id s, SEL c, id e) { [[DCMenu shared] logEvent:@"桥回调: 云存档打开失败"]; if (orig_cb_cloudFail) orig_cb_cloudFail(s, c, e); }
static ImpV1 orig_cb_geetest;
static void rep_cb_geetest(id s, SEL c, id r) { [[DCMenu shared] logEvent:@"桥回调: 极验有结果"]; if (orig_cb_geetest) orig_cb_geetest(s, c, r); }
static ImpV1 orig_cb_payOK;
static void rep_cb_payOK(id s, SEL c, id p) { [[DCMenu shared] logEvent:@"桥回调: 支付成功"]; if (orig_cb_payOK) orig_cb_payOK(s, c, p); }
static ImpV2 orig_cb_payFail;
static void rep_cb_payFail(id s, SEL c, id p, id e) { [[DCMenu shared] logEvent:@"桥回调: 支付失败"]; if (orig_cb_payFail) orig_cb_payFail(s, c, p, e); }
static ImpVB orig_cls_login;
static void rep_cls_login(id s, SEL c, id blk) { [[DCMenu shared] logEvent:@"游戏发起登录调用"]; if (orig_cls_login) orig_cls_login(s, c, blk); }
static ImpV orig_cls_createRole;
static void rep_cls_createRole(id s, SEL c) { [[DCMenu shared] logEvent:@"游戏调用 createRole"]; if (orig_cls_createRole) orig_cls_createRole(s, c); }
static ImpBFn orig_cls_isLoggedIn;
static BOOL rep_cls_isLoggedIn(id s, SEL c) { [[DCMenu shared] logEventOnce:@"is-logged-in" text:@"游戏在查是否已登录"]; return orig_cls_isLoggedIn ? orig_cls_isLoggedIn(s, c) : NO; }
typedef void (*ImpVCP)(id, SEL, const char *, id);
static ImpVCP orig_cls_cloud;
static void rep_cls_cloud(id s, SEL c, const char *p, id blk) { [[DCMenu shared] logEvent:@"游戏调用 openCloudManager"]; if (orig_cls_cloud) orig_cls_cloud(s, c, p, blk); }

static NSString *DCUrlTag(NSURLRequest *req) {
    NSURL *u = [req URL];
    if (!u) return @"(无URL)";
    NSString *hp = [u host] ? [NSString stringWithFormat:@"%@%@", [u host], [u path]] : [u absoluteString];
    return [NSString stringWithFormat:@"%@ %@", [req HTTPMethod] ?: @"GET", hp];
}
typedef id (*ImpReqH)(id, SEL, id, id);
static ImpReqH orig_dataTaskH;
static id rep_dataTaskH(id s, SEL c, id req, id handler) {
    NSString *tag = DCUrlTag((NSURLRequest *)req);
    [[DCMenu shared] logEventOnce:[@"req:" stringByAppendingString:tag] text:[@"请求: " stringByAppendingString:tag]];
    if (!handler) return orig_dataTaskH ? orig_dataTaskH(s, c, req, nil) : nil;
    void (^origH)(id, id, id) = (void (^)(id, id, id))handler;
    void (^wrapped)(id, id, id) = ^(id d, id resp, id err) {
        NSString *st = err ? [NSString stringWithFormat:@"错误%ld", (long)[(NSError *)err code]]
                           : [NSString stringWithFormat:@"%ld", (long)[(NSHTTPURLResponse *)resp statusCode]];
        [[DCMenu shared] logEvent:[NSString stringWithFormat:@"响应: %@ → %@", tag, st]];
        origH(d, resp, err);
    };
    return orig_dataTaskH ? orig_dataTaskH(s, c, req, [wrapped copy]) : nil;
}
typedef id (*ImpReq)(id, SEL, id);
static ImpReq orig_dataTask;
static id rep_dataTask(id s, SEL c, id req) {
    NSString *tag = DCUrlTag((NSURLRequest *)req);
    [[DCMenu shared] logEventOnce:[@"req:" stringByAppendingString:tag] text:[@"请求: " stringByAppendingString:tag]];
    return orig_dataTask ? orig_dataTask(s, c, req) : nil;
}
typedef id (*ImpUpH)(id, SEL, id, id, id);
static ImpUpH orig_uploadH;
static id rep_uploadH(id s, SEL c, id req, id body, id handler) {
    NSString *tag = DCUrlTag((NSURLRequest *)req);
    [[DCMenu shared] logEventOnce:[@"req:" stringByAppendingString:tag] text:[@"请求: " stringByAppendingString:tag]];
    if (!handler) return orig_uploadH ? orig_uploadH(s, c, req, body, nil) : nil;
    void (^origH)(id, id, id) = (void (^)(id, id, id))handler;
    void (^wrapped)(id, id, id) = ^(id d, id resp, id err) {
        NSString *st = err ? [NSString stringWithFormat:@"错误%ld", (long)[(NSError *)err code]]
                           : [NSString stringWithFormat:@"%ld", (long)[(NSHTTPURLResponse *)resp statusCode]];
        [[DCMenu shared] logEvent:[NSString stringWithFormat:@"响应: %@ → %@", tag, st]];
        origH(d, resp, err);
    };
    return orig_uploadH ? orig_uploadH(s, c, req, body, [wrapped copy]) : nil;
}

#pragma mark - Login-fix hooks (behavior switched live by gFixMode)

typedef BOOL (*ImpB)(id, SEL);

#define DC_ADDICTION_HOOK(name) \
  static ImpB orig_##name; \
  static BOOL rep_##name(id s, SEL c) { \
    BOOL v = orig_##name ? orig_##name(s, c) : YES; \
    if (DCAddictionOn() && v) { \
      [[DCMenu shared] logEventOnce:@"fix-addiction" text:@"已拦截 · 防沉迷校验开关"]; \
      return NO; \
    } \
    return v; \
  }

#define DC_REALNAME_HOOK(name) \
  static ImpB orig_##name; \
  static BOOL rep_##name(id s, SEL c) { \
    [[DCMenu shared] logEventOnce:@"rn-read" text:@"实名状态被读取"]; \
    BOOL v = orig_##name ? orig_##name(s, c) : NO; \
    if (DCRealnameOn() && !v) { \
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
DC_REALNAME_HOOK(rn_GSCUserModel)
DC_REALNAME_HOOK(rn_GSCApiConfig)

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

static int DCProbeClass(Class cls, SEL sel, IMP rep, IMP *store) {
    if (!cls) return 0;
    Method m = class_getClassMethod(cls, sel);
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
    int a = 0;
    a += DCProbe(NSClassFromString(@"GSSDK"), @selector(onGameAddiction:data:appRestrictFirst:), (IMP)rep_addiction_GSSDK, (IMP *)&orig_addiction_GSSDK);
    a += DCProbe(NSClassFromString(@"GSSDKCenter"), @selector(onGameAddiction:data:appRestrictFirst:), (IMP)rep_addiction_Center, (IMP *)&orig_addiction_Center);
    a += DCProbe(NSClassFromString(@"GSCGeneralService"), @selector(onGameAddiction:data:appRestrictFirst:), (IMP)rep_addiction_Service, (IMP *)&orig_addiction_Service);
    if (a > 0) [self logEvent:[NSString stringWithFormat:@"防沉迷链探针 %d/3", a]];
    Class apiCls = NSClassFromString(@"GSCGameAddictionApi");
    DCProbe(apiCls, @selector(params), (IMP)rep_api_params, (IMP *)&orig_api_params);
    DCProbe(apiCls, @selector(requestUrl), (IMP)rep_api_url, (IMP *)&orig_api_url);
    DCProbe(NSClassFromString(@"GSCDataManager"), @selector(aniAddictionVC), (IMP)rep_aniVC, (IMP *)&orig_aniVC);
    Class implCls = NSClassFromString(@"BilibiliSDKImpl");
    if (implCls) {
        Method cm = class_getClassMethod(implCls, @selector(isConnecting));
        if (cm) orig_isConnecting = (ImpBFn)method_setImplementation(cm, (IMP)rep_isConnecting);
    }
    Class hbCls = NSClassFromString(@"GSAniaddiction");
    if (hbCls) {
        Method hm = class_getClassMethod(hbCls, @selector(startHeartbeat));
        if (hm) orig_hb_start = (ImpV)method_setImplementation(hm, (IMP)rep_hb_start);
        Method lm = class_getClassMethod(hbCls, @selector(localHeartbeatWithInfo:productId:));
        if (lm) orig_hb_local = (ImpV1Q)method_setImplementation(lm, (IMP)rep_hb_local);
    }
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
    f += DCProbe(NSClassFromString(@"GSCUserModel"), @selector(userRealnameState), (IMP)rep_rn_GSCUserModel, (IMP *)&orig_rn_GSCUserModel);
    f += DCProbe(NSClassFromString(@"GSCApiConfig"), @selector(loginRealNameStatus), (IMP)rep_rn_GSCApiConfig, (IMP *)&orig_rn_GSCApiConfig);
    if (f > 0) [self logEvent:[NSString stringWithFormat:@"修复钩子已装 %d/12", f]];
    int g = 0;
    g += DCProbe(NSClassFromString(@"GSCAppleService"), @selector(loginWithVC:appleSuccess:failure:), (IMP)rep_appleLoginWithVC, (IMP *)&orig_appleLoginWithVC);
    g += DCProbe(NSClassFromString(@"GscAppleLoginModule"), @selector(appleLogin::), (IMP)rep_appleModule, (IMP *)&orig_appleModule);
    g += DCProbe(NSClassFromString(@"GSCAppleAccount"), @selector(authorizationController:didCompleteWithAuthorization:), (IMP)rep_appleOK, (IMP *)&orig_appleOK);
    g += DCProbe(NSClassFromString(@"GSCAppleAccount"), @selector(authorizationController:didCompleteWithError:), (IMP)rep_appleErr, (IMP *)&orig_appleErr);
    g += DCProbe(NSClassFromString(@"ASAuthorizationController"), @selector(performRequests), (IMP)rep_performRequests, (IMP *)&orig_performRequests);
    g += DCProbe(NSClassFromString(@"GSGameCenterManager"), @selector(authenticateWithCompletion:), (IMP)rep_gcAuth, (IMP *)&orig_gcAuth);
    g += DCProbe(NSClassFromString(@"GSGameCenterManager"), @selector(authenticateWithForce:completion:), (IMP)rep_gcAuthForce, (IMP *)&orig_gcAuthForce);
    g += DCProbe(NSClassFromString(@"GKLocalPlayer"), @selector(setAuthenticateHandler:), (IMP)rep_setAuthHandler, (IMP *)&orig_setAuthHandler);
    if (g > 0) [self logEvent:[NSString stringWithFormat:@"苹果/GC探针已装 %d/8", g]];
    int b = 0;
    b += DCProbe(impl, @selector(didExit), (IMP)rep_cb_didExit, (IMP *)&orig_cb_didExit);
    b += DCProbe(impl, @selector(didGameExit), (IMP)rep_cb_didGameExit, (IMP *)&orig_cb_didGameExit);
    b += DCProbe(impl, @selector(didLogout), (IMP)rep_cb_didLogout, (IMP *)&orig_cb_didLogout);
    b += DCProbe(impl, @selector(didCLoseCloudStorageView), (IMP)rep_cb_didCloseCloud, (IMP *)&orig_cb_didCloseCloud);
    b += DCProbe(impl, @selector(didCloseAgreementView), (IMP)rep_cb_didCloseAgree, (IMP *)&orig_cb_didCloseAgree);
    b += DCProbe(impl, @selector(didOpenCloudStorageFailedWithError:), (IMP)rep_cb_cloudFail, (IMP *)&orig_cb_cloudFail);
    b += DCProbe(impl, @selector(didGeetestResult:), (IMP)rep_cb_geetest, (IMP *)&orig_cb_geetest);
    b += DCProbe(impl, @selector(didPaySuccessWithPayment:), (IMP)rep_cb_payOK, (IMP *)&orig_cb_payOK);
    b += DCProbe(impl, @selector(didPayFailureWithPayment:error:), (IMP)rep_cb_payFail, (IMP *)&orig_cb_payFail);
    b += DCProbeClass(impl, @selector(login:), (IMP)rep_cls_login, (IMP *)&orig_cls_login);
    b += DCProbeClass(impl, @selector(createRole), (IMP)rep_cls_createRole, (IMP *)&orig_cls_createRole);
    b += DCProbeClass(impl, @selector(isLoggedIn), (IMP)rep_cls_isLoggedIn, (IMP *)&orig_cls_isLoggedIn);
    b += DCProbeClass(impl, @selector(openCloudManager:callback:), (IMP)rep_cls_cloud, (IMP *)&orig_cls_cloud);
    Class sess = NSClassFromString(@"NSURLSession");
    b += DCProbe(sess, @selector(dataTaskWithRequest:completionHandler:), (IMP)rep_dataTaskH, (IMP *)&orig_dataTaskH);
    b += DCProbe(sess, @selector(dataTaskWithRequest:), (IMP)rep_dataTask, (IMP *)&orig_dataTask);
    b += DCProbe(sess, @selector(uploadTaskWithRequest:fromData:completionHandler:), (IMP)rep_uploadH, (IMP *)&orig_uploadH);
    if (b > 0) [self logEvent:[NSString stringWithFormat:@"桥+网络探针已装 %d/16", b]];
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
    NSString *appliedBadge = cfg[@"badge"];
    self.statusLabel.text = [appliedBadge isKindOfClass:[NSString class]] && appliedBadge.length
        ? [NSString stringWithFormat:@"已连上更新通道 · %@ · %@", [fmt stringFromDate:[NSDate date]], appliedBadge]
        : [NSString stringWithFormat:@"已连上更新通道 · %@", [fmt stringFromDate:[NSDate date]]];
}

- (void)fetchConfig {
    // Cache-busting query: raw.githubusercontent caches up to 5 min otherwise,
    // which delayed a fix_mode flip by a full test cycle.
    NSString *urlStr = [NSString stringWithFormat:@"%@?t=%lld", kDCConfigURL,
                        (long long)[[NSDate date] timeIntervalSince1970]];
    NSURL *url = [NSURL URLWithString:urlStr];
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
