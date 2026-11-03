// Away is a paid service that has not launched. It compiles only with the AWAY flag (Debug builds),
// so App Store builds carry none of it.
#if AWAY
import Foundation
import Network

/// Byte plumbing shared by the bridge and the phone tunnel.
enum Pipe {
    /// Sends one JSON line.
    static func sendLine(_ object: [String: Any], on conn: NWConnection, done: (@Sendable (Bool) -> Void)? = nil) {
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        conn.send(content: data, completion: .contentProcessed { error in done?(error == nil) })
    }

    /// Reads up to the first newline. Hands back the line and any bytes that arrived after it.
    static func readLine(on conn: NWConnection, buffer: Data = Data(),
                         done: @escaping @Sendable (_ line: String?, _ rest: Data) -> Void) {
        if let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            done(line, Data(buffer[buffer.index(after: nl)...]))
            return
        }
        guard buffer.count < 4096 else { done(nil, Data()); return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
            guard let data, !data.isEmpty else {
                done(nil, Data())
                return
            }
            readLine(on: conn, buffer: buffer + data, done: done)
            _ = (isComplete, error)
        }
    }

    /// Copies both ways until either side ends, then cancels both. `head` is written to `b` first.
    /// Each direction waits for its last send before reading more, so a slow cellular link
    /// slows the camera down instead of filling memory.
    static func splice(_ a: NWConnection, _ b: NWConnection, head: Data = Data(),
                       onClose: @escaping @Sendable (_ aToB: Int, _ bToA: Int) -> Void) {
        let state = SpliceState()
        let finish: @Sendable () -> Void = {
            guard state.close() else { return }
            a.cancel()
            b.cancel()
            onClose(state.counts.0, state.counts.1)
        }
        let start: @Sendable () -> Void = {
            pump(from: a, to: b, count: { state.add(aToB: $0) }, finish: finish)
            pump(from: b, to: a, count: { state.add(bToA: $0) }, finish: finish)
        }
        if head.isEmpty {
            start()
        } else {
            b.send(content: head, completion: .contentProcessed { error in
                if error != nil { finish() } else { start() }
            })
        }
    }

    private static func pump(from: NWConnection, to: NWConnection, count: @escaping @Sendable (Int) -> Void,
                             finish: @escaping @Sendable () -> Void) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                count(data.count)
                to.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil || isComplete { finish() } else { pump(from: from, to: to, count: count, finish: finish) }
                })
            } else if isComplete || error != nil {
                finish()
            } else {
                pump(from: from, to: to, count: count, finish: finish)
            }
        }
    }
}

extension Pipe {
    /// Starts a connection and calls back once: true when ready, false when it fails or stalls.
    static func start(_ conn: NWConnection, on queue: DispatchQueue, ready: @escaping @Sendable (Bool) -> Void) {
        let once = Once()
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                once.run { ready(true) }
            case .waiting, .failed:
                // Waiting means no route right now. Callers retry on their own schedule.
                once.run { conn.cancel(); ready(false) }
            case .cancelled:
                once.run { ready(false) }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }
}

private final class SpliceState: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var aToB = 0
    private var bToA = 0

    func close() -> Bool { lock.withLock { defer { closed = true }; return !closed } }
    func add(aToB n: Int) { lock.withLock { aToB += n } }
    func add(bToA n: Int) { lock.withLock { bToA += n } }
    var counts: (Int, Int) { lock.withLock { (aToB, bToA) } }
}
#endif
