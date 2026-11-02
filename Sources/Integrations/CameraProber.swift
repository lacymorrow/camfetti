import Foundation
import IPCamKit

/// Turns what the person typed into a working camera: works out what it is, finds its streams,
/// and proves video arrives before anything is saved.
struct CameraProber: Sendable {
    enum Failure: Error, Equatable {
        case wrongPassword
        case unreachable
        case noStream
        case invalidAddress
    }

    struct Result: Sendable {
        var camera: Camera
        var password: String?
        var apiKey: String?
    }

    struct Input: Sendable {
        var address: String
        var username: String
        var password: String
        var isThingino = false
        var httpPort: Int?
        var streamer: String?
        var name: String?
        /// When the web password is wrong, still try Thingino's default stream login. Live video
        /// then works and the web password only unlocks the controls.
        var fallbackToDefaultStream = false
    }

    /// Accepts a bare host, host:port, or a full rtsp:// or http:// URL.
    static func parseAddress(_ raw: String) -> (scheme: String?, host: String, port: Int?, url: String?)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("://") {
            guard let c = URLComponents(string: text), let host = c.host, !host.isEmpty else { return nil }
            return (c.scheme?.lowercased(), host, c.port, text)
        }
        guard let c = URLComponents(string: "x://\(text)"), let host = c.host, !host.isEmpty else { return nil }
        return (nil, host, c.port, nil)
    }

    func probe(_ input: Input) async throws -> Result {
        guard let parsed = Self.parseAddress(input.address) else { throw Failure.invalidAddress }

        if let scheme = parsed.scheme, scheme == "rtsp" || scheme == "rtsps", let url = parsed.url {
            return try await probeRTSP(url: url, input: input, host: parsed.host)
        }

        let httpPort = input.httpPort ?? parsed.port ?? 80
        let base = URL(string: "http://\(Camera.bracket(parsed.host))\(httpPort == 80 ? "" : ":\(httpPort)")")!
        if input.isThingino {
            return try await probeThingino(base: base, host: parsed.host, httpPort: httpPort, input: input)
        }
        if parsed.port == nil || parsed.scheme == "http", await ThinginoClient(base: base).isThingino() {
            return try await probeThingino(base: base, host: parsed.host, httpPort: httpPort, input: input)
        }
        if let result = try await probeOnvif(host: parsed.host, explicitPort: parsed.port, input: input) {
            return result
        }
        return try await probeTemplates(host: parsed.host, input: input)
    }

    private func probeRTSP(url: String, input: Input, host: String) async throws -> Result {
        let stripped = Camera.strippingCredentials(url)
        let user = stripped.user ?? input.username
        let pass = stripped.password ?? input.password
        try await Self.testStream(url: stripped.url, username: user, password: pass)
        let camera = Camera(name: input.name ?? host, kind: .rtsp, host: host, mainURL: stripped.url, username: user)
        return Result(camera: camera, password: pass)
    }

    private func probeThingino(base: URL, host: String, httpPort: Int, input: Input) async throws -> Result {
        let key: String
        do {
            key = try await ThinginoClient(base: base).mintAPIKey(password: input.password)
        } catch ThinginoClient.Failure.wrongPassword {
            guard input.fallbackToDefaultStream else { throw Failure.wrongPassword }
            return try await probeThinginoDefaultStream(host: host, httpPort: httpPort, input: input)
        } catch ThinginoClient.Failure.notThingino {
            throw Failure.noStream
        } catch {
            throw Failure.unreachable
        }
        let client = ThinginoClient(base: base, apiKey: key)
        let paths = ThinginoClient.defaultPaths(streamer: input.streamer)
        let config = (try? await client.streamConfig()) ?? .init(
            username: "thingino", password: "thingino", port: 554, mainPath: paths.main, subPath: paths.sub)
        let root = "rtsp://\(Camera.bracket(host)):\(config.port)/"
        let main = root + config.mainPath, sub = root + config.subPath
        try await Self.testStream(url: sub, username: config.username, password: config.password)
        var camera = Camera(name: input.name ?? host, kind: .thingino, host: host, mainURL: main, subURL: sub,
                            username: config.username, httpPort: httpPort, streamer: input.streamer)
        camera.canPan = await client.hasMotors()
        return Result(camera: camera, password: config.password, apiKey: key)
    }

    /// View-only Thingino: default stream login, no API key.
    private func probeThinginoDefaultStream(host: String, httpPort: Int, input: Input) async throws -> Result {
        let candidates: [(main: String, sub: String)]
        switch input.streamer {
        case "raptor": candidates = [("stream0", "stream1")]
        case "prudynt": candidates = [("ch0", "ch1")]
        default: candidates = [("ch0", "ch1"), ("stream0", "stream1")]
        }
        let user = "thingino", pass = "thingino", root = "rtsp://\(Camera.bracket(host)):554/"
        for paths in candidates {
            do {
                try await Self.testStream(url: root + paths.sub, username: user, password: pass)
            } catch Failure.noStream {
                continue
            }
            let camera = Camera(name: input.name ?? host, kind: .thingino, host: host, mainURL: root + paths.main,
                                subURL: root + paths.sub, username: user, httpPort: httpPort, streamer: input.streamer)
            return Result(camera: camera, password: pass, apiKey: nil)
        }
        throw Failure.noStream
    }

    private func probeOnvif(host: String, explicitPort: Int?, input: Input) async throws -> Result? {
        let ports = explicitPort.map { [$0] } ?? OnvifClient.commonPorts
        for port in ports {
            let device = "http://\(Camera.bracket(host)):\(port)/onvif/device_service"
            let client = OnvifClient(deviceURL: device, username: input.username, password: input.password)
            do {
                let found = try await client.discover()
                let main = Camera.strippingCredentials(found.mainStream).url
                let sub = found.subStream.map { Camera.strippingCredentials($0).url }
                try await Self.testStream(url: sub ?? main, username: input.username, password: input.password)
                let onvif = Camera.Onvif(deviceURL: device, mediaURL: found.mediaURL, ptzURL: found.ptzURL,
                                         profileToken: found.mainProfile.token, snapshotURL: found.snapshotURL)
                let camera = Camera(name: input.name ?? found.name ?? host, kind: .onvif, host: host, mainURL: main,
                                    subURL: sub, username: input.username, onvif: onvif, canPan: found.ptzURL != nil)
                return Result(camera: camera, password: input.password)
            } catch let failure as OnvifClient.Failure where failure.kind == .unauthorized {
                throw Failure.wrongPassword
            } catch Failure.wrongPassword {
                throw Failure.wrongPassword
            } catch {
                continue
            }
        }
        return nil
    }

    private func probeTemplates(host: String, input: Input) async throws -> Result {
        var sawAuthFailure = false
        for template in BrandTemplate.probeOrder {
            let main = template.url(host: host, path: template.mainPath)
            do {
                try await Self.testStream(url: main, username: input.username, password: input.password)
                let camera = Camera(name: input.name ?? "\(template.name) camera", kind: .rtsp, host: host, mainURL: main,
                                    subURL: template.subPath.map { template.url(host: host, path: $0) }, username: input.username)
                return Result(camera: camera, password: input.password)
            } catch Failure.wrongPassword {
                // One wrong login is enough. Trying more paths risks locking the camera.
                sawAuthFailure = true
                break
            } catch Failure.unreachable {
                throw Failure.unreachable
            } catch {
                continue
            }
        }
        throw sawAuthFailure ? Failure.wrongPassword : Failure.noStream
    }

    /// Connects, reads the stream description, and disconnects.
    static func testStream(url: String, username: String, password: String) async throws {
        let credentials = username.isEmpty ? nil : Credentials(username: username, password: password)
        let session = RTSPClientSession(url: url, credentials: credentials, transport: .tcp, userAgent: "CamFetti")
        do {
            let desc = try await Timeout.run(StreamPump.connectTimeout) { try await session.start() }
            await session.stop()
            guard desc.video != nil else { throw Failure.noStream }
        } catch let failure as Failure {
            await session.stop()
            throw failure
        } catch where credentials != nil && StreamPump.isLoginHangUp(error) {
            // Some cameras hang up on a bad login instead of answering 401.
            await session.stop()
            throw Failure.wrongPassword
        } catch {
            await session.stop()
            switch StreamPump.outcome(for: error) {
            case .stop(.wrongPassword): throw Failure.wrongPassword
            case .stop: throw Failure.noStream
            case .retry, .loginDropped: throw Failure.unreachable
            }
        }
    }
}
