// DCMenu.m — Dead Cells (Bilibili v3.5.13) floating menu tweak for LiveContainer
// Minimal v1: floating ball + panel + hot-update channel ONLY.
// Feature definitions (title / badge / notice / feature list) come from a
// remote JSON; updating that JSON changes the menu with no file replacement.
// Remote config: https://api.github.com/repos/jiajiababa1/video-db/contents/dc-menu/menu.json
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString * const kDCConfigURL = @"https://api.github.com/repos/jiajiababa1/video-db/contents/dc-menu/menu.json";
static NSString * const kDCBundledBadge = @"版本 A";

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
@property (nonatomic, strong) NSDictionary *config;
@property (nonatomic, assign) BOOL setupDone;
+ (instancetype)shared;
- (void)setup;
- (void)fetchConfig;
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
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake((bounds.size.width - pw) / 2.0, bounds.size.height * 0.22, pw, 300)];
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

    UIButton *refresh = [UIButton buttonWithType:UIButtonTypeSystem];
    refresh.frame = CGRectMake(16, 216, (pw - 48) / 2.0, 44);
    refresh.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    refresh.layer.cornerRadius = 10;
    [refresh setTitle:@"检查更新" forState:UIControlStateNormal];
    [refresh setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [refresh addTarget:self action:@selector(fetchConfig) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:refresh];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(32 + (pw - 48) / 2.0, 216, (pw - 48) / 2.0, 44);
    close.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    close.layer.cornerRadius = 10;
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [close addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:close];

    [self fetchConfig];
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
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"HH:mm:ss";
    self.statusLabel.text = [NSString stringWithFormat:@"已连上更新通道 · %@", [fmt stringFromDate:[NSDate date]]];
}

- (void)fetchConfig {
    NSURL *url = [NSURL URLWithString:kDCConfigURL];
    if (!url) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData
                                                   timeoutInterval:15];
    [req setValue:@"application/vnd.github.raw+json" forHTTPHeaderField:@"Accept"];
    [req setValue:@"DCMenu/1.0" forHTTPHeaderField:@"User-Agent"];
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                     completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            DCMenu *self_ = weakSelf;
            if (!self_) return;
            if (err || !data) {
                self_.statusLabel.text = @"更新检查失败 · 显示本地版";
                return;
            }
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) {
                NSString *content = json[@"content"];
                if ([content isKindOfClass:[NSString class]]) {
                    // Standard API response (not raw): base64 payload
                    NSData *decoded = [[NSData alloc] initWithBase64EncodedString:content
                                                                            options:NSDataBase64DecodingIgnoreUnknownCharacters];
                    id inner = decoded ? [NSJSONSerialization JSONObjectWithData:decoded options:0 error:nil] : nil;
                    if ([inner isKindOfClass:[NSDictionary class]]) {
                        [self_ applyConfig:inner];
                        return;
                    }
                } else {
                    [self_ applyConfig:json];
                    return;
                }
            }
            self_.statusLabel.text = @"更新内容解析失败 · 显示本地版";
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
