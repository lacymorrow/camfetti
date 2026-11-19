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
            try? await Task.sleep(for: .seconds(1))
            // What App Review sees with no window open: every item in the Window menu.
            let menu = NSApp.windowsMenu ?? NSApp.mainMenu?.items.first { $0.title == "Window" }?.submenu
            let titles = menu?.items.map { $0.isSeparatorItem ? "-" : $0.title } ?? []
            NSLog("windowMenu: %@", titles.joined(separator: " | "))
            // -reopenFromMenu <title> picks that item the way a click would, then reports the windows.
            if let j = args.firstIndex(of: "-reopenFromMenu"), j + 1 < args.count,
               let menu, let index = menu.items.firstIndex(where: { $0.title == args[j + 1] }) {
                menu.performActionForItem(at: index)
                try? await Task.sleep(for: .seconds(1))
                NSLog("windowsAfterReopen: %d visible", NSApp.windows.filter { $0.canBecomeMain && $0.isVisible }.count)
            }
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

/// Window > CamFetti (⌘0) brings the main window back after it was closed. App Review
/// asks for it, and it's the menu people look in when the window is gone.
struct MainWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(before: .windowList) {
            Button("CamFetti") {
                NSApp.activate()
                openWindow(id: "main")
            }
            .keyboardShortcut("0", modifiers: .command)
            Divider()
        }
    }
}
