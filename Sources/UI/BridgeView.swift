import SwiftUI

/// Full screen while this device is the Away bridge. Meant to sit on a charger for weeks,
/// so it dims itself and keeps the screen from locking.
struct BridgeView: View {
    @Environment(AppModel.self) private var model
    @State private var service = BridgeService()
    @State private var dimmed = false
    @State private var savedBrightness: CGFloat = 0.5
    @State private var idleTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, options: .repeating, isActive: service.status == .connecting)
            VStack(spacing: 10) {
                Text(title).font(.title2.bold())
                Text(detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if let since = service.onlineSince {
                    Text(Self.uptime(from: since, to: context.date))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("bridge-uptime")
                }
            }
            if service.activeStreams > 0 {
                Text(service.activeStreams == 1 ? "1 camera playing" : "\(service.activeStreams) cameras playing")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Turn Off Bridge", role: .destructive) { model.bridgeMode = false }
                .buttonStyle(.bordered)
                .padding(.bottom, 24)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onTapGesture { wake() }
        .onAppear {
            model.stopAll()
            UIApplication.shared.isIdleTimerDisabled = true
            savedBrightness = screen?.brightness ?? 0.5
            service.start()
            wake()
        }
        .onDisappear {
            idleTask?.cancel()
            service.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            screen?.brightness = savedBrightness
        }
        .statusBarHidden(dimmed)
    }

    static func uptime(from since: Date, to now: Date) -> String {
        let seconds = now.timeIntervalSince(since)
        guard seconds >= 60 else { return "Online for less than a minute" }
        let format = DateComponentsFormatter()
        format.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        format.unitsStyle = .short
        return "Online for \(format.string(from: seconds) ?? "")"
    }

    private var screen: UIScreen? {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen
    }

    /// Full brightness for 20 seconds after a tap, then as dim as the screen goes.
    private func wake() {
        dimmed = false
        screen?.brightness = savedBrightness
        idleTask?.cancel()
        idleTask = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            dimmed = true
            screen?.brightness = 0
        }
    }

    private var symbol: String {
        switch service.status {
        case .online: "antenna.radiowaves.left.and.right"
        case .connecting: "antenna.radiowaves.left.and.right"
        case .offline: "antenna.radiowaves.left.and.right.slash"
        }
    }

    private var tint: Color {
        switch service.status {
        case .online: Brand.pink
        case .connecting: .secondary
        case .offline: .orange
        }
    }

    private var title: String {
        switch service.status {
        case .online: "Bridge is on"
        case .connecting: "Connecting…"
        case .offline: "Can't reach CamFetti"
        }
    }

    private var detail: String {
        switch service.status {
        case .online: "Leave this plugged in with CamFetti open. Your cameras can be watched away from home."
        case .connecting: "Reaching the CamFetti relay."
        case let .offline(reason): "\(reason). Trying again on its own."
        }
    }
}
