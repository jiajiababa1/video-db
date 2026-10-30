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

    private var mainTabs: some View {
        TabView {
            NavigationView { HomeView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("首页", systemImage: "house.fill") }
            NavigationView { SectionsView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("栏目", systemImage: "square.grid.2x2.fill") }
            NavigationView { FriendsView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("好友", systemImage: "person.2.fill") }
                .badge(notices.socialBadge)
            NavigationView { LibraryView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("片库", systemImage: "books.vertical.fill") }
            NavigationView { MeView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("我的", systemImage: "person.crop.circle.fill") }
                .badge(notices.meBadge)
        }
        .accentColor(Theme.gold2)
    }
}
