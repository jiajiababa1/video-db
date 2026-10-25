import SwiftUI

struct RootView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var library: Library
    @EnvironmentObject var bridge: Bridge

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
                await CloudSync.pullMerge(into: library, session: session)
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
            NavigationView { LibraryView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("片库", systemImage: "books.vertical.fill") }
            NavigationView { MeView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("我的", systemImage: "person.crop.circle.fill") }
        }
        .accentColor(Theme.gold2)
    }
}
