import Foundation
import os
import WatchConnectivity

/// The watch end of the link. Asks the iPhone for the camera list and for pictures.
/// The phone is reachable whenever it is nearby, even with CamFetti closed: a message launches it.
@MainActor
final class WatchSession: NSObject, WCSessionDelegate {
    static let shared = WatchSession()

    enum Failure: Error {
        case notNearby
        case camera
    }

    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var waitingForPhone: [CheckedContinuation<Void, Never>] = []
    private let log = Logger(subsystem: "sh.lacy.camfetti.watch", category: "link")
    /// Debug builds show this under an error, so a failure on a real watch can be read off the screen.
    private(set) var lastDetail = ""

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        if session.activationState != .activated { session.activate() }
    }

    func cameras() async throws -> [WatchProtocol.CameraSummary] {
        #if DEBUG
        if let fixture = Fixture.current { return try fixture.cameras() }
        #endif
        let reply = try await send(WatchProtocol.cameraListRequest())
        guard let cameras = WatchProtocol.decodeCameras(reply) else { throw Failure.camera }
        return cameras
    }

    func snapshot(id: String) async throws -> Data {
        #if DEBUG
        if let fixture = Fixture.current { return try fixture.snapshot() }
        #endif
        let reply = try await send(WatchProtocol.snapshotRequest(id: id))
        guard let jpeg = WatchProtocol.decodeSnapshot(reply) else { throw Failure.camera }
        return jpeg
    }

    private func send(_ message: [String: Any]) async throws -> [String: Any] {
        guard WCSession.isSupported() else { throw Failure.notNearby }
        activate()
        if WCSession.default.activationState != .activated {
            await withCheckedContinuation { waiting.append($0) }
        }
        let session = WCSession.default
        guard session.activationState == .activated else {
            note("not activated (\(session.activationState.rawValue))")
            throw Failure.notNearby
        }
        // Reachability is often false for a moment after launch, then flips. Give it a few seconds.
        if !session.isReachable { await waitForPhone(seconds: Theme.Timing.reachabilityWait) }
        if !session.isReachable { note("not reachable yet, sending anyway") }
        let box = MessageBox(message)
        let gate = Gate()
        let reply: ReplyBox = try await withCheckedThrowingContinuation { continuation in
            // A phone that never answers must not leave the watch spinning forever.
            Task {
                try? await Task.sleep(for: .seconds(Theme.Timing.requestTimeout))
                if gate.claim() { continuation.resume(throwing: Failure.notNearby) }
            }
            session.sendMessage(box.value, replyHandler: { value in
                if gate.claim() { continuation.resume(returning: ReplyBox(value: value)) }
            }, errorHandler: { error in
                let code = (error as NSError).code
                Task { @MainActor in self.note("send failed: WCError \(code)") }
                if gate.claim() { continuation.resume(throwing: Failure.notNearby) }
            })
        }
        lastDetail = ""
        return reply.value
    }

    private func note(_ detail: String) {
        lastDetail = detail
        log.error("\(detail, privacy: .public)")
    }

    private func waitForPhone(seconds: Double) async {
        await withCheckedContinuation { continuation in
            waitingForPhone.append(continuation)
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                self.resumePhoneWaiters()
            }
        }
    }

    private func resumePhoneWaiters() {
        let pending = waitingForPhone
        waitingForPhone = []
        pending.forEach { $0.resume() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in if reachable { self.resumePhoneWaiters() } }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            let pending = self.waiting
            self.waiting = []
            pending.forEach { $0.resume() }
        }
    }
}

private struct MessageBox: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

private struct ReplyBox: @unchecked Sendable {
    let value: [String: Any]
}

/// Lets exactly one of the reply, the error and the timeout finish a request.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

#if DEBUG
/// Screenshots on a simulator whose WatchConnectivity link is unreliable: `-watchFixture <mode>
/// <jpeg path>` answers from a local picture instead of asking the phone. Debug builds only.
/// Modes: list, camera, cantReach, notNearby, empty.
private struct Fixture {
    let mode: String
    let image: Data?

    static let current: Fixture? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-watchFixture"), i + 2 < args.count else { return nil }
        return Fixture(mode: args[i + 1], image: try? Data(contentsOf: URL(fileURLWithPath: args[i + 2])))
    }()

    func cameras() throws -> [WatchProtocol.CameraSummary] {
        if mode == "notNearby" { throw WatchSession.Failure.notNearby }
        let names: [String]
        switch mode {
        case "empty": names = []
        case "list": names = ["Front of House", "Back of House", "Driveway"]
        default: names = ["Front of House"]
        }
        return names.enumerated().map { WatchProtocol.CameraSummary(id: "fixture-\($0.offset)", name: $0.element, thumbnail: image) }
    }

    func snapshot() throws -> Data {
        if mode == "notNearby" { throw WatchSession.Failure.notNearby }
        if mode == "cantReach" { throw WatchSession.Failure.camera }
        guard let image else { throw WatchSession.Failure.camera }
        return image
    }
}
#endif
