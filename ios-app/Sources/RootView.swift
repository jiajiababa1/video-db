import SwiftUI

/// 全屏页 (刷视频/播放页) 在场时隐藏悬浮底栏: 胶囊浮在所有页面之上,
/// 会压住刷视频自己的进度条和播放页底部 —— 这类页面本来就该独占屏幕 (仿抖音)。
final class ChromeState: ObservableObject {
    static let shared = ChromeState()
    @Published var hidden = false
}

struct RootView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var library: Library
    @EnvironmentObject var bridge: Bridge
    @ObservedObject private var notices = NoticeCenter.shared
    @ObservedObject private var chrome = ChromeState.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var banSnoozed = false    // 封禁弹窗点了"下次再弹" (本次运行内不再弹)
    @State private var showBanAppeal = false
    @State private var expiredSnoozed = false  // 登录失效弹窗点了"稍后再说" (本次运行内不再弹)

    var body: some View {
        Group {
            if session.gatePassed {
                mainTabs
            } else {
                GateView()
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if let note = library.undoNote {
                HStack(spacing: 12) {
                    Text(note).font(.system(size: 13.5)).foregroundColor(Theme.text)
                        .lineLimit(1)
                    Spacer()
                    Button("撤销") { library.performUndo() }
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Theme.gold2)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .glassPanel(14, live: true, shadow: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 100)
            }
        }
        .task {
            bridge.bootstrap()
            await session.validateSession()
            library.activateUser(session.username)
            // 历史每天一清: 跨天先清本地+云端, 再做拉取合并, 免得刚清完又被云端合回来
            if library.rollDayIfNeeded(), session.isLoggedIn, let u = session.username {
                await CloudSync.clearHistory(user: u)
            }
            if session.isLoggedIn {
                await TokenVault.pullTokens(session: session)
                await ConfigSync.pull(session: session, library: library)
                await CloudSync.pullMerge(into: library, session: session)
            }
            await notices.refresh(session: session)
        }
        .onAppear {
            library.onMutate = { ConfigSync.schedulePush(session: session, library: library) }
        }
        .onChange(of: session.isLoggedIn) { logged in
            if logged {
                Task {
                    await TokenVault.pullTokens(session: session)
                    await ConfigSync.pull(session: session, library: library)
                    await CloudSync.pullMerge(into: library, session: session)
                }
            }
        }
        .onChange(of: session.accountGeneration) { _ in
            // 登录/切换/退出账号: 先把片库切到该账号自己的存档 (各账号数据互不串),
            // 再按新账号重拉云端数据 (isLoggedIn 不变时也要做, 所以走 generation 而不是 isLoggedIn)
            library.activateUser(session.username)
            if session.isLoggedIn {
                Task {
                    await TokenVault.pullTokens(session: session)
                    await ConfigSync.pull(session: session, library: library)
                    await CloudSync.pullMerge(into: library, session: session)
                    await notices.refresh(session: session)
                }
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                if library.rollDayIfNeeded(), session.isLoggedIn, let u = session.username {
                    Task { await CloudSync.clearHistory(user: u) }
                }
                Task { await notices.refresh(session: session) }
            }
        }
        // 封禁弹窗: 被封禁就一直弹, 只有点按钮才消 —— "联系站主申诉"去申诉,
        // "下次再弹"本次运行内不再弹 (下次打开 App 还会弹); 解封后自动消失。
        .alert("你的账号已被封禁", isPresented: Binding(
            get: { session.isBanned && !banSnoozed },
            set: { if !$0 { banSnoozed = true } }
        )) {
            Button("联系站主申诉") { showBanAppeal = true }
            Button("下次再弹") { banSnoozed = true }
        } message: {
            Text("封禁期间不能评论、发弹幕、发私信或发布任何内容。申诉每小时限发一条。")
        }
        .sheet(isPresented: $showBanAppeal) {
            NavigationView { AppealView() }
        }
        // 登录失效弹窗: 服务端明确判令牌已作废 (常见: 同一台设备登录/注册了别的账号,
        // 把这个账号的设备会话顶掉, 切回来时拿的是已作废的旧令牌)。旧版装作还登录着,
        // 表现就是令牌拉不到、生成兑换码没反应 —— 现在明说并给一键重登入口。
        .alert("登录已失效", isPresented: Binding(
            get: { session.sessionExpired && !expiredSnoozed },
            set: { if !$0 { expiredSnoozed = true } }
        )) {
            Button("重新登录") {
                session.sessionExpired = false
                session.signOutLocal()
            }
            Button("稍后再说") { expiredSnoozed = true }
        } message: {
            Text("这个账号的登录令牌已被服务端作废，重新用密码登录一次即可恢复。令牌、片库都跟账号走，不会丢。")
        }
        .onChange(of: session.sessionExpired) { expired in
            if !expired { expiredSnoozed = false }
        }
    }

    // MARK: - 四栏布局: 首页(总揽) / 信息 / 朋友 / 我的
    // v4.1 改悬浮胶囊底栏 (用户点名仿抖音截图): 胶囊只占自身大小、不整屏拦截点击;
    // 各页加底部安全区避让。首页 = 总揽页 (货架/片库/栏目三段), 刷视频是「栏目」
    // 里的一条入口, 点进去才刷 (不再是首页本体, 也没有弹窗货架, 杜绝声音重叠)。
    @State private var tabSel = 0
    @State private var epochs = [0, 0, 0, 0]
    @State private var visited: Set<Int> = [0]

    /// 再次点击当前项: 把该页导航栈换新 (回到根页+顶部), iOS 通用习惯。
    private func selectTab(_ i: Int) {
        if i == tabSel {
            epochs[i] += 1
        } else {
            tabSel = i
            visited.insert(i)
        }
        Haptics.light()
    }

    private var mainTabs: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                if visited.contains(0) {
                    tabPage(0) { CatalogView() }
                        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 64) }
                }
                if visited.contains(1) {
                    tabPage(1) { InboxView() }
                        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 64) }
                }
                if visited.contains(2) {
                    tabPage(2) { FriendsView() }
                        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 64) }
                }
                if visited.contains(3) {
                    tabPage(3) { ProfileHomeView() }
                        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 64) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            floatingDock
        }
    }

    @ViewBuilder
    private func tabPage<V: View>(_ idx: Int, @ViewBuilder content: () -> V) -> some View {
        NavigationView { content() }
            .navigationViewStyle(.stack)
            .id(epochs[idx])
            .environment(\.vdbTabActive, tabSel == idx)
            .opacity(tabSel == idx ? 1 : 0)
            .allowsHitTesting(tabSel == idx)
            .zIndex(tabSel == idx ? 1 : 0)
    }

    /// 悬浮胶囊底栏 (仿抖音): 半透明黑胶囊浮在内容上; 胶囊之外的区域不拦截点击
    private var floatingDock: some View {
        HStack(spacing: 0) {
            dockItem(0, icon: "house.fill", label: "首页")
            dockItem(1, icon: "bell.fill", label: "信息", badge: notices.socialBadge)
            dockItem(2, icon: "person.2.fill", label: "朋友")
            dockItem(3, icon: "person.crop.circle.fill", label: "我的", badge: notices.meBadge)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.55))
                .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.5), radius: 14, y: 5)
        )
        .padding(.horizontal, 56)
        .padding(.bottom, 8)
        .opacity(chrome.hidden ? 0 : 1)
        .allowsHitTesting(!chrome.hidden)
        .animation(.easeOut(duration: 0.2), value: chrome.hidden)
    }

    private func dockItem(_ idx: Int, icon: String, label: String, badge: Int = 0) -> some View {
        Button { selectTab(idx) } label: {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 20))
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.red)
                            .clipShape(Capsule())
                            .offset(x: 11, y: -5)
                    }
                }
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(tabSel == idx ? Theme.gold2 : Theme.sub)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 首页总揽: 货架 / 片库 / 栏目三段 (v4.1 起是首页本体, 不再是弹窗;
/// 刷视频是栏目段里的一条入口, 点进去才开始刷)
struct CatalogView: View {
    @State private var seg = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("片库", selection: $seg) {
                Text("货架").tag(0)
                Text("片库").tag(1)
                Text("栏目").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(8)
            switch seg {
            case 1: LibraryView()
            case 2: SectionsView()
            default: HomeView()
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("首页")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 当前 Tab 是否处于前台 (刷视频据此自动暂停/恢复)
struct VDBTabActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var vdbTabActive: Bool {
        get { self[VDBTabActiveKey.self] }
        set { self[VDBTabActiveKey.self] = newValue }
    }
}
