import AVFoundation
import Foundation
import Network
import Observation
import Photos

/// App-wide state: the camera list, the grid's streams, and network status.
@MainActor @Observable
final class AppModel {
    let store: CameraStore
    /// Camera open full screen. Grid streams pause while it is set.
    var focused: Camera?
    /// Camera whose details sheet is open.
    var editing: Camera?
    private(set) var isOnline = true
    /// Fires once, when the very first camera goes live.
    var celebrate = false

    private var gridStreams: [UUID: LiveStream] = [:]
    private let monitor = NWPathMonitor()

    init(store: CameraStore = CameraStore()) {
        self.store = store
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    static func configureAudioSession() {
        // Mixes with other audio, so a silent grid never stops the person's music.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func gridStream(for camera: Camera) -> LiveStream {
        if let existing = gridStreams[camera.id] { return existing }
        let stream = makeStream(camera, url: camera.gridURL)
        gridStreams[camera.id] = stream
        return stream
    }

    func mainStream(for camera: Camera) -> LiveStream {
        makeStream(camera, url: camera.mainURL, thumbnail: gridStreams[camera.id]?.thumbnail)
    }

    func makeStream(_ camera: Camera, url: String, thumbnail: Data? = nil) -> LiveStream {
        let id = camera.id
        return LiveStream(urls: Self.addresses(for: camera, url: url), username: camera.username,
                          password: CameraSecrets(id: id).password,
                          thumbnail: thumbnail ?? Thumbnails.load(id),
                          thumbnailSink: { Thumbnails.save($0, for: id) })
    }

    /// Home address first, away address second.
    nonisolated static func addresses(for camera: Camera, url: String) -> [String] {
        var urls = [url]
        if let away = camera.awayHost?.trimmingCharacters(in: .whitespaces), !away.isEmpty {
            urls.append(Camera.replacingHost(in: url, with: away))
        }
        return urls
    }

    func stopGridStream(_ camera: Camera) {
        gridStreams[camera.id]?.stop()
    }

    /// Drop a stream so the next appearance uses new settings.
    func resetStream(_ camera: Camera) {
        gridStreams[camera.id]?.stop()
        gridStreams[camera.id] = nil
    }

    func stopAll() {
        gridStreams.values.forEach { $0.stop() }
    }

    func remove(_ camera: Camera) {
        resetStream(camera)
        store.remove(camera)
    }

    func thinginoClient(for camera: Camera, host: String? = nil) -> ThinginoClient? {
        guard camera.kind == .thingino, let base = camera.webBase(host: host) else { return nil }
        return ThinginoClient(base: base, apiKey: CameraSecrets(id: camera.id).apiKey)
    }

    func onvifClient(for camera: Camera) -> OnvifClient? {
        guard let onvif = camera.onvif else { return nil }
        return OnvifClient(deviceURL: onvif.deviceURL, username: camera.username,
                           password: CameraSecrets(id: camera.id).password ?? "")
    }

    enum SaveResult { case saved, denied, failed }

    func save(jpeg: Data) async -> SaveResult {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .denied }
        do {
            try await PHPhotoLibrary.shared().performChanges(Self.addPhotoChange(jpeg))
            return .saved
        } catch {
            return .failed
        }
    }

    /// Photos runs change blocks on its own background queue. Built outside the main actor so
    /// Swift does not mark the block main-actor-only, which crashed the app on 2026-10-31.
    nonisolated private static func addPhotoChange(_ jpeg: Data) -> @Sendable () -> Void {
        { PHAssetCreationRequest.forAsset().addResource(with: .photo, data: jpeg, options: nil) }
    }
}
