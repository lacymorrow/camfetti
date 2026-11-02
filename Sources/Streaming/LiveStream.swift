import AVFoundation
import CoreMedia
import IPCamKit
import Observation

/// One camera stream: connects, feeds the display layer, recovers on its own.
@MainActor @Observable
final class LiveStream {
    enum Failure: Equatable, Sendable {
        case wrongPassword
        case notFound
        case unsupported
    }

    enum Phase: Equatable, Sendable {
        case idle
        case connecting
        case live
        case reconnecting
        case failed(Failure)
    }

    private(set) var phase: Phase = .idle
    private(set) var resolution: CGSize?
    private(set) var hasAudio = false
    /// Last frame seen, as JPEG. Shown under the video so nothing starts black.
    private(set) var thumbnail: Data?
    var muted = true {
        didSet { audio.setMuted(muted) }
    }

    let layer = AVSampleBufferDisplayLayer()

    private let urls: [String]
    private let credentials: Credentials?
    private let audio = AudioOut()
    private let keyframe = KeyframeBox()
    private let thumbnailSink: (@Sendable (Data) -> Void)?
    private var task: Task<Void, Never>?

    init(urls: [String], username: String?, password: String?, thumbnail: Data? = nil,
         thumbnailSink: (@Sendable (Data) -> Void)? = nil) {
        self.urls = urls
        if let username, !username.isEmpty {
            credentials = Credentials(username: username, password: password ?? "")
        } else {
            credentials = nil
        }
        self.thumbnail = thumbnail
        self.thumbnailSink = thumbnailSink
    }

    func start() {
        guard task == nil else { return }
        phase = .connecting
        let renderer = RendererBox(renderer: layer.sampleBufferRenderer)
        let urls = urls, credentials = credentials, audio = audio, keyframe = keyframe, sink = thumbnailSink
        let pump = StreamPump(urls: urls, credentials: credentials, renderer: renderer, audio: audio,
                              keyframe: keyframe, thumbnailSink: sink) { [weak self] event in
            await self?.handle(event)
        }
        task = Task.detached(priority: .userInitiated) { await pump.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
        audio.stop()
        muted = true
        layer.sampleBufferRenderer.flush()
        phase = .idle
    }

    func retry() {
        stop()
        start()
    }

    /// Full resolution JPEG of the most recent keyframe.
    func snapshot() async -> Data? {
        let box = keyframe
        return await Task.detached { box.jpeg() }.value
    }

    private func handle(_ event: StreamPump.Event) {
        guard task != nil else { return }
        switch event {
        case .connecting: phase = .connecting
        case .reconnecting: phase = .reconnecting
        case let .failed(failure): phase = .failed(failure)
        case let .live(width, height, audio):
            phase = .live
            resolution = CGSize(width: width, height: height)
            hasAudio = audio
        case let .thumbnail(data): thumbnail = data
        }
    }
}

final class RendererBox: @unchecked Sendable {
    let renderer: AVSampleBufferVideoRenderer
    init(renderer: AVSampleBufferVideoRenderer) { self.renderer = renderer }
}

/// Holds the latest keyframe for on-demand snapshots.
final class KeyframeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sample: CMSampleBuffer?
    func set(_ s: CMSampleBuffer) { lock.lock(); sample = s; lock.unlock() }
    func jpeg() -> Data? {
        lock.lock(); let s = sample; lock.unlock()
        return s.flatMap { FrameGrabber.jpeg(from: $0, quality: 0.9) }
    }
}

/// The background loop for one stream. Tries each address in order, keeps the first that
/// answers, and retries with backoff. A wrong password or missing stream stops the loop,
/// because retrying cannot fix those and repeated bad logins can lock a camera.
struct StreamPump: Sendable {
    enum Event: Sendable {
        case connecting
        case reconnecting
        case live(width: Int, height: Int, hasAudio: Bool)
        case failed(LiveStream.Failure)
        case thumbnail(Data)
    }

    enum Outcome: Sendable {
        case retry
        /// The camera hung up during login. Some cameras do this instead of answering 401.
        case loginDropped
        case stop(LiveStream.Failure)
    }

    /// Hang-ups during login in a row before the loop treats the password as rejected.
    static let loginDropLimit = 3

    let urls: [String]
    let credentials: Credentials?
    let renderer: RendererBox
    let audio: AudioOut
    let keyframe: KeyframeBox
    let thumbnailSink: (@Sendable (Data) -> Void)?
    let emit: @Sendable (Event) async -> Void

    /// Cameras often wait a few seconds before rejecting a bad login, so this stays generous.
    static let connectTimeout: Duration = .seconds(12)
    static let stallLimit: TimeInterval = 8
    static let thumbnailInterval: TimeInterval = 10

    func run() async {
        var delay: Double = 0.5
        var everLive = false
        var loginDrops = 0
        while !Task.isCancelled {
            for url in urls where !Task.isCancelled {
                let session = RTSPClientSession(url: url, credentials: credentials, transport: .tcp, userAgent: "CamFetti")
                let wentLive = LiveFlag()
                let result = await play(session, onLive: { wentLive.set() })
                await session.stop()
                if wentLive.value {
                    everLive = true
                    delay = 0.5
                    loginDrops = 0
                }
                switch result {
                case let .stop(failure):
                    await emit(.failed(failure))
                    return
                case .loginDropped:
                    loginDrops += 1
                    if loginDrops >= Self.loginDropLimit {
                        await emit(.failed(.wrongPassword))
                        return
                    }
                case .retry:
                    break
                }
            }
            if Task.isCancelled { return }
            await emit(everLive ? .reconnecting : .connecting)
            try? await Task.sleep(for: .seconds(delay))
            delay = Self.nextDelay(after: delay)
        }
    }

    static func nextDelay(after delay: Double) -> Double { min(delay * 2, 8) }

    /// A hang-up during login. Servers that reject a password by closing the socket show up as a
    /// clean disconnect or as a reset (POSIX 54), depending on timing.
    static func isLoginHangUp(_ error: Error) -> Bool {
        guard let error = error as? RTSPError else { return false }
        switch error {
        case .unexpectedDisconnection: return true
        case let .connectionFailed(message): return message.contains("error 54") || message.localizedCaseInsensitiveContains("reset by peer")
        default: return false
        }
    }

    static func outcome(for error: Error) -> Outcome {
        guard let error = error as? RTSPError else { return .retry }
        switch error {
        case .authenticationFailed: return .stop(.wrongPassword)
        case let .sessionSetupFailed(code, _):
            if code == 401 || code == 403 { return .stop(.wrongPassword) }
            if code == 404 { return .stop(.notFound) }
            return .retry
        default: return .retry
        }
    }

    private func play(_ session: RTSPClientSession, onLive: @Sendable @escaping () -> Void) async -> Outcome {
        do {
            let desc: SessionDescription
            do {
                desc = try await Timeout.run(Self.connectTimeout) { try await session.start() }
            } catch where credentials != nil && Self.isLoginHangUp(error) {
                return .loginDropped
            }
            guard let video = desc.video else { return .stop(.unsupported) }
            if let a = desc.audio, AudioOut.isSupported(a.codec) {
                audio.configure(codec: a.codec, sampleRate: Double(a.sampleRate), channels: UInt32(a.channels ?? 1), extraData: a.extraData)
            }
            let clock = FrameClock()
            return try await withThrowingTaskGroup(of: Outcome.self) { group in
                group.addTask {
                    try await pumpFrames(session, video: video, hasAudio: desc.audio.map { AudioOut.isSupported($0.codec) } ?? false,
                                         clock: clock, onLive: onLive)
                    return .retry
                }
                group.addTask {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(2))
                        if clock.secondsSinceLastFrame > Self.stallLimit { return .retry }
                    }
                    return .retry
                }
                let first = try await group.next() ?? .retry
                group.cancelAll()
                return first
            }
        } catch is CancellationError {
            return .retry
        } catch {
            return Self.outcome(for: error)
        }
    }

    private func pumpFrames(_ session: RTSPClientSession, video: VideoStream, hasAudio: Bool, clock: FrameClock,
                            onLive: @Sendable () -> Void) async throws {
        var format: CMVideoFormatDescription?
        if let sps = video.sps, let pps = video.pps {
            format = try? H26x.formatDescription(codec: video.codec, sps: sps, pps: pps, vps: video.vps)
        }
        var started = false
        var lastThumbnail = Date.distantPast
        for try await item in session.frames() {
            try Task.checkCancellation()
            switch item {
            case let .audio(frame):
                audio.enqueue(frame.data)
            case let .video(frame):
                clock.tick()
                let inBand = H26x.parameterSets(in: frame.nalus, codec: video.codec)
                if let sps = frame.sps ?? inBand.sps, let pps = frame.pps ?? inBand.pps {
                    format = (try? H26x.formatDescription(codec: video.codec, sps: sps, pps: pps, vps: frame.vps ?? inBand.vps)) ?? format
                }
                let isKey = H26x.isRandomAccess(frame.nalus, codec: video.codec, flagged: frame.isKeyframe)
                if !started && !isKey { continue }
                guard let format, let sample = H26x.sampleBuffer(
                    nalus: frame.nalus, codec: video.codec, isKeyframe: isKey, format: format) else { continue }
                if renderer.renderer.status == .failed { renderer.renderer.flush() }
                renderer.renderer.enqueue(sample)
                if !started {
                    started = true
                    onLive()
                    let size = H26x.dimensions(format)
                    await emit(.live(width: size.width, height: size.height, hasAudio: hasAudio))
                }
                if isKey {
                    keyframe.set(sample)
                    if Date().timeIntervalSince(lastThumbnail) >= Self.thumbnailInterval {
                        lastThumbnail = Date()
                        if let jpeg = FrameGrabber.jpeg(from: sample, maxWidth: 640, quality: 0.6) {
                            thumbnailSink?(jpeg)
                            await emit(.thumbnail(jpeg))
                        }
                    }
                }
            case .metadata, .rtcp:
                break
            }
        }
    }
}

final class LiveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

final class FrameClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    func tick() { lock.lock(); last = Date(); lock.unlock() }
    var secondsSinceLastFrame: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(last)
    }
}

enum Timeout {
    struct Expired: Error {}

    static func run<T: Sendable>(_ limit: Duration, _ work: @Sendable @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw Expired()
            }
            guard let first = try await group.next() else { throw Expired() }
            group.cancelAll()
            return first
        }
    }
}
