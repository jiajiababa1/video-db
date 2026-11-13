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
                .padding(.bottom, 62)
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

    @State private var tabSel = 0
    @State private var epochs = [0, 0, 0, 0, 0]

    /// 再次点击当前 Tab: 把该 Tab 的导航栈换新 (回到根页+顶部, 数据从缓存秒开再刷新),
    /// 这是 iOS 通用习惯 ("点当前 Tab 回顶部")。
    private var tabBinding: Binding<Int> {
        Binding(get: { tabSel }, set: { newVal in
            if newVal == tabSel { epochs[newVal] += 1 }
            tabSel = newVal
        })
    }

    private var mainTabs: some View {
        TabView(selection: tabBinding) {
            NavigationView { HomeView() }
                .navigationViewStyle(.stack)
                .id(epochs[0])
                .tabItem { Label("首页", systemImage: "house.fill") }
                .tag(0)
            NavigationView { SectionsView() }
                .navigationViewStyle(.stack)
                .id(epochs[1])
                .tabItem { Label("栏目", systemImage: "square.grid.2x2.fill") }
                .tag(1)
            NavigationView { FriendsView() }
                .navigationViewStyle(.stack)
                .id(epochs[2])
                .tabItem { Label("好友", systemImage: "person.2.fill") }
                .badge(notices.socialBadge)
                .tag(2)
            NavigationView { LibraryView() }
                .navigationViewStyle(.stack)
                .id(epochs[3])
                .tabItem { Label("片库", systemImage: "books.vertical.fill") }
                .tag(3)
            NavigationView { MeView() }
                .navigationViewStyle(.stack)
                .id(epochs[4])
                .tabItem { Label("我的", systemImage: "person.crop.circle.fill") }
                .badge(notices.meBadge)
                .tag(4)
        }
        .accentColor(Theme.gold2)
    }
}
