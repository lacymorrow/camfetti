import AppKit
import Observation
import SwiftUI

/// Closing the last window never quits CamFetti. The Dock icon or the menu bar brings it back.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the main window the first time it appears. Opens it again after it was closed.
    @MainActor static var openMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if AWAY
        Task { @MainActor in AwayController.shared.resume() }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { Self.openMainWindow?() } }
        return true
    }
}

#if DEBUG
extension MacAppDelegate {
    /// `-closeWindowAfter <seconds>` closes the main window by itself, to test reopening without a click.
    @MainActor private static var closed = false

    @MainActor static func closeMainWindowIfAsked() {
        guard !closed else { return }
        closed = true
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-closeWindowAfter"), i + 1 < args.count, let seconds = Double(args[i + 1]) else { return }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            NSApp.windows.filter { $0.canBecomeMain }.forEach { $0.close() }
        }
    }
}
#endif

/// Lets the app delegate reopen the main window from a Dock click after it was closed.
struct MainWindowHook: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear {
                MacAppDelegate.openMainWindow = {
                    NSApp.activate()
                    openWindow(id: "main")
                }
                #if DEBUG
                MacAppDelegate.closeMainWindowIfAsked()
                #endif
            }
    }
}
