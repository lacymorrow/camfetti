import Foundation

/// Aptabase telemetry (LAC-7620). Five events and nothing else: app_open, feature_used(name),
/// purchase_started, purchase_completed, error(class). No camera names, addresses, passwords,
/// video, or identifiers beyond Aptabase's own session id. One switch in Settings, default on,
/// read before every event, so turning it off stops events at once.
///
/// Apple TV has no Settings screen and so no way to opt out. It therefore never sends anything.
enum Telemetry {
    /// Aptabase Cloud US app key for CamFetti. Ships in the binary by design; not a secret.
    static let appKey = "A-US-4230698939"
    static let endpoint = URL(string: "https://us.aptabase.com/api/v0/event")!
    static let defaultsKey = "telemetryEnabled"
    static let sdkVersion = "camfetti-http@1"

    enum Event: Equatable, Sendable {
        case appOpen
        case featureUsed(String)
        case purchaseStarted
        case purchaseCompleted
        case error(String)

        var name: String {
            switch self {
            case .appOpen: "app_open"
            case .featureUsed: "feature_used"
            case .purchaseStarted: "purchase_started"
            case .purchaseCompleted: "purchase_completed"
            case .error: "error"
            }
        }

        var props: [String: String]? {
            switch self {
            case .featureUsed(let name): ["name": name]
            case .error(let errorClass): ["class": errorClass]
            default: nil
            }
        }
    }

    /// Default on, except where the person has no way to turn it off.
    static var isEnabled: Bool {
        #if os(tvOS)
        false
        #else
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
        #endif
    }

    static func appOpen() { send(.appOpen) }
    static func feature(_ name: String) { send(.featureUsed(name)) }
    static func purchaseStarted() { send(.purchaseStarted) }
    static func purchaseCompleted() { send(.purchaseCompleted) }
    /// Pass a class name such as "URLError", never a message.
    static func error(_ errorClass: String) { send(.error(errorClass)) }

    static func send(_ event: Event) {
        guard isEnabled else { return }
        Task.detached(priority: .utility) { await Sender.shared.send(event) }
    }

    /// The request for one event. Pure, so a test can read exactly what would leave the device.
    static func makeRequest(_ event: Event, sessionId: String, now: Date) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(appKey, forHTTPHeaderField: "App-Key")
        let info = Bundle.main.infoDictionary
        var body: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: now),
            "sessionId": sessionId,
            "eventName": event.name,
            "systemProps": [
                "isDebug": isDebugBuild,
                "locale": Locale.current.identifier,
                "osName": osName,
                "appVersion": info?["CFBundleShortVersionString"] as? String ?? "",
                "appBuildNumber": info?["CFBundleVersion"] as? String ?? "",
                "sdkVersion": sdkVersion,
            ] as [String: Any],
        ]
        if let props = event.props { body["props"] = props }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private static var osName: String {
        #if os(macOS)
        "macOS"
        #elseif os(visionOS)
        "visionOS"
        #else
        "iOS"
        #endif
    }

    /// Session ids rotate after an hour of inactivity, as Aptabase's own SDKs do.
    private actor Sender {
        static let shared = Sender()
        private var sessionId = UUID().uuidString
        private var touchedAt = Date()

        func send(_ event: Event) async {
            let now = Date()
            if now.timeIntervalSince(touchedAt) > 3600 { sessionId = UUID().uuidString }
            touchedAt = now
            let request = Telemetry.makeRequest(event, sessionId: sessionId, now: now)
            // Offline or blocked: drop the event. Telemetry never changes what the app does.
            _ = try? await URLSession.shared.data(for: request)
        }
    }
}
