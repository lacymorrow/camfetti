import Foundation

/// A camera the person has added. Secrets live in the Keychain, never here.
struct Camera: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case thingino
        case onvif
        case rtsp
    }

    struct Onvif: Codable, Hashable, Sendable {
        var deviceURL: String
        var mediaURL: String?
        var ptzURL: String?
        var profileToken: String?
        var snapshotURL: String?
    }

    var id: UUID = UUID()
    var name: String
    var kind: Kind
    /// Host on the home network (IP or name).
    var host: String
    /// Optional second address used away from home: a Tailscale name or 100.x address,
    /// a WireGuard address, or a public hostname.
    var awayHost: String?
    /// RTSP URLs without credentials. `subURL` is the light stream used in the grid.
    var mainURL: String
    var subURL: String?
    /// RTSP username. The password is in the Keychain.
    var username: String
    /// Thingino web UI port and streamer name (prudynt, raptor, strero).
    var httpPort: Int?
    var streamer: String?
    var onvif: Onvif?
    var canPan: Bool = false
    var addedAt: Date = Date()

    var gridURL: String { subURL ?? mainURL }

    /// Base URL of the camera's web API, for Thingino.
    func webBase(host override: String? = nil) -> URL? {
        let h = override ?? host
        let port = httpPort ?? 80
        return URL(string: port == 80 ? "http://\(Self.bracket(h))" : "http://\(Self.bracket(h)):\(port)")
    }

    static func bracket(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }
}

extension Camera {
    /// Same URL with its host swapped, used to reach the camera at its away address.
    static func replacingHost(in url: String, with host: String) -> String {
        guard var comps = URLComponents(string: url) else { return url }
        comps.host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return comps.string ?? url
    }

    /// Strips user:password from a URL so it can be stored safely.
    static func strippingCredentials(_ url: String) -> (url: String, user: String?, password: String?) {
        guard var comps = URLComponents(string: url) else { return (url, nil, nil) }
        let user = comps.user.flatMap { $0.removingPercentEncoding ?? $0 }
        let pass = comps.password.flatMap { $0.removingPercentEncoding ?? $0 }
        comps.user = nil
        comps.password = nil
        return (comps.string ?? url, user, pass)
    }
}
