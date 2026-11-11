import AVFoundation
import Foundation
import Observation

/// Where a camera's SD card recordings come from: Reolink's API or Thingino's file manager.
protocol RecordingSource: Sendable {
    /// Days with recordings since `from`, newest first.
    func days(from: Date) async throws -> [Date]
    /// Clips on that day, oldest first.
    func clips(on day: Date) async throws -> [Recording]
    /// Something the system player can open: a stream that seeks, or a local copy.
    func media(for clip: Recording) async throws -> URL
    /// The clips worth watching, for a camera that records nonstop. Nil when every clip is already an event.
    func highlights(in clips: [Recording]) -> [Recording]?
    func close() async
}

extension RecordingSource {
    func highlights(in clips: [Recording]) -> [Recording]? { nil }
}

struct ReolinkSource: RecordingSource {
    let client: ReolinkClient
    let token: String

    func days(from: Date) async throws -> [Date] { try await client.days(token, from: from, to: Date()) }
    func clips(on day: Date) async throws -> [Recording] { try await client.clips(token, on: day) }
    /// Reolink answers Range requests, so clips stream and seek straight from the camera.
    func media(for clip: Recording) async throws -> URL {
        guard let url = client.playbackURL(for: clip, token: token) else { throw ReolinkClient.Failure.badResponse }
        return url
    }
    func close() async { await client.logout(token) }
}

extension ThinginoRecordings: RecordingSource {
    func clips(on day: Date) async throws -> [Recording] { try await clips(on: day, now: Date()) }

    /// Thingino can't stream with seeking, so clips (about 3 MB a minute) are copied to the phone first.
    /// Copies live in a temporary folder that `close` empties.
    func media(for clip: Recording) async throws -> URL {
        let folder = Self.cacheFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = clip.name.replacingOccurrences(of: "/", with: "_")
        let file = folder.appending(path: name)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        try await client.download(path: clip.name, to: file)
        return file
    }

    func highlights(in clips: [Recording]) -> [Recording]? { Self.activity(in: clips) }

    func close() async { try? FileManager.default.removeItem(at: Self.cacheFolder) }

    static var cacheFolder: URL { FileManager.default.temporaryDirectory.appending(path: "camfetti-playback") }
}

/// Plays back what a camera recorded to its own SD card.
@MainActor @Observable
final class PlaybackModel {
    enum Phase: Equatable {
        case loading
        case ready
        case noCard
        /// A Thingino camera whose recorder isn't switched on.
        case notRecording
        case noRecordings
        case wrongPassword
        case unreachable
    }

    let camera: Camera
    private(set) var phase: Phase = .loading
    /// Days with recordings, newest first.
    private(set) var days: [Date] = []
    private(set) var day: Date?
    /// Clips on `day`, oldest first, so the timeline reads left to right.
    private(set) var clips: [Recording] = []
    /// Clips on `day` with activity, for a camera that records nonstop. Nil when every clip is an event.
    private(set) var highlights: [Recording]?
    /// Shows only `highlights`. The choice carries from day to day.
    var activityOnly = true
    private(set) var loadingDay = false
    private(set) var current: Recording?
    /// True while the picked clip is being fetched.
    private(set) var preparing = false
    /// The picked clip couldn't be fetched.
    private(set) var clipFailed = false
    let player = AVPlayer()
    /// What the strip shows and what plays next.
    var visibleClips: [Recording] { activityOnly ? highlights ?? clips : clips }
    private var playTask: Task<Void, Never>?

    private var source: RecordingSource?
    private var endObserver: NSObjectProtocol?

    /// Cameras whose sign-in failed this session. They are never asked again until the password is edited,
    /// because cameras lock out after repeated failures.
    private static var refused: Set<UUID> = []

    static func forgetRefusal(_ id: UUID) { refused.remove(id) }

    init(camera: Camera) {
        self.camera = camera
    }

    /// Hosts to try, home first.
    private var hosts: [String] {
        var list = [camera.host]
        if let away = camera.awayHost?.trimmingCharacters(in: .whitespaces), !away.isEmpty { list.append(away) }
        return list
    }

    func start() async {
        guard !Self.refused.contains(camera.id) else { phase = .wrongPassword; return }
        phase = .loading
        do {
            guard let source = try await (camera.kind == .thingino ? openThingino() : openReolink()) else { return }
            self.source = source
            let from = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
            days = try await source.days(from: from)
            guard let newest = days.first else {
                if phase == .loading { phase = .noRecordings }
                return
            }
            phase = .ready
            await select(day: newest, playLatest: true)
        } catch ThinginoClient.Failure.wrongPassword {
            Self.refused.insert(camera.id)
            phase = .wrongPassword
        } catch {
            phase = .unreachable
        }
    }

    /// Signs in once per host and never retries a wrong password.
    private func openReolink() async throws -> RecordingSource? {
        let password = CameraSecrets(id: camera.id).password ?? ""
        for host in hosts {
            guard let base = camera.webBase(host: host) else { continue }
            let client = ReolinkClient(base: base, username: camera.username, password: password)
            do {
                let token = try await client.login()
                guard try await client.hasCard(token) else {
                    await client.logout(token)
                    phase = .noCard
                    return nil
                }
                return ReolinkSource(client: client, token: token)
            } catch ReolinkClient.Failure.wrongPassword {
                Self.refused.insert(camera.id)
                phase = .wrongPassword
                return nil
            } catch {
                continue
            }
        }
        phase = .unreachable
        return nil
    }

    /// Uses the camera's API key. A camera that was never set to record says so, instead of "no recordings".
    private func openThingino() async throws -> RecordingSource? {
        guard let key = CameraSecrets(id: camera.id).apiKey else { phase = .wrongPassword; return nil }
        for host in hosts {
            guard let base = camera.webBase(host: host) else { continue }
            let client = ThinginoClient(base: base, apiKey: key)
            var settings: ThinginoClient.RecorderSettings
            do {
                settings = try await client.recorderSettings()
            } catch ThinginoClient.Failure.wrongPassword {
                throw ThinginoClient.Failure.wrongPassword
            } catch {
                continue
            }
            if settings.mount.isEmpty, (try? await client.isRecording()) == true,
               let card = try? await client.card(),
               let restored = try? await client.restoreRecorder(settings, card: card) {
                settings = restored
            }
            guard !settings.mount.isEmpty else { phase = .notRecording; return nil }
            guard settings.mounts.contains(settings.mount) else { phase = .noCard; return nil }
            guard let root = try await ThinginoRecordings.findRoot(client: client, mount: settings.mount,
                                                                   devicePath: settings.devicePath) else {
                phase = settings.autostart ? .noRecordings : .notRecording
                return nil
            }
            return ThinginoRecordings(client: client, root: root, clipSeconds: settings.duration)
        }
        phase = .unreachable
        return nil
    }

    func select(day: Date, playLatest: Bool = false) async {
        guard let source else { return }
        self.day = day
        loadingDay = true
        defer { loadingDay = false }
        clips = (try? await source.clips(on: day)) ?? []
        highlights = source.highlights(in: clips)
        if let pick = playLatest ? visibleClips.last : visibleClips.first { play(pick) }
    }

    func play(_ clip: Recording) {
        current = clip
        preparing = true
        playTask?.cancel()
        playTask = Task { await load(clip) }
    }

    private func load(_ clip: Recording) async {
        guard let source else { return }
        let url: URL
        do {
            url = try await source.media(for: clip)
        } catch {
            if current == clip { preparing = false; clipFailed = true }
            return
        }
        // Another clip was picked while this one was coming in.
        guard !Task.isCancelled, current == clip else { return }
        clipFailed = false
        preparing = false
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.playNext() }
        }
        player.play()
        // Fetch the next clip now, so playback rolls on without a pause.
        let upcoming = visibleClips
        if let index = upcoming.firstIndex(of: clip), index + 1 < upcoming.count {
            _ = try? await source.media(for: upcoming[index + 1])
        }
    }

    /// Clips follow each other in time, so the next one is what happened next.
    func playNext() {
        let upcoming = visibleClips
        guard let current, let index = upcoming.firstIndex(of: current), index + 1 < upcoming.count else { return }
        play(upcoming[index + 1])
    }

    /// Switches between activity and every clip, and starts the newest clip if the playing one left the strip.
    func toggleActivityOnly() {
        activityOnly.toggle()
        if let current, visibleClips.contains(current) { return }
        if let newest = visibleClips.last { play(newest) }
    }

    func stop() async {
        playTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        await source?.close()
        source = nil
    }
}
