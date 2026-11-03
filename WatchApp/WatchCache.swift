import Foundation

/// What the watch keeps on its own storage: the camera list, one small thumbnail per camera and
/// the last full picture. No passwords, ever.
enum WatchCache {
    private static var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("camfetti", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static var listURL: URL { dir.appendingPathComponent("cameras.json") }
    private static func thumbURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).thumb.jpg") }
    private static func imageURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).jpg") }

    private struct Row: Codable { let id: String; let name: String }

    static func loadCameras() -> [WatchProtocol.CameraSummary]? {
        guard let data = try? Data(contentsOf: listURL), let rows = try? JSONDecoder().decode([Row].self, from: data) else { return nil }
        return rows.map { WatchProtocol.CameraSummary(id: $0.id, name: $0.name, thumbnail: loadImage($0.id)?.data ?? (try? Data(contentsOf: thumbURL($0.id)))) }
    }

    static func save(cameras: [WatchProtocol.CameraSummary]) {
        let keep = Set(cameras.map(\.id))
        if let old = loadCameras() {
            for gone in old where !keep.contains(gone.id) {
                try? FileManager.default.removeItem(at: thumbURL(gone.id))
                try? FileManager.default.removeItem(at: imageURL(gone.id))
            }
        }
        try? JSONEncoder().encode(cameras.map { Row(id: $0.id, name: $0.name) }).write(to: listURL, options: .atomic)
        for camera in cameras {
            if let thumb = camera.thumbnail { try? thumb.write(to: thumbURL(camera.id), options: .atomic) }
        }
    }

    /// The last full picture and when it was saved.
    static func loadImage(_ id: String) -> (data: Data, date: Date)? {
        guard let data = try? Data(contentsOf: imageURL(id)) else { return nil }
        let date = (try? FileManager.default.attributesOfItem(atPath: imageURL(id).path)[.modificationDate] as? Date) ?? Date()
        return (data, date)
    }

    static func saveImage(_ data: Data, id: String) {
        try? data.write(to: imageURL(id), options: .atomic)
    }
}
