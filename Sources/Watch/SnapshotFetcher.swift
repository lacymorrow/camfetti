import Foundation

/// One current picture of a camera, from the cheapest source it has:
/// the Thingino snapshot endpoint, then the ONVIF snapshot URL, then a keyframe from the RTSP stream.
/// A camera whose snapshot URL fails (Reolink wants the password in the query string, and answers
/// 200 with a JSON error otherwise) still gets a picture from its stream.
/// Home address first, away address second, like the live streams.
@MainActor
final class SnapshotFetcher {
    static let shared = SnapshotFetcher()

    /// How long to wait for a first keyframe when a camera has no snapshot URL.
    static let keyframeWait: Duration = .seconds(6)
    /// An RTSP stream stays up this long after its last request, so a 2 s refresh does not reconnect each time.
    static let streamLinger: Duration = .seconds(20)

    private var streams: [UUID: LiveStream] = [:]
    private var lingering: [UUID: Task<Void, Never>] = [:]

    /// Full-size JPEG, or nil when the camera cannot be reached.
    func jpeg(for camera: Camera) async -> Data? {
        var useStream = true
        if camera.kind == .thingino {
            for host in hosts(for: camera) {
                guard let base = camera.webBase(host: host) else { continue }
                let client = ThinginoClient(base: base, apiKey: CameraSecrets(id: camera.id).apiKey, session: Self.session)
                do {
                    return try await client.snapshot()
                } catch ThinginoClient.Failure.badResponse {
                    continue
                } catch ThinginoClient.Failure.wrongPassword {
                    return nil
                } catch {
                    useStream = false
                }
            }
            if !useStream { return nil }
        }
        if let snapshotURL = camera.onvif?.snapshotURL {
            for host in hosts(for: camera) {
                let url = host == camera.host ? snapshotURL : Camera.replacingHost(in: snapshotURL, with: host)
                if let data = await Self.fetch(url, username: camera.username, password: CameraSecrets(id: camera.id).password) {
                    return data
                }
            }
        }
        return await keyframe(for: camera)
    }

    private func hosts(for camera: Camera) -> [String] {
        var hosts = [camera.host]
        if let away = camera.awayHost?.trimmingCharacters(in: .whitespaces), !away.isEmpty { hosts.append(away) }
        return hosts
    }

    // MARK: HTTP

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 6
        return URLSession(configuration: config)
    }()

    private static func fetch(_ url: String, username: String, password: String?) async -> Data? {
        guard let target = URL(string: url) else { return nil }
        let delegate = BasicDigestOnce(username: username, password: password ?? "")
        let session = URLSession(configuration: session.configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: target),
              (response as? HTTPURLResponse)?.statusCode == 200, isJPEG(data) else { return nil }
        return data
    }

    /// Some cameras answer 200 with an error page or JSON. Only a real JPEG counts.
    nonisolated static func isJPEG(_ data: Data) -> Bool {
        data.count > 3 && data.starts(with: [0xFF, 0xD8, 0xFF])
    }

    /// Answers a Basic or Digest challenge once. A second challenge means the password is wrong,
    /// and asking again could lock the camera.
    private final class BasicDigestOnce: NSObject, URLSessionTaskDelegate, Sendable {
        let username: String
        let password: String
        init(username: String, password: String) {
            self.username = username
            self.password = password
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
            -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            let method = challenge.protectionSpace.authenticationMethod
            guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest,
                  challenge.previousFailureCount == 0, !username.isEmpty else { return (.cancelAuthenticationChallenge, nil) }
            return (.useCredential, URLCredential(user: username, password: password, persistence: .none))
        }
    }

    // MARK: RTSP keyframe

    private func keyframe(for camera: Camera) async -> Data? {
        let stream: LiveStream
        if let existing = streams[camera.id] {
            stream = existing
        } else {
            stream = LiveStream(urls: AppModel.addresses(for: camera, url: camera.gridURL), username: camera.username,
                                password: CameraSecrets(id: camera.id).password)
            streams[camera.id] = stream
            stream.start()
        }
        scheduleTeardown(camera.id)
        let deadline = ContinuousClock.now + Self.keyframeWait
        while ContinuousClock.now < deadline {
            if let data = await stream.snapshot() { return data }
            if case .failed = stream.phase { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    private func scheduleTeardown(_ id: UUID) {
        lingering[id]?.cancel()
        lingering[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.streamLinger)
            guard !Task.isCancelled, let self else { return }
            self.streams[id]?.stop()
            self.streams[id] = nil
            self.lingering[id] = nil
        }
    }
}
