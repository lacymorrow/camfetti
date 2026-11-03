// Away is a paid service that has not launched. It compiles only with the AWAY flag (Debug builds),
// so App Store builds carry none of it.
#if AWAY
import AppKit
import Observation
import os
import ServiceManagement
import SwiftUI

/// What the menu shows: one line, in plain words.
enum AwayLine: Equatable {
    case off, connecting, online, offline, sleeping

    var text: String {
        switch self {
        case .off: "Away is off"
        case .connecting: "Connecting…"
        case .online: "Your iPhone can watch your cameras away from home"
        case .offline: "Can't reach CamFetti. Trying again."
        case .sleeping: "Your Mac is going to sleep, so Away will pause"
        }
    }

    var symbol: String {
        switch self {
        case .off: "moon.zzz"
        case .connecting: "ellipsis.circle"
        case .online: "checkmark.circle.fill"
        case .offline: "exclamationmark.triangle.fill"
        case .sleeping: "powersleep"
        }
    }

    var tint: Color {
        switch self {
        case .online: Theme.accent
        case .offline, .sleeping: Theme.warning
        case .off, .connecting: Theme.idle
        }
    }
}

/// Runs Away on the Mac. While it is on, the Mac stays awake, CamFetti starts at login, and
/// the app keeps running with no window open.
@MainActor @Observable
final class AwayController {
    static let shared = AwayController()

    private static let key = "away.mac"
    private let service = BridgeService()
    private var activity: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []
    private let log = Logger(subsystem: "sh.lacy.camfetti", category: "away")
    private(set) var sleeping = false

    var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            UserDefaults.standard.set(isOn, forKey: Self.key)
            apply()
        }
    }

    init() {
        isOn = UserDefaults.standard.bool(forKey: Self.key) && AwayConfig.isAvailable
    }

    var line: AwayLine {
        guard isOn else { return .off }
        if sleeping { return .sleeping }
        return switch service.status {
        case .connecting: .connecting
        case .online: .online
        case .offline: .offline
        }
    }

    /// Called once at launch: picks up where the person left it.
    func resume() {
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sleeping = true }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sleeping = false }
            },
        ]
        apply()
    }

    private func apply() {
        if isOn {
            service.start()
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleSystemSleepDisabled, .userInitiated], reason: "CamFetti Away is on")
            }
            setLaunchAtLogin(true)
        } else {
            service.stop()
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
            setLaunchAtLogin(false)
        }
    }

    /// Tied to Away, so there is no separate setting to forget about.
    private func setLaunchAtLogin(_ on: Bool) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-awayNoLoginItem") { return }
        #endif
        let item = SMAppService.mainApp
        do {
            if on, item.status != .enabled { try item.register() }
            if !on, item.status == .enabled { try item.unregister() }
        } catch {
            log.error("login item: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
