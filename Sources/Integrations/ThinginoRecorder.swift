import Foundation

/// Thingino's SD card recorder, through the same endpoints its own web page uses:
/// `tool-record.cgi` holds the saved settings (start at boot, where, how much), `json-prudynt.cgi`
/// starts and stops recording now, and `tool-sdcard.cgi` (read only, never POSTed: POST formats the card)
/// reports the card.
extension ThinginoClient {
    struct RecorderSettings: Equatable, Sendable {
        var autostart: Bool
        var channel: Int
        var cleanupEnabled: Bool
        var devicePath: String
        var duration: Int
        var filename: String
        var limitGB: Int
        var minFreeMB: Int
        var checkInterval: Int
        var mount: String
        /// Storage the camera can record to, such as "/mnt/mmcblk0p1".
        var mounts: [String]
    }

    struct Card: Equatable, Sendable {
        var present: Bool
        var sizeBytes: Int64
        /// Mounted partitions by mount point, with their size. A card can be far bigger than its partition:
        /// a 64 GB card left over from flashing firmware had one 117 MB partition (Wyze v3, 2026-11-09).
        var partitions: [String: Int64] = [:]

        func usableBytes(on mount: String) -> Int64 { partitions[mount] ?? sizeBytes }
    }

    enum RecorderFailure: Error, Equatable {
        /// The camera said no, in its own words.
        case refused(String)
    }

    func recorderSettings() async throws -> RecorderSettings {
        let (data, response) = try await session.data(for: request("/x/tool-record.cgi", method: "GET"))
        try Self.check(response)
        guard let settings = Self.parseRecorderSettings(data) else { throw Failure.badResponse }
        return settings
    }

    func card() async throws -> Card {
        let (data, response) = try await session.data(for: request("/x/tool-sdcard.cgi", method: "GET"))
        try Self.check(response)
        guard let card = Self.parseCard(data) else { throw Failure.badResponse }
        return card
    }

    func saveRecorder(_ settings: RecorderSettings) async throws {
        var post = request("/x/tool-record.cgi", method: "POST")
        post.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        post.httpBody = Data(Self.recorderForm(settings).utf8)
        let (data, response) = try await session.data(for: post)
        if (response as? HTTPURLResponse)?.statusCode == 401 { throw Failure.wrongPassword }
        if let message = Self.errorMessage(data) { throw RecorderFailure.refused(message) }
        try Self.check(response)
    }

    /// True while the main stream is being written to the card.
    func isRecording() async throws -> Bool {
        let reply = try await prudynt(["mp4": ["status": NSNull()]])
        return ((reply["mp4"] as? [String: Any])?["status"] as? [String: Any])?["ch0"] as? Bool ?? false
    }

    func startRecording() async throws { try await recorderCommand("start") }

    func stopRecording() async throws { try await recorderCommand("stop") }

    private func recorderCommand(_ action: String) async throws {
        let reply = try await prudynt(["mp4": [action: ["channel": 0]]])
        let result = (reply["mp4"] as? [String: Any])?[action] as? String
        guard result == "ok" else { throw RecorderFailure.refused(result ?? "The camera's streamer didn't answer.") }
    }

    private func prudynt(_ body: [String: Any]) async throws -> [String: Any] {
        var post = request("/x/json-prudynt.cgi", method: "POST")
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: post)
        try Self.check(response)
        // An empty reply means prudynt isn't running.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RecorderFailure.refused("The camera's streamer didn't answer.")
        }
        return json
    }

    private static func check(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw Failure.wrongPassword }
        guard status == 200 else { throw Failure.badResponse }
    }

    // MARK: Pure helpers

    static func parseRecorderSettings(_ data: Data) -> RecorderSettings? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["data"] as? [String: Any], let video = payload["video"] as? [String: Any] else { return nil }
        func int(_ k: String, _ fallback: Int) -> Int { (video[k] as? Int) ?? (video[k] as? String).flatMap(Int.init) ?? fallback }
        func str(_ k: String) -> String { video[k] as? String ?? "" }
        return RecorderSettings(autostart: video["autostart"] as? Bool ?? false,
                                channel: int("channel", 0),
                                cleanupEnabled: video["cleanup_enabled"] as? Bool ?? false,
                                devicePath: str("device_path"),
                                duration: int("duration", 60),
                                filename: str("filename"),
                                limitGB: int("limit", 15),
                                minFreeMB: int("min_free_mb", 500),
                                checkInterval: int("check_interval", 60),
                                mount: str("mount"),
                                mounts: payload["mounts"] as? [String] ?? [])
    }

    static func parseCard(_ data: Data) -> Card? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["data"] as? [String: Any] else { return nil }
        let device = payload["device"] as? [String: Any]
        let size = (device?["size_bytes"] as? NSNumber)?.int64Value ?? 0
        let df = ((payload["reports"] as? [String: Any])?["partitions_b64"] as? String)
            .flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        return Card(present: payload["has_sdcard"] as? Bool ?? false, sizeBytes: size, partitions: parsePartitions(df))
    }

    /// `df -h` lines such as "/dev/mmcblk0p1  117.2M  83.5M  33.7M  71% /mnt/mmcblk0p1".
    static func parsePartitions(_ df: String) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for line in df.split(separator: "\n") {
            let cols = line.split(whereSeparator: \.isWhitespace)
            guard cols.count >= 6, cols[0].hasPrefix("/dev/"), let size = bytes(String(cols[1])) else { continue }
            result[String(cols[5])] = size
        }
        return result
    }

    static func bytes(_ human: String) -> Int64? {
        let units: [Character: Double] = ["K": 0x1p10, "M": 0x1p20, "G": 0x1p30, "T": 0x1p40]
        if let unit = human.last, let scale = units[unit], let n = Double(human.dropLast()) { return Int64(n * scale) }
        return Int64(human)
    }

    /// Where recordings go: the saved mount if it's still there, else the SD card.
    static func recordingMount(_ s: RecorderSettings) -> String? {
        s.mounts.contains(s.mount) ? s.mount : s.mounts.first { $0.contains("mmc") } ?? s.mounts.first
    }

    /// The form Thingino's own page posts. Every field is sent, because the camera overwrites
    /// any field that's missing with its default.
    static func recorderForm(_ s: RecorderSettings) -> String {
        let fields: [(String, String)] = [
            ("form", "video"),
            ("vr_autostart", s.autostart ? "true" : "false"),
            ("vr_channel", String(s.channel)),
            ("vr_cleanup_enabled", s.cleanupEnabled ? "true" : "false"),
            ("vr_device_path", s.devicePath),
            ("vr_duration", String(s.duration)),
            ("vr_filename", s.filename),
            ("vr_limit", String(s.limitGB)),
            ("vr_min_free_mb", String(s.minFreeMB)),
            ("vr_check_interval", String(s.checkInterval)),
            ("vr_mount", s.mount),
        ]
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }

    static func errorMessage(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        return error["message"] as? String ?? "The camera didn't save the setting."
    }

    /// The settings that make the camera record nonstop to its card and keep doing so:
    /// the card as the destination, oldest clips deleted when it fills, and a size cap
    /// that uses most of the card instead of Thingino's fixed 15 GB.
    static func recordingOn(_ current: RecorderSettings, card: Card) -> RecorderSettings? {
        guard let mount = recordingMount(current) else { return nil }
        var s = current
        s.autostart = true
        s.cleanupEnabled = true
        s.mount = mount
        s.limitGB = max(1, Int(Double(card.usableBytes(on: mount)) * 0.9 / 1_073_741_824))
        if s.minFreeMB <= 0 { s.minFreeMB = 500 }
        if s.duration <= 0 { s.duration = 60 }
        if s.checkInterval <= 0 { s.checkInterval = 60 }
        if s.filename.isEmpty { s.filename = "%Y/%m/%d/%H-%M-%S" }
        return s
    }

    /// Smaller than this fills in minutes, and the cleanup floor (500 MB free) erases every clip.
    /// Seen on a real 117 MB partition: a clip was deleted a second after it was written.
    static let smallestCardBytes: Int64 = 4_000_000_000
}
