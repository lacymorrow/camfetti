import AVFoundation
import XCTest
@testable import CamFetti

final class ThinginoPlaybackTests: XCTestCase {
    let tz = TimeZone(identifier: "America/New_York")!

    private func entry(_ name: String, size: Int = 2_662_590, dir: Bool = false) -> ThinginoClient.Entry {
        .init(name: name, path: "/mnt/mmcblk0p1/cam-e/2026/11/09/\(name)", size: size, isDirectory: dir)
    }

    private func day() -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = tz
        return c.date(from: DateComponents(year: 2026, month: 11, day: 9))!
    }

    /// Trimmed from the real Wyze's file manager, 2026-11-09.
    func testParsesFileManagerListing() throws {
        let json = #"{"directory":"/mnt/mmcblk0p1/cam-e/2026/11/09","parent":"/mnt/mmcblk0p1/cam-e/2026/11","breadcrumbs":[],"entries":[{"name":"14-05-54.mp4","path":"/mnt/mmcblk0p1/cam-e/2026/11/09/14-05-54.mp4","size":"2662590","perm":"-rwxrwxrwx","time":"Nov 9 14:06","is_dir":false,"is_link":false,"link_target":"","deletable":true},{"name":"2026","path":"/mnt/mmcblk0p1/cam-e/2026","size":"-","perm":"drwxrwxrwx","time":"Nov 9 14:05","is_dir":true,"is_link":false,"link_target":"","deletable":true}]}"#
        let entries = try XCTUnwrap(ThinginoClient.parseEntries(Data(json.utf8)))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].size, 2_662_590)
        XCTAssertFalse(entries[0].isDirectory)
        XCTAssertTrue(entries[1].isDirectory)
        XCTAssertEqual(entries[1].size, 0)
    }

    func testClipsEndAtTheNextClipAndSkipTheOneBeingWritten() {
        let entries = [entry("14-06-54.mp4"), entry("14-05-54.mp4"), entry("14-07-54.mp4"), entry("notes.txt"), entry("14-08-00.mp4", size: 0)]
        let now = day().addingTimeInterval(14 * 3600 + 8 * 60 + 10) // 14:08:10, the 14:07:54 clip is still recording
        let clips = ThinginoRecordings.clips(entries, day: day(), clipSeconds: 60, now: now, timeZone: tz)
        XCTAssertEqual(clips.map { ($0.name as NSString).lastPathComponent }, ["14-05-54.mp4", "14-06-54.mp4"])
        XCTAssertEqual(clips[0].duration, 60)
        XCTAssertEqual(clips[1].name, "/mnt/mmcblk0p1/cam-e/2026/11/09/14-06-54.mp4", "the full path is what plays")
    }

    func testLastClipShowsOnceTheCameraStoppedRecording() {
        let later = day().addingTimeInterval(20 * 3600)
        let clips = ThinginoRecordings.clips([entry("14-05-54.mp4")], day: day(), clipSeconds: 60, now: later, timeZone: tz)
        XCTAssertEqual(clips.count, 1)
    }

    func testPlayURLCarriesKeyAndEncodedPath() throws {
        let client = ThinginoClient(base: URL(string: "http://192.168.1.163")!, apiKey: "abc123")
        let url = try XCTUnwrap(client.playURL(path: "/mnt/mmcblk0p1/cam e/14-05-54.mp4"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(url.path, "/x/tool-file-manager.cgi")
        XCTAssertEqual(items.first { $0.name == "play" }?.value, "/mnt/mmcblk0p1/cam e/14-05-54.mp4")
        XCTAssertEqual(items.first { $0.name == "token" }?.value, "abc123")
    }

    func testFolderNames() {
        XCTAssertTrue(ThinginoRecordings.isNumber("2026", digits: 4))
        XCTAssertFalse(ThinginoRecordings.isNumber("cam-e", digits: 4))
        XCTAssertFalse(ThinginoRecordings.isNumber("١٢", digits: 2), "only ASCII digits")
    }
}

/// Reads the fake Thingino's card (rig/start.sh). Skipped when the rig is down.
final class ThinginoPlaybackRigTests: XCTestCase {
    let base = URL(string: "http://127.0.0.1:8080")!

    func testFindsDaysAndStreamsAClip() async throws {
        var probe = URLRequest(url: base, timeoutInterval: 4)
        probe.httpMethod = "GET"
        guard (try? await URLSession.shared.data(for: probe)) != nil else { throw XCTSkip("test rig not running") }
        let key = try await ThinginoClient(base: base).mintAPIKey(password: "root")
        let client = ThinginoClient(base: base, apiKey: key)
        let settings = try await client.recorderSettings()
        if settings.mount.isEmpty {
            let card = try await client.card()
            try await client.saveRecorder(try XCTUnwrap(ThinginoClient.recordingOn(settings, card: card)))
        }
        let saved = try await client.recorderSettings()

        let root = try await ThinginoRecordings.findRoot(client: client, mount: saved.mount, devicePath: saved.devicePath)
        XCTAssertEqual(root, "/mnt/mmcblk0p1/cam-rig", "found the folder with year folders, skipping files")
        let recordings = ThinginoRecordings(client: client, root: try XCTUnwrap(root), clipSeconds: saved.duration)
        let days = try await recordings.days(from: Date().addingTimeInterval(-90 * 86400))
        XCTAssertEqual(days.count, 2)
        XCTAssertGreaterThan(days[0], days[1], "newest first")

        let yesterday = try await recordings.clips(on: days[1])
        let clip = try XCTUnwrap(yesterday.first)
        XCTAssertTrue(clip.name.hasSuffix("/21-05-00.mp4"))

        let file = try await recordings.media(for: clip)
        XCTAssertTrue(file.isFileURL, "Thingino clips play from a local copy, because the camera ignores Range")
        let duration = try await AVURLAsset(url: file).load(.duration)
        XCTAssertEqual(duration.seconds, 5, accuracy: 0.5)
        await recordings.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "copies are removed when playback closes")
    }
}
