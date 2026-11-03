import AVFoundation
import Foundation
import Network
import Observation
#if os(iOS) || os(visionOS)
import Photos
#elseif os(macOS)
import AppKit
#endif

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
        #if os(iOS) || os(visionOS)
        // Mixes with other audio, so a silent grid never stops the person's music.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
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

    /// Home address first, away address second. With Away routing on, only the relay tunnel.
    nonisolated static func addresses(for camera: Camera, url: String) -> [String] {
        #if AWAY
        if AwayConfig.routeThroughRelay, let tunneled = AwayTunnel.shared.localURL(for: url) {
            return [tunneled]
        }
        #endif
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

    /// Drop every stream so the next appearance picks up a routing change.
    func resetAllStreams() {
        stopAll()
        gridStreams.removeAll()
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

    #if os(iOS) || os(visionOS)
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
    #elseif os(macOS)
    /// On the Mac a snapshot goes where the person says, through the standard save panel.
    func save(jpeg: Data) async -> SaveResult {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = "CamFetti Snapshot.jpg"
        guard panel.runModal() == .OK, let url = panel.url else { return .denied }
        return (try? jpeg.write(to: url)) != nil ? .saved : .failed
    }
    #else
    /// Apple TV has nowhere to put a snapshot, and the button is hidden there.
    func save(jpeg: Data) async -> SaveResult { .failed }
    #endif
}
