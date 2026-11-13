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

    // MARK: - v3.0 自定义悬浮 Dock 导航 (替代系统 TabView 的模板感)
    // 五个目的地: 首页 / 片库 / 刷视频(中间主按钮) / 好友 / 我的。
    // 栏目页收进首页的「全部栏目」入口。页面懒挂载: 首次点开才创建, 之后保持状态。
    @State private var tabSel = 0
    @State private var epochs = [0, 0, 0, 0, 0]
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
        ZStack {
            if visited.contains(0) { tabPage(0, inset: true) { HomeView() } }
            if visited.contains(1) { tabPage(1, inset: true) { LibraryView() } }
            if visited.contains(2) { tabPage(2, inset: false) { SwipeFeedView(dockInset: true) } }
            if visited.contains(3) { tabPage(3, inset: true) { FriendsView() } }
            if visited.contains(4) { tabPage(4, inset: true) { MeView() } }
        }
        .overlay(alignment: .bottom) { dock }
    }

    @ViewBuilder
    private func tabPage<V: View>(_ idx: Int, inset: Bool, @ViewBuilder content: () -> V) -> some View {
        NavigationView { content() }
            .navigationViewStyle(.stack)
            .id(epochs[idx])
            .environment(\.vdbTabActive, tabSel == idx)
            .opacity(tabSel == idx ? 1 : 0)
            .allowsHitTesting(tabSel == idx)
            .zIndex(tabSel == idx ? 1 : 0)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if inset { Color.clear.frame(height: 76) }
            }
    }

    private var dock: some View {
        // 玻璃条与主按钮分开叠放: 玻璃条自身带圆角裁剪, 主按钮必须在裁剪之外,
        // 否则凸起的圆会被切掉一截 (v3.0 的按钮位置 bug)
        ZStack {
            HStack(spacing: 0) {
                dockItem(0, icon: "house.fill", label: "首页")
                dockItem(1, icon: "books.vertical.fill", label: "片库")
                Color.clear
                    .frame(maxWidth: .infinity)
                dockItem(3, icon: "person.2.fill", label: "好友", badge: notices.socialBadge)
                dockItem(4, icon: "person.crop.circle.fill", label: "我的", badge: notices.meBadge)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .glassPanel(24, live: true, shadow: true)
            Button { selectTab(2) } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 54, height: 54)
                    .background(Theme.goldGradient)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .offset(y: -16)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
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
