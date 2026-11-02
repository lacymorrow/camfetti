import XCTest
@testable import CamFetti

/// Runs against real cameras. Skipped unless TEST_RUNNER_CAMFETTI_REAL holds base64 JSON:
/// [{"name","address","user","pass"}]. Prints no secrets.
@MainActor
final class RealCameraTests: XCTestCase {
    struct Item: Decodable { let name: String; let address: String; let user: String; let pass: String }

    func testRealCamerasAddAndGoLive() async throws {
        guard let b64 = ProcessInfo.processInfo.environment["CAMFETTI_REAL"], let data = Data(base64Encoded: b64) else {
            throw XCTSkip("no real cameras configured")
        }
        for item in try JSONDecoder().decode([Item].self, from: data) {
            let found = try await CameraProber().probe(.init(address: item.address, username: item.user, password: item.pass, name: item.name))
            let c = found.camera
            print("REAL \(c.name): kind=\(c.kind) main=\(c.mainURL) sub=\(c.subURL ?? "-") ptz=\(c.onvif?.ptzURL != nil) canPan=\(c.canPan)")
            XCTAssertFalse(c.mainURL.contains(item.pass), "no password in stored URL")
            for (label, url) in [("grid", c.gridURL), ("main", c.mainURL)] {
                let stream = LiveStream(urls: [url], username: c.username, password: found.password)
                let start = Date()
                stream.start()
                while stream.phase != .live, Date().timeIntervalSince(start) < 15 {
                    if case .failed = stream.phase { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let elapsed = Date().timeIntervalSince(start)
                let size = stream.resolution.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-"
                print("REAL \(c.name) \(label): phase=\(stream.phase) firstFrame=\(String(format: "%.2f", elapsed))s size=\(size) audio=\(stream.hasAudio)")
                XCTAssertEqual(stream.phase, .live, "\(c.name) \(label)")
                try await Task.sleep(for: .seconds(2))
                XCTAssertEqual(stream.phase, .live, "\(c.name) \(label) stays live")
                stream.stop()
            }
        }
    }
}

/// Thingino controls against a real camera. Skipped unless TEST_RUNNER_CAMFETTI_THINGINO holds
/// base64 JSON {"host","pass"}. Puts the camera back in Auto when done.
final class RealThinginoTests: XCTestCase {
    struct Config: Decodable { let host: String; let pass: String }

    func testDayNightReachesRealCamera() async throws {
        guard let b64 = ProcessInfo.processInfo.environment["CAMFETTI_THINGINO"], let data = Data(base64Encoded: b64) else {
            throw XCTSkip("no real Thingino camera configured")
        }
        let config = try JSONDecoder().decode(Config.self, from: data)
        let base = URL(string: "http://\(config.host)")!
        let key = try await ThinginoClient(base: base).mintAPIKey(password: config.pass)
        let client = ThinginoClient(base: base, apiKey: key)
        defer { Task { try? await client.setDayNight(.auto) } }

        try await client.setDayNight(.night)
        var mode = try await forcedMode(base: base, key: key)
        print("REAL thingino after night: \(mode)")
        XCTAssertEqual(mode, "night")

        try await client.setDayNight(.auto)
        mode = try await forcedMode(base: base, key: key)
        print("REAL thingino after auto: \(mode)")
        XCTAssertEqual(mode, "")
        _ = try await client.streamConfig()
    }

    private func forcedMode(base: URL, key: String) async throws -> String {
        try await Task.sleep(for: .seconds(1))
        let url = URL(string: ThinginoClient.authenticatedPath("/x/json-config-daynight.cgi", apiKey: key), relativeTo: base)!
        let (data, _) = try await URLSession.shared.data(from: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["force_mode"] as? String ?? "?"
    }
}
