import Foundation

/// A Reolink camera's SD card recording settings. Newer firmware (GetRecV20) keeps one hourly table per
/// trigger, so CamFetti can choose what to record. Older firmware (GetRec, an RLC-410 from 2020) has one
/// table that records on motion, so it only turns on and off. A save sends back everything the camera
/// reported, changing only the fields CamFetti owns.
extension ReolinkClient {
    enum RecordMode: String, CaseIterable, Sendable {
        /// Every hour, with motion still marked so playback can find it.
        case nonstop
        /// Any motion, people and vehicles included.
        case motion
        /// Only what the camera's AI calls a person, vehicle or animal. Ignores rain, leaves and shadows.
        case smart
    }

    struct RecordConfig: Equatable, Sendable {
        var isV20: Bool
        var enabled: Bool
        var overwrite: Bool
        /// Trigger ("TIMING", "MD", "AI_PEOPLE", ...) to one character per hour of the week. Legacy has only "MD".
        var tables: [String: String]
        /// The camera's own Rec object.
        var raw: Data

        /// AI triggers this camera has, in a fixed order.
        var aiTriggers: [String] { ReolinkClient.aiTriggers.filter { tables[$0] != nil } }

        /// What the camera can be set to record. Empty when it only turns on and off.
        var modes: [RecordMode] {
            guard isV20, tables["MD"] != nil else { return [] }
            return aiTriggers.isEmpty ? [.nonstop, .motion] : [.nonstop, .motion, .smart]
        }

        /// Nil when the camera's own schedule (set in Reolink's app, say) isn't one of the modes.
        var mode: RecordMode? {
            guard !modes.isEmpty else { return nil }
            if Self.all(tables["TIMING"], "1") { return .nonstop }
            guard Self.none(tables["TIMING"]) else { return nil }
            if Self.all(tables["MD"], "1") { return .motion }
            if Self.none(tables["MD"]), !aiTriggers.isEmpty, aiTriggers.allSatisfy({ Self.all(tables[$0], "1") }) { return .smart }
            return nil
        }

        /// True when no trigger records at any hour, so "on" would still record nothing.
        var recordsNothing: Bool { tables.values.allSatisfy { Self.none($0) } }

        mutating func apply(_ mode: RecordMode) {
            set("TIMING", mode == .nonstop)
            set("MD", mode != .smart)
            for trigger in aiTriggers { set(trigger, true) }
        }

        /// On, every hour of a schedule that records nothing, and replace the oldest clips so it never stops at a full card.
        mutating func turnOn() {
            enabled = true
            overwrite = true
            guard recordsNothing else { return }
            if isV20 { apply(.motion) } else { set("MD", true) }
        }

        private mutating func set(_ trigger: String, _ on: Bool) {
            let count = tables[trigger]?.count ?? ReolinkClient.hoursInWeek
            tables[trigger] = String(repeating: on ? "1" : "0", count: count == 0 ? ReolinkClient.hoursInWeek : count)
        }

        private static func all(_ table: String?, _ flag: Character) -> Bool {
            guard let table, !table.isEmpty else { return false }
            return table.allSatisfy { $0 == flag }
        }

        private static func none(_ table: String?) -> Bool { table?.allSatisfy { $0 == "0" } ?? true }
    }

    static let aiTriggers = ["AI_PEOPLE", "AI_VEHICLE", "AI_DOG_CAT"]
    static let hoursInWeek = 168

    func recordConfig(_ token: String) async throws -> RecordConfig {
        let (data, _) = try await post([["cmd": "GetRecV20", "action": 0, "param": ["channel": 0]]], cmd: "GetRecV20", token: token)
        if let config = Self.parseRecord(data, v20: true) { return config }
        let (legacy, _) = try await post([["cmd": "GetRec", "action": 0, "param": ["channel": 0]]], cmd: "GetRec", token: token)
        guard let config = Self.parseRecord(legacy, v20: false) else { throw Failure.badResponse }
        return config
    }

    func saveRecord(_ config: RecordConfig, token: String) async throws {
        let cmd = config.isV20 ? "SetRecV20" : "SetRec"
        guard let rec = Self.recordBody(config) else { throw Failure.badResponse }
        let (data, _) = try await post([["cmd": cmd, "param": ["Rec": rec]]], cmd: cmd, token: token)
        guard let reply = Self.firstReply(data) else { throw Failure.badResponse }
        guard (reply["code"] as? Int) == 0 else {
            if Self.int((reply["error"] as? [String: Any])?["rspCode"]) == -26 { throw Failure.notAllowed }
            let detail = (reply["error"] as? [String: Any])?["detail"] as? String
            throw Failure.refused(detail ?? "it couldn't save the setting")
        }
    }

    /// Size of the mounted card in bytes, or nil when there's no usable card.
    func cardBytes(_ token: String) async throws -> Int64? {
        let (data, _) = try await post([["cmd": "GetHddInfo", "action": 0, "param": [:]]], cmd: "GetHddInfo", token: token)
        return try Self.parseCardBytes(data)
    }

    // MARK: Pure helpers

    static func parseRecord(_ data: Data, v20: Bool) -> RecordConfig? {
        guard let reply = firstReply(data), (reply["code"] as? Int) == 0,
              let rec = (reply["value"] as? [String: Any])?["Rec"] as? [String: Any],
              let schedule = rec["schedule"] as? [String: Any],
              let raw = try? JSONSerialization.data(withJSONObject: rec) else { return nil }
        let overwrite = int(rec["overwrite"]) == 1
        if v20 {
            guard let table = schedule["table"] as? [String: Any] else { return nil }
            return RecordConfig(isV20: true, enabled: int(rec["enable"]) == 1, overwrite: overwrite,
                                tables: table.compactMapValues { $0 as? String }, raw: raw)
        }
        guard let table = schedule["table"] as? String else { return nil }
        return RecordConfig(isV20: false, enabled: int(schedule["enable"]) == 1, overwrite: overwrite, tables: ["MD": table], raw: raw)
    }

    /// The camera's Rec object with CamFetti's fields written over it.
    static func recordBody(_ config: RecordConfig) -> [String: Any]? {
        guard var rec = (try? JSONSerialization.jsonObject(with: config.raw)) as? [String: Any] else { return nil }
        var schedule = rec["schedule"] as? [String: Any] ?? [:]
        rec["overwrite"] = config.overwrite ? 1 : 0
        if config.isV20 {
            rec["enable"] = config.enabled ? 1 : 0
            var table = schedule["table"] as? [String: Any] ?? [:]
            for (trigger, hours) in config.tables { table[trigger] = hours }
            schedule["table"] = table
            if schedule["channel"] == nil { schedule["channel"] = 0 }
        } else {
            schedule["enable"] = config.enabled ? 1 : 0
            schedule["table"] = config.tables["MD"] ?? ""
            if rec["channel"] == nil { rec["channel"] = 0 }
        }
        rec["schedule"] = schedule
        return rec
    }

    /// `capacity` is in megabytes. An unmounted or unformatted card counts as none.
    static func parseCardBytes(_ data: Data) throws -> Int64? {
        guard let reply = firstReply(data) else { throw Failure.badResponse }
        let disks = (reply["value"] as? [String: Any])?["HddInfo"] as? [[String: Any]] ?? []
        guard let disk = disks.first(where: { int($0["mount"]) == 1 && (int($0["capacity"]) ?? 0) > 0 }),
              let megabytes = int(disk["capacity"]) else { return nil }
        return Int64(megabytes) * 1_048_576
    }

    private static func int(_ value: Any?) -> Int? { (value as? Int) ?? (value as? String).flatMap(Int.init) }
}
