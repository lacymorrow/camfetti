import Foundation

/// Talks to the Thingino web API. Signs in once with the web password, keeps only an API key.
struct ThinginoClient: Sendable {
    enum Failure: Error, Equatable {
        case wrongPassword
        case notThingino
        case badResponse
    }

    struct StreamConfig: Equatable, Sendable {
        var username: String
        var password: String
        var port: Int
        var mainPath: String
        var subPath: String
    }

    enum DayNight: String, CaseIterable, Sendable {
        case auto, day, night
    }

    /// `session` must not store cookies globally; sign-in uses the returned cookie only.
    let base: URL
    var apiKey: String?
    var session: URLSession = .shared

    static func defaultPaths(streamer: String?) -> (main: String, sub: String) {
        streamer == "raptor" ? ("stream0", "stream1") : ("ch0", "ch1")
    }

    /// True if the web root identifies as Thingino.
    func isThingino() async -> Bool {
        var request = URLRequest(url: base, timeoutInterval: 3)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await session.data(for: request) else { return false }
        return String(decoding: data, as: UTF8.self).lowercased().contains("thingino")
    }

    /// Signs in and returns an API key, reusing the camera's key if it already has one.
    func mintAPIKey(password: String) async throws -> String {
        var login = request("/x/login.cgi", method: "POST")
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoded = Data(password.utf8).base64EncodedString()
        login.httpBody = try JSONSerialization.data(withJSONObject: ["username": "root", "password": encoded, "encoding": "base64"])
        let (_, loginResponse) = try await session.data(for: login)
        guard let http = loginResponse as? HTTPURLResponse else { throw Failure.badResponse }
        if http.statusCode == 401 { throw Failure.wrongPassword }
        if http.statusCode == 404 { throw Failure.notThingino }
        guard http.statusCode == 200, let cookie = Self.sessionCookie(from: http) else { throw Failure.badResponse }

        var get = request("/x/api-key.cgi", method: "GET")
        get.setValue(cookie, forHTTPHeaderField: "Cookie")
        let (existing, _) = try await session.data(for: get)
        if let key = Self.apiKey(in: existing) { return key }

        var post = request("/x/api-key.cgi", method: "POST")
        post.setValue(cookie, forHTTPHeaderField: "Cookie")
        let (created, _) = try await session.data(for: post)
        guard let key = Self.apiKey(in: created) else { throw Failure.badResponse }
        return key
    }

    /// RTSP credentials and paths from the camera. Raptor builds may not have this endpoint.
    func streamConfig() async throws -> StreamConfig {
        let (data, response) = try await session.data(for: request("/x/json-config-rtsp.cgi", method: "GET"))
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 401 { throw Failure.wrongPassword }
        guard status == 200, let config = Self.parseStreamConfig(data) else { throw Failure.badResponse }
        return config
    }

    /// One JPEG from the camera's snapshot endpoint. A 401 is never retried, because cameras lock out.
    func snapshot() async throws -> Data {
        let (data, response) = try await session.data(for: request("/x/ch0.jpg", method: "GET", timeout: 6))
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 401 { throw Failure.wrongPassword }
        guard status == 200, !data.isEmpty else { throw Failure.badResponse }
        return data
    }

    func setDayNight(_ mode: DayNight) async throws {
        var post = request("/x/json-imp.cgi", method: "POST")
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = mode == .auto ? ["cmd": "auto", "val": "1"] : ["cmd": "daynight", "val": mode.rawValue]
        post.httpBody = try JSONSerialization.data(withJSONObject: body)
        try await send(post)
    }

    /// Relative move in motor steps. Only integers reach the URL, on purpose.
    func move(dx: Int, dy: Int) async throws {
        try await send(request("/x/json-motor.cgi?d=g&x=\(dx)&y=\(dy)", method: "GET"))
    }

    func stopMotors() async throws {
        try await send(request("/x/json-motor.cgi?d=s", method: "GET"))
    }

    /// True when the camera has motors and reports their position.
    func hasMotors() async -> Bool {
        guard let (data, response) = try? await session.data(for: request("/x/json-motor.cgi?d=j", method: "GET")),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["error"] == nil
    }

    private func send(_ request: URLRequest) async throws {
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw Failure.wrongPassword }
        guard status == 200 else { throw Failure.badResponse }
    }

    func request(_ path: String, method: String, timeout: TimeInterval = 5) -> URLRequest {
        var r = URLRequest(url: URL(string: Self.authenticatedPath(path, apiKey: apiKey), relativeTo: base)!.absoluteURL,
                           timeoutInterval: timeout)
        r.httpMethod = method
        r.httpShouldHandleCookies = false
        if let apiKey { r.setValue(apiKey, forHTTPHeaderField: "X-API-Key") }
        return r
    }

    /// Real cameras answered 401 to the X-API-Key header alone (found on a Wyze v3, 2026-10-31), so the
    /// key also goes in `token=`, which the firmware accepts. Hex only, because json-motor.cgi evals
    /// its query string.
    static func authenticatedPath(_ path: String, apiKey: String?) -> String {
        guard let apiKey, !apiKey.isEmpty, apiKey.allSatisfy(\.isHexDigit) else { return path }
        return path + (path.contains("?") ? "&" : "?") + "token=\(apiKey)"
    }

    // MARK: Pure helpers

    static func sessionCookie(from response: HTTPURLResponse) -> String? {
        guard let header = response.value(forHTTPHeaderField: "Set-Cookie") else { return nil }
        return header.split(separator: ";").first.map(String.init)
    }

    static func apiKey(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["api_key"] as? String)?.nilIfEmpty
    }

    static func parseStreamConfig(_ data: Data) -> StreamConfig? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func str(_ k: String) -> String { (json[k] as? String) ?? (json[k] as? Int).map(String.init) ?? "" }
        return StreamConfig(username: str("username"), password: str("password"),
                            port: Int(str("rtsp_port")) ?? 554,
                            mainPath: str("rtsp_ch0").nilIfEmpty ?? "ch0",
                            subPath: str("rtsp_ch1").nilIfEmpty ?? "ch1")
    }
}
