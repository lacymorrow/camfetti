import Foundation
import Network
import Observation
import os
import UIKit

/// Home side of Away. Holds one link to the relay and, when a phone asks for a camera,
/// dials the camera on the home network and a fresh link back to the relay, then joins them.
@MainActor @Observable
final class BridgeService {
    enum Status: Equatable {
        case connecting
        case online
        case offline(String)
    }

    private(set) var status: Status = .connecting
    private(set) var onlineSince: Date?
    private(set) var activeStreams = 0
    private(set) var totalStreams = 0
    private(set) var reconnects = 0

    private var control: NWConnection?
    private var buffer = Data()
    private var heartbeat: Task<Void, Never>?
    private var lastPong = Date()
    private var running = false
    private var backoff: Double = 1
    private let started = Date()
    private let dataQueue = DispatchQueue(label: "sh.lacy.camfetti.away.bridge", qos: .userInitiated)
    private let log = Logger(subsystem: "sh.lacy.camfetti", category: "bridge")

    static let heartbeatEvery: Duration = .seconds(30)
    static let pongLimit: TimeInterval = 75

    func start() {
        guard !running else { return }
        running = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        connect()
    }

    func stop() {
        running = false
        heartbeat?.cancel()
        control?.cancel()
        control = nil
    }

    private func connect() {
        guard running, let room = AwayConfig.room else { return }
        if status == .online { status = .connecting }
        buffer = Data()
        let conn = NWConnection(to: AwayConfig.endpoint, using: .relay())
        control = conn
        conn.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state, on: conn, room: room) }
        }
        conn.start(queue: .main)
    }

    private func handle(_ state: NWConnection.State, on conn: NWConnection, room: String) {
        guard conn === control else { return }
        switch state {
        case .ready:
            Pipe.sendLine(["role": "bridge", "room": room, "device": Self.deviceName], on: conn)
            readNext(on: conn)
        case .waiting:
            status = .offline("No internet")
        case let .failed(error):
            drop(conn, reason: error.localizedDescription)
        case .cancelled:
            drop(conn, reason: "Disconnected")
        default:
            break
        }
    }

    private func readNext(on conn: NWConnection) {
        Pipe.readLine(on: conn, buffer: buffer) { [weak self] line, rest in
            MainActor.assumeIsolated {
                guard let self, conn === self.control else { return }
                guard let line else {
                    self.drop(conn, reason: "Relay closed the link")
                    return
                }
                self.buffer = rest
                self.handleLine(line, on: conn)
                if conn === self.control { self.readNext(on: conn) }
            }
        }
    }

    private func handleLine(_ line: String, on conn: NWConnection) {
        if line.hasPrefix("err") {
            drop(conn, reason: line == "err room" ? "This bridge's code isn't recognized" : line)
            return
        }
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if message["ok"] != nil {
            status = .online
            onlineSince = Date()
            backoff = 1
            lastPong = Date()
            startHeartbeat(on: conn)
        } else if message["pong"] != nil {
            lastPong = Date()
        } else if let id = message["open"] as? String, let target = (message["target"] as? String).flatMap(Target.init) {
            open(stream: id, to: target)
        }
    }

    private func startHeartbeat(on conn: NWConnection) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, conn === self.control else { return }
                if Date().timeIntervalSince(self.lastPong) > Self.pongLimit {
                    self.drop(conn, reason: "Relay stopped answering")
                    return
                }
                Pipe.sendLine(self.heartbeatFields(), on: conn)
                try? await Task.sleep(for: Self.heartbeatEvery)
            }
        }
    }

    private func drop(_ conn: NWConnection, reason: String) {
        guard conn === control else { return }
        log.info("link down: \(reason, privacy: .public)")
        control = nil
        conn.cancel()
        heartbeat?.cancel()
        onlineSince = nil
        status = .offline(reason)
        reconnects += 1
        let wait = backoff
        backoff = min(backoff * 2, 15)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            self?.connect()
        }
    }

    private func open(stream id: String, to target: Target) {
        guard target.isPrivate, let room = AwayConfig.room else {
            log.error("refused non-home target")
            return
        }
        activeStreams += 1
        totalStreams += 1
        let camera = NWConnection(host: .init(target.host), port: .init(rawValue: target.port)!, using: .tcp)
        let queue = dataQueue
        let finished: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.activeStreams -= 1 }
        }
        Pipe.start(camera, on: queue) { [log] ready in
            guard ready else {
                log.error("camera unreachable")
                finished()
                return
            }
            let link = NWConnection(to: AwayConfig.endpoint, using: .relay())
            Pipe.start(link, on: queue) { ready in
                guard ready else { camera.cancel(); finished(); return }
                Pipe.sendLine(["role": "data", "room": room, "stream": id], on: link)
                Pipe.splice(link, camera) { _, _ in finished() }
            }
        }
    }

    private func heartbeatFields() -> [String: Any] {
        let device = UIDevice.current
        let charging: String = switch device.batteryState {
        case .charging: "charging"
        case .full: "full"
        case .unplugged: "unplugged"
        default: "unknown"
        }
        return [
            "hb": 1,
            "battery": (Double(device.batteryLevel) * 100).rounded(),
            "power": charging,
            "thermal": ProcessInfo.processInfo.thermalState.rawValue,
            "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "app_s": Int(Date().timeIntervalSince(started)),
            "link_s": Int(Date().timeIntervalSince(onlineSince ?? Date())),
            "streams": activeStreams,
            "total": totalStreams,
            "reconnects": reconnects,
        ]
    }

    private static var deviceName: String {
        var info = utsname()
        uname(&info)
        let model = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return "\(model) iOS \(UIDevice.current.systemVersion)"
    }
}
