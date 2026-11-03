import Foundation

/// The messages between the iPhone app and the watch app. Shared by both targets, so it uses
/// Foundation only. Camera passwords are never part of any message.
enum WatchProtocol {
    enum Key {
        static let request = "request"
        static let cameraID = "id"
        static let cameras = "cameras"
        static let name = "name"
        static let thumbnail = "thumb"
        static let jpeg = "jpeg"
        static let error = "error"
    }

    enum Request {
        static let cameras = "cameras"
        static let snapshot = "snapshot"
    }

    /// Why the iPhone could not answer. "Not nearby" is decided on the watch, not sent.
    enum Failure: String, Error {
        /// The camera did not give a picture.
        case camera
        /// The phone did not understand the request.
        case badRequest
    }

    struct CameraSummary: Equatable, Hashable, Sendable, Identifiable {
        let id: String
        var name: String
        var thumbnail: Data?
    }

    static func cameraListRequest() -> [String: Any] {
        [Key.request: Request.cameras]
    }

    static func snapshotRequest(id: String) -> [String: Any] {
        [Key.request: Request.snapshot, Key.cameraID: id]
    }

    static func encode(cameras: [CameraSummary]) -> [String: Any] {
        let rows: [[String: Any]] = cameras.map { camera in
            var row: [String: Any] = [Key.cameraID: camera.id, Key.name: camera.name]
            if let thumbnail = camera.thumbnail { row[Key.thumbnail] = thumbnail }
            return row
        }
        return [Key.cameras: rows]
    }

    static func decodeCameras(_ reply: [String: Any]) -> [CameraSummary]? {
        guard let rows = reply[Key.cameras] as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let id = row[Key.cameraID] as? String, let name = row[Key.name] as? String else { return nil }
            return CameraSummary(id: id, name: name, thumbnail: row[Key.thumbnail] as? Data)
        }
    }

    static func encode(snapshot: Data) -> [String: Any] { [Key.jpeg: snapshot] }
    static func encode(failure: Failure) -> [String: Any] { [Key.error: failure.rawValue] }
    static func decodeSnapshot(_ reply: [String: Any]) -> Data? { reply[Key.jpeg] as? Data }
}
