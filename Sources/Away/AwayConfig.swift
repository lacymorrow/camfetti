import CryptoKit
import Foundation
import Network

/// Away spike settings. Nothing here shows up unless a room token was installed with
/// `-awayRoom <token>` at launch, so store builds and other people never see it.
enum AwayConfig {
    static let relayHost = "relay.camfetti.lacy.sh"
    static let relayPort: UInt16 = 7443
    /// SHA-256 of the relay's certificate (DER). The relay uses a self-signed cert, so this pin
    /// is the whole trust decision.
    static let relayPin = "6997166005565751969dffc40a0fb09f8c1665d4ef9ec079bea53bea7f5e480d"

    private static let roomKey = "away.room"
    private static let routeKey = "away.route"

    /// Saves launch arguments: `-awayRoom <token>`, and for local testing `-awayRelay host:port`
    /// and `-awayPin <hex>`.
    static func installFromLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let room = value("-awayRoom") { Keychain.set(room == "none" ? nil : room, for: roomKey) }
        if let relay = value("-awayRelay") { UserDefaults.standard.set(relay == "none" ? nil : relay, forKey: "away.relay") }
        if let pin = value("-awayPin") { UserDefaults.standard.set(pin == "none" ? nil : pin, forKey: "away.pin") }
    }

    static var room: String? { Keychain.get(roomKey) }
    static var isAvailable: Bool { room != nil }

    /// Phone side: send every camera through the relay instead of trying it directly.
    static var routeThroughRelay: Bool {
        get { isAvailable && UserDefaults.standard.bool(forKey: routeKey) }
        set { UserDefaults.standard.set(newValue, forKey: routeKey) }
    }

    static var endpoint: NWEndpoint {
        if let override = UserDefaults.standard.string(forKey: "away.relay"),
           let target = Target(override) {
            return .hostPort(host: .init(target.host), port: .init(rawValue: target.port) ?? .init(integerLiteral: relayPort))
        }
        return .hostPort(host: .init(relayHost), port: .init(rawValue: relayPort)!)
    }

    static var pin: String { UserDefaults.standard.string(forKey: "away.pin") ?? relayPin }
}

/// A "host:port" pair, with IPv6 hosts in brackets.
struct Target: Hashable, Sendable, CustomStringConvertible {
    let host: String
    let port: UInt16

    init(host: String, port: UInt16) {
        self.host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        self.port = port
    }

    init?(_ text: String) {
        guard let colon = text.lastIndex(of: ":"), let port = UInt16(text[text.index(after: colon)...]) else { return nil }
        self.init(host: String(text[..<colon]), port: port)
    }

    var description: String { "\(Camera.bracket(host)):\(port)" }

    /// The bridge only dials addresses on the home network, so a leaked room token can't turn
    /// it into a proxy to the internet.
    var isPrivate: Bool {
        if let v4 = IPv4Address(host) {
            let b = [UInt8](v4.rawValue)
            return b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
                || (b[0] == 169 && b[1] == 254) || (b[0] == 100 && (64...127).contains(b[1]))
        }
        if let v6 = IPv6Address(host) {
            let b = [UInt8](v6.rawValue)
            return (b[0] & 0xFE) == 0xFC || (b[0] == 0xFE && (b[1] & 0xC0) == 0x80)
        }
        return host.hasSuffix(".local")
    }
}

extension NWParameters {
    /// TLS 1.3 to the relay, trusting only the pinned certificate.
    static func relay() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)
        sec_protocol_options_set_tls_server_name(sec, AwayConfig.relayHost)
        let pin = AwayConfig.pin.lowercased()
        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            let ref = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(ref) as? [SecCertificate], let leaf = chain.first else {
                complete(false)
                return
            }
            let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
            complete(digest.map { String(format: "%02x", $0) }.joined() == pin)
        }, .global(qos: .userInitiated))
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 20
        tcp.connectionTimeout = 10
        return NWParameters(tls: tls, tcp: tcp)
    }
}
