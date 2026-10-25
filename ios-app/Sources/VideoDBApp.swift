import SwiftUI

@main
struct VideoDBApp: App {
    @StateObject private var library = Library()
    @StateObject private var session = Session.shared
    @StateObject private var bridge = Bridge.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(session)
                .environmentObject(bridge)
                .preferredColorScheme(.dark)
        }
    }
}
