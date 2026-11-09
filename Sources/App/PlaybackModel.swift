import AVFoundation
import Foundation
import Observation

/// Plays back what a camera recorded to its own SD card. Reolink only for now; Thingino follows once
/// its recorder can be switched on from the app.
@MainActor @Observable
final class PlaybackModel {
    enum Phase: Equatable {
        case loading
        case ready
        case noCard
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
    private(set) var loadingDay = false
    private(set) var current: Recording?
    let player = AVPlayer()

    private var client: ReolinkClient?
    private var token: String?
    private var endObserver: NSObjectProtocol?

    /// Cameras whose sign-in failed this session. They are never asked again until the password is edited,
    /// because cameras lock out after repeated failures.
    private static var refused: Set<UUID> = []

    static func forgetRefusal(_ id: UUID) { refused.remove(id) }

    init(camera: Camera) {
        self.camera = camera
    }

    /// Hosts to try, home first. Reolink's API is on the camera's web port.
    private var hosts: [String] {
        var list = [camera.host]
        if let away = camera.awayHost?.trimmingCharacters(in: .whitespaces), !away.isEmpty { list.append(away) }
        return list
    }

    func start() async {
        guard !Self.refused.contains(camera.id) else { phase = .wrongPassword; return }
        phase = .loading
        let password = CameraSecrets(id: camera.id).password ?? ""
        for host in hosts {
            guard let base = camera.webBase(host: host) else { continue }
            let candidate = ReolinkClient(base: base, username: camera.username, password: password)
            do {
                let token = try await candidate.login()
                client = candidate
                self.token = token
                break
            } catch ReolinkClient.Failure.wrongPassword {
                Self.refused.insert(camera.id)
                phase = .wrongPassword
                return
            } catch {
                continue
            }
        }
        guard let client, let token else { phase = .unreachable; return }
        do {
            guard try await client.hasCard(token) else { phase = .noCard; return }
            let now = Date()
            let from = Calendar.current.date(byAdding: .day, value: -90, to: now) ?? now
            days = try await client.days(token, from: from, to: now)
            guard let newest = days.first else { phase = .noRecordings; return }
            phase = .ready
            await select(day: newest, playLatest: true)
        } catch {
            phase = .unreachable
        }
    }

    func select(day: Date, playLatest: Bool = false) async {
        guard let client, let token else { return }
        self.day = day
        loadingDay = true
        defer { loadingDay = false }
        clips = (try? await client.clips(token, on: day)) ?? []
        if let pick = playLatest ? clips.last : clips.first { play(pick) }
    }

    func play(_ clip: Recording) {
        guard let client, let token, let url = client.playbackURL(for: clip, token: token) else { return }
        current = clip
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.playNext() }
        }
        player.play()
    }

    /// Clips are motion events, so the next one is the next thing that happened.
    func playNext() {
        guard let current, let index = clips.firstIndex(of: current), index + 1 < clips.count else { return }
        play(clips[index + 1])
    }

    func stop() async {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let client, let token { await client.logout(token) }
        token = nil
    }
}
