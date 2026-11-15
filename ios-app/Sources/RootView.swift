import SwiftUI

struct RootView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var library: Library
    @EnvironmentObject var bridge: Bridge
    @ObservedObject private var notices = NoticeCenter.shared
    @Environment(\.scenePhase) private var scenePhase

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
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task { await notices.refresh(session: session) }
            }
        }
    }

    // MARK: - v4.0 四栏布局 (抖音式): 首页(刷视频) / 信息 / 朋友 / 我的
    // 底栏不再悬浮覆盖内容, 改成布局内的一条: 页面区到此为止, 任何按钮都不会被它挡住
    // (v3.x 悬浮 Dock 遮挡底部按钮的问题就来自覆盖式布局)。
    // 老「首页货架 / 片库 / 栏目」收进刷视频页左上角的片库入口 (CatalogView)。
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
        VStack(spacing: 0) {
            ZStack {
                if visited.contains(0) { tabPage(0) { SwipeFeedView(dockInset: true) } }
                if visited.contains(1) { tabPage(1) { InboxView() } }
                if visited.contains(2) { tabPage(2) { FriendsView() } }
                if visited.contains(3) { tabPage(3) { ProfileHomeView() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            dock
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

    private var dock: some View {
        HStack(spacing: 0) {
            dockItem(0, icon: "house.fill", label: "首页")
            dockItem(1, icon: "bell.fill", label: "信息", badge: notices.socialBadge)
            dockItem(2, icon: "person.2.fill", label: "朋友")
            dockItem(3, icon: "person.crop.circle.fill", label: "我的", badge: notices.meBadge)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Theme.bg)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
        }
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

/// 片库总入口: 老首页货架 / 片库 / 栏目三页收纳 (刷视频页左上角按钮打开)
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
            .padding(12)
            switch seg {
            case 1: LibraryView()
            case 2: SectionsView()
            default: HomeView()
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("片库")
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
