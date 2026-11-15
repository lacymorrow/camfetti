import Foundation

/// Reads what a Thingino camera recorded to its SD card through the camera's file manager
/// (`tool-file-manager.cgi`: `cd=` lists a folder, `play=` sends a file).
/// Recordings use the layout Thingino's recorder writes by default and CamFetti's switch keeps:
/// `<mount>/<hostname>/YYYY/MM/DD/HH-MM-SS.mp4`, named on the camera's own clock.
extension ThinginoClient {
    struct Entry: Equatable, Sendable {
        var name: String
        var path: String
        var size: Int
        var isDirectory: Bool
    }

    func list(_ directory: String) async throws -> [Entry] {
        let (data, response) = try await session.data(for: request("/x/tool-file-manager.cgi?cd=\(Self.encodePath(directory))", method: "GET", timeout: 8))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw Failure.wrongPassword }
        if status == 404 { return [] }
        guard status == 200, let entries = Self.parseEntries(data) else { throw Failure.badResponse }
        return entries
    }

    /// The clip's URL. The key rides in `token=`, so no headers are needed.
    func playURL(path: String) -> URL? {
        URL(string: Self.authenticatedPath("/x/tool-file-manager.cgi?play=\(Self.encodePath(path))", apiKey: apiKey), relativeTo: base)?.absoluteURL
    }

    /// Downloads a clip to `destination`. The camera's web server drops the Range header before the CGI
    /// sees it and answers every request with the whole file as 200 (Wyze v3, 2026-11-09), which the system
    /// player won't stream, so clips play from a local copy.
    func download(path: String, to destination: URL) async throws {
        guard let url = playURL(path: path) else { throw Failure.badResponse }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpShouldHandleCookies = false
        let (temp, response) = try await session.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw Failure.wrongPassword }
        guard status == 200 || status == 206 else { throw Failure.badResponse }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    static func encodePath(_ path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "/-._~")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func parseEntries(_ data: Data) -> [Entry]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["entries"] as? [[String: Any]] else { return nil }
        return entries.compactMap { e in
            guard let name = e["name"] as? String, let path = e["path"] as? String else { return nil }
            let size = (e["size"] as? Int) ?? (e["size"] as? String).flatMap(Int.init) ?? 0
            return Entry(name: name, path: path, size: size, isDirectory: e["is_dir"] as? Bool ?? false)
        }
    }
}

/// Days and clips on a Thingino camera's card.
struct ThinginoRecordings: Sendable {
    let client: ThinginoClient
    /// The folder that holds the YYYY folders.
    let root: String
    /// Clip length the recorder is set to, used as each clip's length.
    let clipSeconds: Int
    var timeZone: TimeZone = .current

    /// The recordings folder: `mount/device_path`, where `%hostname` means whichever folder on the
    /// card holds year folders (the app doesn't otherwise know the camera's hostname).
    static func findRoot(client: ThinginoClient, mount: String, devicePath: String) async throws -> String? {
        let mount = mount.hasSuffix("/") ? String(mount.dropLast()) : mount
        if !devicePath.isEmpty, !devicePath.contains("%") {
            return mount + "/" + devicePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        for folder in try await client.list(mount) where folder.isDirectory {
            if try await client.list(folder.path).contains(where: { $0.isDirectory && isNumber($0.name, digits: 4) }) {
                return folder.path
            }
        }
        return nil
    }

    /// Days with recordings since `from`, newest first.
    func days(from: Date) async throws -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let floor = calendar.dateComponents([.year, .month], from: from)
        var days: [Date] = []
        for year in try await numbered(root, digits: 4) where year.value >= floor.year ?? 0 {
            for month in try await numbered(year.path, digits: 2)
            where year.value > floor.year ?? 0 || month.value >= floor.month ?? 0 {
                for day in try await numbered(month.path, digits: 2) {
                    if let date = calendar.date(from: DateComponents(year: year.value, month: month.value, day: day.value)),
                       date >= calendar.startOfDay(for: from) {
                        days.append(date)
                    }
                }
            }
        }
        return days.sorted(by: >)
    }

    /// Finished clips on `day`, oldest first.
    func clips(on day: Date, now: Date = Date()) async throws -> [Recording] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        guard let y = c.year, let m = c.month, let d = c.day else { return [] }
        let folder = String(format: "%@/%04d/%02d/%02d", root, y, m, d)
        return Self.clips(try await client.list(folder), day: calendar.startOfDay(for: day),
                          clipSeconds: clipSeconds, now: now, timeZone: timeZone)
    }

    /// Clip times come from `HH-MM-SS.mp4`. A clip ends at its set length or when the next one starts.
    /// The clip still being written is left out, because it can't play until the camera closes it.
    static func clips(_ entries: [ThinginoClient.Entry], day: Date, clipSeconds: Int, now: Date, timeZone: TimeZone) -> [Recording] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let starts: [(ThinginoClient.Entry, Date)] = entries.compactMap { entry in
            guard !entry.isDirectory, entry.size > 0, entry.name.hasSuffix(".mp4") else { return nil }
            let parts = entry.name.dropLast(4).split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                  let start = calendar.date(bySettingHour: parts[0], minute: parts[1], second: parts[2], of: day) else { return nil }
            return (entry, start)
        }
        .sorted { $0.1 < $1.1 }
        let length = TimeInterval(max(1, clipSeconds))
        return starts.enumerated().compactMap { index, item in
            let (entry, start) = item
            let next = index + 1 < starts.count ? starts[index + 1].1 : nil
            guard next != nil || start.addingTimeInterval(length + 10) < now else { return nil }
            let end = min(start.addingTimeInterval(length), next ?? .distantFuture)
            return Recording(name: entry.path, start: start, end: end, size: entry.size)
        }
    }

    private func numbered(_ folder: String, digits: Int) async throws -> [(value: Int, path: String)] {
        try await client.list(folder).compactMap { entry in
            guard entry.isDirectory, Self.isNumber(entry.name, digits: digits), let value = Int(entry.name) else { return nil }
            return (value, entry.path)
        }
    }

    static func isNumber(_ name: String, digits: Int) -> Bool {
        name.count == digits && name.allSatisfy(\.isASCII) && name.allSatisfy(\.isNumber)
    }
}
