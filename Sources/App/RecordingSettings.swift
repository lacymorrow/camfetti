import Foundation
import Observation

/// The "Record to SD Card" switch for a Thingino camera. It changes the camera right away:
/// on means record nonstop now and after every reboot, deleting the oldest clips when the card fills.
@MainActor @Observable
final class RecordingSettings {
    enum Phase: Equatable {
        case checking
        /// The app has no key for the camera's web page yet.
        case needsWebPassword
        case noCard
        /// `usable` is the partition the camera records to; `card` is the whole card.
        case cardTooSmall(usable: Int64, card: Int64)
        /// `on` is the saved setting; `recordingNow` is what the camera is doing this minute.
        case ready(on: Bool, recordingNow: Bool)
        case failed(String)
    }

    private(set) var phase: Phase = .checking
    private(set) var busy = false
    private let client: ThinginoClient?

    init(client: ThinginoClient?) {
        self.client = client
    }

    var isOn: Bool {
        if case .ready(let on, _) = phase { return on }
        return false
    }

    func load() async {
        guard let client, client.apiKey != nil else { phase = .needsWebPassword; return }
        phase = .checking
        do {
            let card = try await client.card()
            guard card.present else { phase = .noCard; return }
            let settings = try await client.recorderSettings()
            let usable = ThinginoClient.recordingMount(settings).map(card.usableBytes) ?? card.sizeBytes
            guard usable >= ThinginoClient.smallestCardBytes else {
                phase = .cardTooSmall(usable: usable, card: card.sizeBytes)
                return
            }
            let recording = try await client.isRecording()
            phase = .ready(on: settings.autostart, recordingNow: recording)
        } catch {
            phase = Self.describe(error)
        }
    }

    func set(_ on: Bool) async {
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

    static func describe(_ error: Error) -> Phase {
        switch error {
        case ThinginoClient.Failure.wrongPassword:
            // Never retried: the sheet shows the web password field instead.
            return .needsWebPassword
        case ThinginoClient.RecorderFailure.refused(let reason):
            return .failed("The camera said: \(reason)")
        default:
            return .failed("Couldn't reach the camera.")
        }
    }
}
