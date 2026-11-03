#if os(iOS)
import Foundation
import UIKit
import WatchConnectivity

/// The iPhone end of the watch app. A message from the watch launches CamFetti in the
/// background, so everything here works with no window: it reads its own camera list from disk,
/// fetches the picture, shrinks it and replies. Passwords stay in the Keychain on this phone.
final class WatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchLink()

    /// Call once, as early as launch allows. A background launch needs the delegate set before
    /// the first message arrives.
    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let reply = ReplyBox(replyHandler)
        let request = message[WatchProtocol.Key.request] as? String
        let id = message[WatchProtocol.Key.cameraID] as? String
        Task { @MainActor in
            // Keep the app running until the reply goes out, even if the phone is locked.
            var background = UIBackgroundTaskIdentifier.invalid
            background = UIApplication.shared.beginBackgroundTask(withName: "watch-request") {
                UIApplication.shared.endBackgroundTask(background)
            }
            let answer = await Self.answer(request: request, id: id)
            reply.send(answer)
            UIApplication.shared.endBackgroundTask(background)
        }
    }

    // MARK: Answers

    @MainActor
    static func answer(request: String?, id: String?, store: CameraStore = CameraStore(),
                       fetcher: SnapshotFetcher = .shared) async -> [String: Any] {
        switch request {
        case WatchProtocol.Request.cameras:
            let rows = store.cameras.map { camera in
                WatchProtocol.CameraSummary(id: camera.id.uuidString, name: camera.name,
                                            thumbnail: Thumbnails.load(camera.id).flatMap(SnapshotEncoder.thumbnail(from:)))
            }
            return WatchProtocol.encode(cameras: rows)
        case WatchProtocol.Request.snapshot:
            guard let id, let uuid = UUID(uuidString: id), let camera = store.cameras.first(where: { $0.id == uuid }) else {
                return WatchProtocol.encode(failure: .badRequest)
            }
            guard let raw = await fetcher.jpeg(for: camera), let small = SnapshotEncoder.snapshot(from: raw) else {
                return WatchProtocol.encode(failure: .camera)
            }
            return WatchProtocol.encode(snapshot: small)
        default:
            return WatchProtocol.encode(failure: .badRequest)
        }
    }
}

/// WatchConnectivity hands over a reply closure that is not Sendable. It is safe to call from any thread.
private struct ReplyBox: @unchecked Sendable {
    let handler: ([String: Any]) -> Void
    init(_ handler: @escaping ([String: Any]) -> Void) { self.handler = handler }
    func send(_ reply: [String: Any]) { handler(reply) }
}
#endif
