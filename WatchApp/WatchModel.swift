import Foundation
import Observation
import UIKit

/// The camera list on the watch: what is cached, and what the iPhone last said.
@MainActor @Observable
final class WatchModel {
    enum Link: Equatable { case unknown, connected, notNearby }

    private(set) var cameras: [WatchProtocol.CameraSummary]
    private(set) var link: Link = .unknown
    /// True once the iPhone has answered, so an empty list means "no cameras" and not "not asked yet".
    private(set) var heardFromPhone = false
    private let session: WatchSession

    init(session: WatchSession = .shared) {
        self.session = session
        cameras = WatchCache.loadCameras() ?? []
    }

    /// Asks for the list and the small thumbnails, and keeps asking while the phone can't be
    /// reached, so walking back into range fixes it without reopening the app. Never fetches a camera.
    func refresh() async {
        while !Task.isCancelled {
            do {
                let fresh = try await session.cameras()
                cameras = fresh
                heardFromPhone = true
                link = .connected
                WatchCache.save(cameras: fresh)
                cameras = WatchCache.loadCameras() ?? fresh
                return
            } catch {
                link = .notNearby
                try? await Task.sleep(for: .seconds(Theme.Timing.snapshotRetry))
            }
        }
    }

}

/// One camera's picture: the cached one at once, then a fresh one every couple of seconds.
@MainActor @Observable
final class SnapshotLoader {
    enum Status: Equatable { case loading, fresh, notNearby, cantReach }

    let camera: WatchProtocol.CameraSummary
    private(set) var image: UIImage?
    private(set) var imageDate: Date?
    private(set) var status: Status = .loading
    /// A fresh picture has landed during this visit.
    private(set) var hasFresh = false
    private let session: WatchSession

    init(camera: WatchProtocol.CameraSummary, session: WatchSession = .shared) {
        self.camera = camera
        self.session = session
        if let cached = WatchCache.loadImage(camera.id) {
            image = UIImage(data: cached.data)
            imageDate = cached.date
        } else if let thumbnail = camera.thumbnail {
            image = UIImage(data: thumbnail)
        }
    }

    /// Runs until cancelled. The view cancels it when the scene leaves the active phase.
    func run() async {
        while !Task.isCancelled {
            let ok = await fetchOnce()
            let pause = ok ? Theme.Timing.snapshotRefresh : Theme.Timing.snapshotRetry
            try? await Task.sleep(for: .seconds(pause))
        }
    }

    @discardableResult
    func fetchOnce() async -> Bool {
        do {
            let data = try await session.snapshot(id: camera.id)
            guard !Task.isCancelled, let decoded = UIImage(data: data) else { return false }
            WatchCache.saveImage(data, id: camera.id)
            image = decoded
            imageDate = Date()
            hasFresh = true
            status = .fresh
            return true
        } catch WatchSession.Failure.notNearby {
            if !Task.isCancelled { status = .notNearby }
        } catch {
            if !Task.isCancelled { status = .cantReach }
        }
        return false
    }

    var isError: Bool { status == .notNearby || status == .cantReach }

    var message: String? {
        switch status {
        case .notNearby: "iPhone not nearby"
        case .cantReach: "Can't reach \(camera.name)"
        default: nil
        }
    }
}
