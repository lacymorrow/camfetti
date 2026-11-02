import Foundation
import Network
import os

/// Phone side of Away. Each camera address gets a listener on 127.0.0.1, and every connection
/// to it is carried through the relay to the bridge at home. The RTSP code never knows.
final class AwayTunnel: @unchecked Sendable {
    static let shared = AwayTunnel()

    private let lock = NSLock()
    private var listeners: [Target: (listener: NWListener, port: UInt16)] = [:]
    private let queue = DispatchQueue(label: "sh.lacy.camfetti.away.tunnel", qos: .userInitiated)
    private let log = Logger(subsystem: "sh.lacy.camfetti", category: "away")

    /// The same URL pointed at the local listener for its camera.
    func localURL(for url: String) -> String? {
        guard var comps = URLComponents(string: url), let host = comps.host else { return nil }
        let port = comps.port ?? (comps.scheme == "http" ? 80 : 554)
        guard let target = UInt16(exactly: port).map({ Target(host: host, port: $0) }),
              let local = localPort(for: target) else { return nil }
        comps.host = "127.0.0.1"
        comps.port = Int(local)
        return comps.string
    }

    private func localPort(for target: Target) -> UInt16? {
        lock.withLock {
            if let existing = listeners[target] { return existing.port }
            // A stable port per camera, so a reopened stream finds its listener at the same URL.
            var port = 50000 + UInt16(Self.hash(target.description) % 10000)
            while listeners.values.contains(where: { $0.port == port }) { port += 1 }
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
            let params = NWParameters.tcp
            // Bound to loopback only: other devices on the Wi-Fi must never reach the tunnel.
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
            params.allowLocalEndpointReuse = true
            guard let listener = try? NWListener(using: params) else { return nil }
            listener.newConnectionHandler = { [weak self] local in self?.carry(local, to: target) }
            listener.stateUpdateHandler = { [weak self, port] state in
                if case let .failed(error) = state {
                    self?.log.error("listener \(port) failed: \(error.localizedDescription, privacy: .public)")
                    self?.drop(target)
                }
            }
            listener.start(queue: queue)
            listeners[target] = (listener, port)
            return port
        }
    }

    private func drop(_ target: Target) {
        lock.withLock { listeners.removeValue(forKey: target)?.listener.cancel() }
    }

    private func carry(_ local: NWConnection, to target: Target) {
        guard let room = AwayConfig.room else { local.cancel(); return }
        let started = Date()
        let relay = NWConnection(to: AwayConfig.endpoint, using: .relay())
        local.start(queue: queue)
        Pipe.start(relay, on: queue) { [log] ready in
            guard ready else {
                log.error("relay unreachable for \(target, privacy: .private)")
                local.cancel()
                return
            }
            Pipe.sendLine(["role": "phone", "room": room, "target": target.description], on: relay)
            Pipe.readLine(on: relay) { line, rest in
                guard line == "ok" else {
                    log.error("relay said \(line ?? "nothing", privacy: .public)")
                    relay.cancel()
                    local.cancel()
                    return
                }
                let setup = Int(Date().timeIntervalSince(started) * 1000)
                log.info("tunnel up in \(setup) ms")
                Pipe.splice(relay, local, head: rest) { down, up in
                    log.info("tunnel closed after \(Int(Date().timeIntervalSince(started)))s, down \(down) up \(up)")
                }
            }
        }
    }

    private static func hash(_ s: String) -> UInt32 {
        s.utf8.reduce(2_166_136_261) { ($0 ^ UInt32($1)) &* 16_777_619 }
    }
}
