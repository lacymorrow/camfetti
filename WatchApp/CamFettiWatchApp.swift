import SwiftUI

@main
struct CamFettiWatchApp: App {
    @State private var model = WatchModel()

    init() {
        WatchSession.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(model)
                .tint(Theme.accent)
        }
    }
}
