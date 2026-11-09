import Foundation

/// One clip on a camera's SD card.
struct Recording: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let start: Date
    let end: Date
    let size: Int

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

/// Reads a Reolink camera's SD card over its HTTP API: which days have recordings, the clips on a
/// day, and a URL the system player streams with seeking (the camera answers Range requests).
/// A failed sign-in is never retried, because cameras lock out.
struct ReolinkClient: Sendable {
    enum Failure: Error, Equatable {
        case notReolink
        case wrongPassword
        case badResponse
    }

    let base: URL
    var username: String
    var password: String
    var session: URLSession = .shared
    /// Reolink reports times on the camera's own clock, which is set to the home's time zone.
    var timeZone: TimeZone = .current

    /// True when the camera answers like a Reolink. Sends no password, so it can never lock anyone out.
    func isReolink() async -> Bool {
        guard let (data, _) = try? await post([["cmd": "GetDevInfo", "action": 0, "param": [:]]], cmd: "GetDevInfo", token: nil, timeout: 3)
        else { return false }
        return Self.isReolinkReply(data)
    }

    /// Signs in once and returns a session token.
    func login() async throws -> String {
        let body: [[String: Any]] = [["cmd": "Login", "param": ["User": ["Version": "0", "userName": username, "password": password]]]]
        let (data, status) = try await post(body, cmd: "Login", token: nil)
        if status == 401 { throw Failure.wrongPassword }
        if status == 404 { throw Failure.notReolink }
        return try Self.parseLogin(data)
    }

    func logout(_ token: String) async {
        _ = try? await post([["cmd": "Logout", "action": 0, "param": [:]]], cmd: "Logout", token: token, timeout: 3)
    }

    /// False when the camera has no card, or the card isn't mounted.
    func hasCard(_ token: String) async throws -> Bool {
        let (data, _) = try await post([["cmd": "GetHddInfo", "action": 0, "param": [:]]], cmd: "GetHddInfo", token: token)
        return try Self.parseHasCard(data)
    }

    /// Days between `from` and `to` that have at least one recording, newest first.
    func days(_ token: String, from: Date, to: Date) async throws -> [Date] {
        let (data, _) = try await post(search(from: from, to: to, onlyStatus: true), cmd: "Search", token: token)
        return try Self.parseDays(data, timeZone: timeZone).filter { $0 <= to }.sorted(by: >)
    }

    /// Clips recorded on the day that contains `day`, oldest first.
    func clips(_ token: String, on day: Date) async throws -> [Recording] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? day
        let (data, _) = try await post(search(from: start, to: end, onlyStatus: false), cmd: "Search", token: token, timeout: 15)
        return try Self.parseClips(data, timeZone: timeZone)
    }

    /// Streams the clip as MP4. The token stays valid for the camera's session lease (an hour).
    func playbackURL(for clip: Recording, token: String) -> URL? {
        var comps = URLComponents(url: base.appending(path: "cgi-bin/api.cgi"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            .init(name: "cmd", value: "Playback"),
            .init(name: "source", value: clip.name),
            .init(name: "output", value: clip.name),
            .init(name: "token", value: token),
        ]
        return comps?.url
    }

    // MARK: Requests

    private func search(from: Date, to: Date, onlyStatus: Bool) -> [[String: Any]] {
        [["cmd": "Search", "action": 0, "param": ["Search": [
            "channel": 0, "onlyStatus": onlyStatus ? 1 : 0, "streamType": "main",
            "StartTime": Self.timeObject(from, timeZone: timeZone),
            "EndTime": Self.timeObject(to, timeZone: timeZone),
        ]]]]
    }

    private func post(_ body: [[String: Any]], cmd: String, token: String?, timeout: TimeInterval = 8) async throws -> (Data, Int) {
        var comps = URLComponents(url: base.appending(path: "cgi-bin/api.cgi"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [.init(name: "cmd", value: cmd)] + (token.map { [.init(name: "token", value: $0)] } ?? [])
        guard let url = comps?.url else { throw Failure.badResponse }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: Pure helpers

    static func timeObject(_ date: Date, timeZone: TimeZone) -> [String: Int] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return ["year": c.year ?? 0, "mon": c.month ?? 0, "day": c.day ?? 0,
                "hour": c.hour ?? 0, "min": c.minute ?? 0, "sec": c.second ?? 0]
    }

    static func date(from object: [String: Any], timeZone: TimeZone) -> Date? {
        func int(_ key: String) -> Int? { (object[key] as? Int) ?? (object[key] as? String).flatMap(Int.init) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let year = int("year"), let month = int("mon"), let day = int("day") else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: int("hour") ?? 0, minute: int("min") ?? 0, second: int("sec") ?? 0))
    }

    /// The first reply in the array, or nil when the body isn't Reolink's JSON shape.
    static func firstReply(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first
    }

    /// Any Reolink reply carries `cmd` and `code`, even "please login first".
    static func isReolinkReply(_ data: Data) -> Bool {
        guard let reply = firstReply(data) else { return false }
        return reply["cmd"] != nil && reply["code"] != nil
    }

    static func parseLogin(_ data: Data) throws -> String {
        guard let reply = firstReply(data) else { throw Failure.notReolink }
        if let token = ((reply["value"] as? [String: Any])?["Token"] as? [String: Any])?["name"] as? String,
           (reply["code"] as? Int) == 0, !token.isEmpty {
            return token
        }
        // -7 "login failed" and -27 "username or password error" both mean a wrong password.
        let code = (reply["error"] as? [String: Any])?["rspCode"] as? Int
        if [-7, -27].contains(code ?? 0) { throw Failure.wrongPassword }
        throw Failure.badResponse
    }

    static func parseHasCard(_ data: Data) throws -> Bool {
        guard let reply = firstReply(data) else { throw Failure.badResponse }
        guard let disks = (reply["value"] as? [String: Any])?["HddInfo"] as? [[String: Any]] else { return false }
        return disks.contains { ($0["mount"] as? Int) == 1 && (($0["capacity"] as? Int) ?? 0) > 0 }
    }

    /// `Status` lists one entry per month with a `table` string: character n is "1" when day n+1 has recordings.
    static func parseDays(_ data: Data, timeZone: TimeZone) throws -> [Date] {
        guard let reply = firstReply(data) else { throw Failure.badResponse }
        let result = (reply["value"] as? [String: Any])?["SearchResult"] as? [String: Any]
        guard let months = result?["Status"] as? [[String: Any]] else {
            if reply["error"] != nil { throw Failure.badResponse }
            return []
        }
        var days: [Date] = []
        for month in months {
            guard let table = month["table"] as? String else { continue }
            for (index, flag) in table.enumerated() where flag == "1" {
                if let date = date(from: ["year": month["year"] ?? 0, "mon": month["mon"] ?? 0, "day": index + 1], timeZone: timeZone) {
                    days.append(date)
                }
            }
        }
        return days
    }

    static func parseClips(_ data: Data, timeZone: TimeZone) throws -> [Recording] {
        guard let reply = firstReply(data) else { throw Failure.badResponse }
        let result = (reply["value"] as? [String: Any])?["SearchResult"] as? [String: Any]
        guard let files = result?["File"] as? [[String: Any]] else {
            if reply["error"] != nil { throw Failure.badResponse }
            return []
        }
        return files.compactMap { file in
            guard let name = file["name"] as? String,
                  let start = (file["StartTime"] as? [String: Any]).flatMap({ date(from: $0, timeZone: timeZone) }),
                  let end = (file["EndTime"] as? [String: Any]).flatMap({ date(from: $0, timeZone: timeZone) }) else { return nil }
            let size = (file["size"] as? Int) ?? (file["size"] as? String).flatMap(Int.init) ?? 0
            return Recording(name: name, start: start, end: end, size: size)
        }
        .sorted { $0.start < $1.start }
    }
}
