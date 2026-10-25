import SwiftUI

@main
struct VideoDBApp: App {
    @StateObject private var library = Library()
    @StateObject private var session = Session.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(session)
                .preferredColorScheme(.dark)
        }
    }
}
