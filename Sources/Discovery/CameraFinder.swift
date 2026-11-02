import Foundation
import Network
import Observation

/// A camera seen on the network that has not been added yet.
struct FoundCamera: Identifiable, Hashable, Sendable {
    var id: String { host }
    var name: String
    var host: String
    var httpPort: Int?
    var isThingino: Bool
    var streamer: String?
    var brand: String?
}

/// Finds cameras two ways: Bonjour for those that announce themselves (Thingino), and a quick
/// sweep of the local subnet for the RTSP port for those that do not (most brands).
@MainActor @Observable
final class CameraFinder {
    private(set) var found: [FoundCamera] = []
    private(set) var isSearching = false
    private var browser: NWBrowser?
    private var sweep: Task<Void, Never>?

    func start() {
        guard browser == nil else { return }
        isSearching = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_thingino._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                for result in results { self?.resolveAndMerge(result) }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
        let sink = FoundSink(finder: self)
        sweep = Task {
            if let subnet = LocalSubnet.current() {
                await SubnetSweep.run(hosts: subnet.hosts) { camera in
                    await sink.deliver(camera)
                }
            }
            sink.finished()
        }
    }

    func stop() {
        browser?.cancel()
        browser = nil
        sweep?.cancel()
        sweep = nil
        isSearching = false
    }

    private func resolveAndMerge(_ result: NWBrowser.Result) {
        Task {
            guard let camera = await Self.resolve(result) else { return }
            merge(camera)
        }
    }

    fileprivate func markDone() { isSearching = false }

    fileprivate func merge(_ camera: FoundCamera) {
        if let i = found.firstIndex(where: { $0.host == camera.host }) {
            // Bonjour knows more than the sweep. Never downgrade.
            if camera.isThingino || !found[i].isThingino { found[i] = camera }
        } else {
            found.append(camera)
        }
    }

    /// Connects briefly to learn the service's address.
    private nonisolated static func resolve(_ result: NWBrowser.Result) async -> FoundCamera? {
        guard case let .service(name, _, _, _) = result.endpoint else { return nil }
        var txt: [String: String] = [:]
        if case let .bonjour(record) = result.metadata { txt = record.dictionary }
        // IPv4 on purpose: Bonjour can hand back an IPv6 link-local address (fe80::...), which
        // doesn't match the camera's saved address and breaks in URLs once the zone is dropped.
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(to: result.endpoint, using: parameters)
        let address: (String, Int)? = await withCheckedContinuation { continuation in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                        once.run { continuation.resume(returning: (Self.clean(host), Int(port.rawValue))) }
                    } else {
                        once.run { continuation.resume(returning: nil) }
                    }
                case .failed, .cancelled:
                    once.run { continuation.resume(returning: nil) }
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                once.run { continuation.resume(returning: nil) }
            }
        }
        connection.cancel()
        guard let address else { return nil }
        return FoundCamera(name: name, host: address.0, httpPort: address.1, isThingino: true,
                           streamer: txt["streamer"], brand: "Thingino")
    }

    nonisolated static func clean(_ host: NWEndpoint.Host) -> String {
        let text = "\(host)"
        return text.split(separator: "%").first.map(String.init) ?? text
    }
}

/// Carries sweep results back to the finder on the main actor.
private final class FoundSink: Sendable {
    nonisolated(unsafe) weak var finder: CameraFinder?
    init(finder: CameraFinder) { self.finder = finder }
    @MainActor func deliver(_ camera: FoundCamera) { finder?.merge(camera) }
    @MainActor func finished() { finder?.markDone() }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

struct LocalSubnet: Equatable, Sendable {
    let address: UInt32
    let mask: UInt32

    /// Every usable host, skipping our own. Limited to a /24 around us, so the sweep stays quick.
    var hosts: [String] {
        let effective = max(mask, 0xFFFF_FF00)
        let network = address & effective
        let count = (~effective)
        guard count >= 2 else { return [] }
        return (1..<count).compactMap { i in
            let ip = network | i
            return ip == address ? nil : Self.format(ip)
        }
    }

    static func format(_ ip: UInt32) -> String {
        "\((ip >> 24) & 255).\((ip >> 16) & 255).\((ip >> 8) & 255).\(ip & 255)"
    }

    static func current() -> LocalSubnet? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var cursor = head
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let name = String(cString: item.pointee.ifa_name)
            guard name.hasPrefix("en"), let sa = item.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  let nm = item.pointee.ifa_netmask else { continue }
            let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if ip != 0 { return LocalSubnet(address: ip, mask: mask) }
        }
        return nil
    }
}

enum SubnetSweep {
    static let port: UInt16 = 554
    static let concurrency = 40

    static func run(hosts: [String], onFound: @Sendable @escaping (FoundCamera) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = hosts.makeIterator()
            func addNext() -> Bool {
                guard let host = iterator.next() else { return false }
                group.addTask {
                    guard await isOpen(host: host, port: port) else { return }
                    let brand = await identify(host: host)
                    let thingino = brand == "Thingino"
                    await onFound(FoundCamera(name: brand.map { "\($0) camera" } ?? "Camera at \(host)", host: host,
                                              httpPort: thingino ? 80 : nil, isThingino: thingino, streamer: nil, brand: brand))
                }
                return true
            }
            for _ in 0..<concurrency where addNext() {}
            while await group.next() != nil {
                if Task.isCancelled { group.cancelAll(); return }
                _ = addNext()
            }
        }
    }

    static func isOpen(host: String, port: UInt16, timeout: TimeInterval = 0.8) async -> Bool {
        let connection = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .tcp)
        let open: Bool = await withCheckedContinuation { continuation in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume(returning: true) }
                case .failed, .cancelled: once.run { continuation.resume(returning: false) }
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.run { continuation.resume(returning: false) }
            }
        }
        connection.cancel()
        return open
    }

    static func identify(host: String) async -> String? {
        guard let url = URL(string: "http://\(host)/") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return brand(inPage: String(decoding: data, as: UTF8.self))
    }

    static func brand(inPage page: String) -> String? {
        let text = page.lowercased()
        let names = ["thingino": "Thingino", "reolink": "Reolink", "hikvision": "Hikvision", "dahua": "Dahua",
                     "amcrest": "Amcrest", "annke": "Annke", "tapo": "Tapo", "unifi": "UniFi", "wyze": "Wyze"]
        return names.keys.sorted().first { text.contains($0) }.flatMap { names[$0] }
    }
}
