import Foundation
import Observation

/// The person's camera list, saved as JSON in Application Support.
@MainActor @Observable
final class CameraStore {
    private(set) var cameras: [Camera] = []
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("cameras.json")
        }
        load()
    }

    func add(_ camera: Camera, password: String?, apiKey: String? = nil) {
        let secrets = CameraSecrets(id: camera.id)
        secrets.password = password
        if let apiKey { secrets.apiKey = apiKey }
        if let i = cameras.firstIndex(where: { $0.id == camera.id }) {
            cameras[i] = camera
        } else {
            cameras.append(camera)
        }
        save()
    }

    func update(_ camera: Camera) {
        guard let i = cameras.firstIndex(where: { $0.id == camera.id }) else { return }
        cameras[i] = camera
        save()
    }

    func remove(_ camera: Camera) {
        CameraSecrets(id: camera.id).removeAll()
        Thumbnails.remove(camera.id)
        cameras.removeAll { $0.id == camera.id }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        cameras.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func move(_ camera: Camera, by offset: Int) {
        guard let i = cameras.firstIndex(of: camera) else { return }
        let j = max(0, min(cameras.count - 1, i + offset))
        guard i != j else { return }
        cameras.swapAt(i, j)
        save()
    }

    /// True when a camera with this host is already added.
    func contains(host: String) -> Bool {
        cameras.contains { $0.host.caseInsensitiveCompare(host) == .orderedSame }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        cameras = (try? JSONDecoder().decode([Camera].self, from: data)) ?? []
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(cameras) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Last frame per camera, kept on disk so tiles never start as a black box.
enum Thumbnails {
    static var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func url(_ id: UUID) -> URL { dir.appendingPathComponent("\(id).jpg") }
    static func load(_ id: UUID) -> Data? { try? Data(contentsOf: url(id)) }
    static func save(_ data: Data, for id: UUID) { try? data.write(to: url(id), options: .atomic) }
    static func remove(_ id: UUID) { try? FileManager.default.removeItem(at: url(id)) }
}
