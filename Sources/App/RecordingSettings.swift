import Foundation
import Observation

/// The "Record to SD Card" switch for a Thingino or Reolink camera. It changes the camera right away.
/// Thingino: on means record nonstop now and after every reboot, deleting the oldest clips when the card fills.
/// Reolink: on means the camera's own schedule records, replacing the oldest clips when the card fills, and
/// newer firmware also picks what to record (`modes`).
@MainActor @Observable
final class RecordingSettings {
    enum Phase: Equatable {
        case checking
        /// The app has no key for the camera's web page yet.
        case needsWebPassword
        /// A Reolink refused the saved password. Never retried, because cameras lock out.
        case wrongPassword
        case noCard
        /// `usable` is the partition the camera records to; `card` is the whole card.
        case cardTooSmall(usable: Int64, card: Int64)
        /// `on` is the saved setting; `recordingNow` is what the camera is doing this minute.
        case ready(on: Bool, recordingNow: Bool)
        case failed(String)
    }

    private(set) var phase: Phase = .checking {
        didSet { if case .ready(let on, _) = phase { lastOn = on } }
    }
    /// What the camera was last seen doing, so a refused change doesn't flip the switch.
    private var lastOn = false
    private(set) var busy = false
    /// The card the camera records to, for the note.
    private(set) var cardBytes: Int64?
    /// What the camera can be set to record. Empty when it only turns on and off.
    private(set) var modes: [ReolinkClient.RecordMode] = []
    /// Nil when the camera keeps its own schedule that isn't one of `modes`.
    private(set) var mode: ReolinkClient.RecordMode?
    /// The AI triggers a Reolink has, for naming the smart mode.
    private(set) var aiTriggers: [String] = []
    private let client: ThinginoClient?
    /// Home first, then away. Empty for a Thingino camera.
    private let reolinks: [ReolinkClient]
    private let cameraID: UUID?

    init(client: ThinginoClient?) {
        self.client = client
        reolinks = []
        cameraID = nil
    }

    init(reolink clients: [ReolinkClient], cameraID: UUID) {
        client = nil
        reolinks = clients
        self.cameraID = cameraID
    }

    var isReolink: Bool { !reolinks.isEmpty }

    var isOn: Bool {
        if case .ready(let on, _) = phase { return on }
        return lastOn
    }

    func load() async {
        if isReolink { await reolink { client, token in try await self.read(client, token) }; return }
        guard let client, client.apiKey != nil else { phase = .needsWebPassword; return }
        phase = .checking
        do {
            let card = try await client.card()
            guard card.present else { phase = .noCard; return }
            var settings = try await client.recorderSettings()
            let usable = ThinginoClient.recordingMount(settings).map(card.usableBytes) ?? card.sizeBytes
            guard usable >= ThinginoClient.smallestCardBytes else {
                phase = .cardTooSmall(usable: usable, card: card.sizeBytes)
                return
            }
            let recording = try await client.isRecording()
            if ThinginoClient.lostSettings(settings, recording: recording),
               let restored = try await client.restoreRecorder(settings, card: card) {
                settings = restored
            }
            cardBytes = usable
            phase = .ready(on: settings.autostart, recordingNow: recording)
        } catch {
            phase = Self.describe(error)
        }
    }

    func set(_ on: Bool) async {
        if isReolink {
            await change { config in
                if on { config.turnOn() } else { config.enabled = false }
            }
            return
        }
        guard let client, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let current = try await client.recorderSettings()
            if on {
                let card = try await client.card()
                let usable = ThinginoClient.recordingMount(current).map(card.usableBytes) ?? card.sizeBytes
                guard usable >= ThinginoClient.smallestCardBytes else {
                    phase = card.present ? .cardTooSmall(usable: usable, card: card.sizeBytes) : .noCard
                    return
                }
                guard let next = ThinginoClient.recordingOn(current, card: card) else {
                    phase = .failed("The camera hasn't mounted its SD card. Try taking the card out and putting it back.")
                    return
                }
                try await client.saveRecorder(next)
                if try await !client.isRecording() { try await client.startRecording() }
            } else {
                if try await client.isRecording() { try await client.stopRecording() }
                var next = current
                next.autostart = false
                if next.mount.isEmpty { next.mount = next.mounts.first ?? "" }
                if !next.mount.isEmpty { try await client.saveRecorder(next) }
            }
            phase = .ready(on: on, recordingNow: try await client.isRecording())
        } catch {
            phase = Self.describe(error)
        }
    }

    /// Picks what a Reolink records. Turns recording on too, since choosing a mode means wanting it.
    func choose(_ mode: ReolinkClient.RecordMode) async {
        await change { config in
            config.apply(mode)
            config.turnOn()
        }
    }

    // MARK: Reolink

    private func change(_ edit: @escaping @MainActor (inout ReolinkClient.RecordConfig) -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await reolink { client, token in
            var config = try await client.recordConfig(token)
            edit(&config)
            try await client.saveRecord(config, token: token)
            try await self.read(client, token)
        }
    }

    private func read(_ client: ReolinkClient, _ token: String) async throws {
        guard let card = try await client.cardBytes(token) else { phase = .noCard; return }
        let config = try await client.recordConfig(token)
        cardBytes = card
        modes = config.modes
        mode = config.mode
        aiTriggers = config.aiTriggers
        let on = config.enabled && !config.recordsNothing
        phase = .ready(on: on, recordingNow: on)
    }

    /// Signs in once per host, home first, and never retries a wrong password.
    private func reolink(_ work: @escaping @MainActor (ReolinkClient, String) async throws -> Void) async {
        guard let id = cameraID else { return }
        guard !PlaybackModel.isRefused(id) else { phase = .wrongPassword; return }
        if case .ready = phase {} else { phase = .checking }
        for client in reolinks {
            let token: String
            do {
                token = try await client.login()
            } catch ReolinkClient.Failure.wrongPassword {
                PlaybackModel.refuse(id)
                phase = .wrongPassword
                return
            } catch {
                continue
            }
            do {
                try await work(client, token)
            } catch {
                phase = Self.describe(error)
            }
            await client.logout(token)
            return
        }
        phase = .failed("Couldn't reach the camera.")
    }

    static func describe(_ error: Error) -> Phase {
        switch error {
        case ThinginoClient.Failure.wrongPassword:
            // Never retried: the sheet shows the web password field instead.
            return .needsWebPassword
        case ThinginoClient.RecorderFailure.refused(let reason), ReolinkClient.Failure.refused(let reason):
            return .failed("The camera said: \(reason)")
        case ReolinkClient.Failure.wrongPassword:
            return .wrongPassword
        case ReolinkClient.Failure.notAllowed:
            return .failed("This camera won't let CamFetti's account change recording. Change it in the Reolink app, or add the camera again with its admin account.")
        default:
            return .failed("Couldn't reach the camera.")
        }
    }
}
