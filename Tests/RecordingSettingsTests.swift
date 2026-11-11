import XCTest
@testable import CamFetti

final class RecorderParsingTests: XCTestCase {
    /// Trimmed from a real Wyze v3 on Thingino, 2026-11-09.
    let realSettings = Data(#"{"ok":true,"data":{"video":{"autostart":false,"channel":0,"check_interval":60,"cleanup_enabled":false,"device_path":"%hostname","duration":60,"filename":"%Y/%m/%d/%H-%M-%S","limit":15,"min_free_mb":500,"mount":""},"mounts":["/mnt/mmcblk0p1"]}}"#.utf8)

    func testParsesRecorderSettings() throws {
        let s = try XCTUnwrap(ThinginoClient.parseRecorderSettings(realSettings))
        XCTAssertFalse(s.autostart)
        XCTAssertEqual(s.mount, "")
        XCTAssertEqual(s.mounts, ["/mnt/mmcblk0p1"])
        XCTAssertEqual(s.filename, "%Y/%m/%d/%H-%M-%S")
        XCTAssertEqual(s.limitGB, 15)
    }

    func testParsesCard() throws {
        let card = try XCTUnwrap(ThinginoClient.parseCard(Data(#"{"ok":true,"data":{"has_sdcard":true,"device":{"name":"mmcblk0","size_bytes":127926272}}}"#.utf8)))
        XCTAssertEqual(card, .init(present: true, sizeBytes: 127_926_272))
        let none = try XCTUnwrap(ThinginoClient.parseCard(Data(#"{"ok":true,"data":{"has_sdcard":false,"device":null}}"#.utf8)))
        XCTAssertFalse(none.present)
    }

    /// The real Wyze: a 64 GB card whose only partition is 117 MB.
    func testBigCardWithSmallPartitionUsesThePartition() throws {
        let df = "Filesystem                Size      Used Available Use% Mounted on\n/dev/mmcblk0p1          117.2M     83.5M     33.7M  71% /mnt/mmcblk0p1\n"
        let json = #"{"ok":true,"data":{"has_sdcard":true,"device":{"size_bytes":62534975488},"reports":{"partitions_b64":"\#(Data(df.utf8).base64EncodedString())"}}}"#
        let card = try XCTUnwrap(ThinginoClient.parseCard(Data(json.utf8)))
        XCTAssertEqual(card.sizeBytes, 62_534_975_488)
        XCTAssertEqual(card.usableBytes(on: "/mnt/mmcblk0p1"), 122_893_107)
        XCTAssertLessThan(card.usableBytes(on: "/mnt/mmcblk0p1"), ThinginoClient.smallestCardBytes)
        XCTAssertEqual(ThinginoClient.bytes("58.2G"), 62_491_774_156)
    }

    func testTurningOnPicksTheCardAndSizesTheLimit() throws {
        let s = try XCTUnwrap(ThinginoClient.parseRecorderSettings(realSettings))
        let on = try XCTUnwrap(ThinginoClient.recordingOn(s, card: .init(present: true, sizeBytes: 128_000_000_000)))
        XCTAssertTrue(on.autostart)
        XCTAssertTrue(on.cleanupEnabled)
        XCTAssertEqual(on.mount, "/mnt/mmcblk0p1")
        XCTAssertEqual(on.limitGB, 107, "about 90% of a 128 GB card, not Thingino's fixed 15")
        XCTAssertEqual(on.filename, s.filename, "the camera's own file layout is kept")
    }

    func testTurningOnWithoutAMountedCardIsRefused() throws {
        var s = try XCTUnwrap(ThinginoClient.parseRecorderSettings(realSettings))
        s.mounts = []
        XCTAssertNil(ThinginoClient.recordingOn(s, card: .init(present: true, sizeBytes: 32_000_000_000)))
    }

    func testFormSendsEveryFieldEncoded() throws {
        var s = try XCTUnwrap(ThinginoClient.parseRecorderSettings(realSettings))
        s.mount = "/mnt/mmcblk0p1"
        let form = ThinginoClient.recorderForm(s)
        let items = Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(string: "?" + form)?.queryItems).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items.count, 11)
        XCTAssertEqual(items["form"], "video")
        XCTAssertEqual(items["vr_filename"], "%Y/%m/%d/%H-%M-%S", "percent signs survive the camera's urldecode")
        XCTAssertEqual(items["vr_device_path"], "%hostname")
        XCTAssertEqual(items["vr_mount"], "/mnt/mmcblk0p1")
        XCTAssertFalse(form.contains("/"), "slashes are encoded too")
    }

    func testSettingsAreLostOnlyWhileRecordingWithNoMount() throws {
        var s = try XCTUnwrap(ThinginoClient.parseRecorderSettings(realSettings))
        XCTAssertTrue(ThinginoClient.lostSettings(s, recording: true))
        XCTAssertFalse(ThinginoClient.lostSettings(s, recording: false), "never set up, so nothing to restore")
        s.mount = "/mnt/mmcblk0p1"
        XCTAssertFalse(ThinginoClient.lostSettings(s, recording: true), "turned off at boot on purpose")
    }

    func testCameraErrorsAreRead() {
        XCTAssertEqual(ThinginoClient.errorMessage(Data(#"{"error":{"code":422,"message":"Record mount cannot be empty."}}"#.utf8)),
                       "Record mount cannot be empty.")
        XCTAssertNil(ThinginoClient.errorMessage(Data(#"{"ok":true}"#.utf8)))
    }

    func testNotes() {
        XCTAssertTrue(CameraDetailsView.recordingNote(.cardTooSmall(usable: 122_000_000, card: 62_534_975_488)).text.contains("Format the card"))
        XCTAssertTrue(CameraDetailsView.recordingNote(.cardTooSmall(usable: 2_000_000_000, card: 2_000_000_000)).text.contains("4 GB or more"))
        XCTAssertTrue(CameraDetailsView.recordingNote(.ready(on: true, recordingNow: false)).isError)
        XCTAssertFalse(CameraDetailsView.canToggle(.noCard))
        XCTAssertTrue(CameraDetailsView.canToggle(.ready(on: false, recordingNow: false)))
    }
}

/// Turns recording on and off against the fake Thingino (rig/start.sh). Skipped when the rig is down.
final class RecorderRigTests: XCTestCase {
    let base = URL(string: "http://127.0.0.1:8080")!

    @MainActor
    func testSwitchRecordsAndSurvivesReboot() async throws {
        var probe = URLRequest(url: base, timeoutInterval: 4)
        probe.httpMethod = "GET"
        guard (try? await URLSession.shared.data(for: probe)) != nil else { throw XCTSkip("test rig not running") }
        let key = try await ThinginoClient(base: base).mintAPIKey(password: "root")
        let client = ThinginoClient(base: base, apiKey: key)
        let settings = RecordingSettings(client: client)

        await settings.load()
        XCTAssertEqual(settings.phase, .ready(on: false, recordingNow: false))

        await settings.set(true)
        XCTAssertEqual(settings.phase, .ready(on: true, recordingNow: true))
        let saved = try await client.recorderSettings()
        XCTAssertTrue(saved.autostart, "starts again after a reboot")
        XCTAssertTrue(saved.cleanupEnabled)
        XCTAssertEqual(saved.mount, "/mnt/mmcblk0p1")
        XCTAssertEqual(saved.limitGB, 26, "90% of the 29.7 GB partition")

        await settings.set(false)
        XCTAssertEqual(settings.phase, .ready(on: false, recordingNow: false))
        let off = try await client.recorderSettings()
        XCTAssertFalse(off.autostart)
    }

    @MainActor
    func testLostSettingsComeBackWhileRecording() async throws {
        var probe = URLRequest(url: base, timeoutInterval: 4)
        probe.httpMethod = "GET"
        guard (try? await URLSession.shared.data(for: probe)) != nil else { throw XCTSkip("test rig not running") }
        let key = try await ThinginoClient(base: base).mintAPIKey(password: "root")
        let client = ThinginoClient(base: base, apiKey: key)
        let settings = RecordingSettings(client: client)
        await settings.load()
        await settings.set(true)
        defer { Task { @MainActor in await settings.set(false) } }

        let lose = URL(string: "_lose_settings?token=\(key)", relativeTo: base)!.absoluteURL
        _ = try await URLSession.shared.data(from: lose)
        let lost = try await client.recorderSettings()
        XCTAssertEqual(lost.mount, "")

        await settings.load()
        XCTAssertEqual(settings.phase, .ready(on: true, recordingNow: true), "the switch still shows on")
        let saved = try await client.recorderSettings()
        XCTAssertTrue(saved.autostart)
        XCTAssertTrue(saved.cleanupEnabled)
        XCTAssertEqual(saved.mount, "/mnt/mmcblk0p1")
    }

    @MainActor
    func testNoKeyAsksForWebPassword() async {
        let settings = RecordingSettings(client: ThinginoClient(base: base))
        await settings.load()
        XCTAssertEqual(settings.phase, .needsWebPassword)
    }
}

/// Drives a real Thingino camera's recorder: saves the settings, records a few seconds, stops, and turns
/// start-at-boot back off. Skipped unless CAMFETTI_THINGINO holds base64 JSON {"host","pass"}.
/// Signs in once and never retries. Prints no secrets. Leaves the camera's mount and cleanup settings changed,
/// so restore /etc/prudynt.json afterwards if the camera should be exactly as before.
final class RealThinginoRecorderTests: XCTestCase {
    @MainActor
    func testRealRecorderStartsAndStops() async throws {
        guard let b64 = ProcessInfo.processInfo.environment["CAMFETTI_THINGINO"], let data = Data(base64Encoded: b64),
              let cfg = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let host = cfg["host"], let pass = cfg["pass"], let base = URL(string: "http://\(host)") else {
            throw XCTSkip("no Thingino configured")
        }
        let key = try await ThinginoClient(base: base).mintAPIKey(password: pass)
        let client = ThinginoClient(base: base, apiKey: key)

        let screen = RecordingSettings(client: client)
        await screen.load()
        print("THINGINO phase=\(screen.phase)")

        let card = try await client.card()
        XCTAssertTrue(card.present)
        let original = try await client.recorderSettings()
        // Use a 1 GB cap whatever the card, since this only records a few seconds.
        var next = try XCTUnwrap(ThinginoClient.recordingOn(original, card: .init(present: true, sizeBytes: 1_200_000_000)))
        next.limitGB = 1
        try await client.saveRecorder(next)
        let saved = try await client.recorderSettings()
        XCTAssertTrue(saved.autostart)
        XCTAssertEqual(saved.mount, next.mount)
        XCTAssertEqual(saved.filename, original.filename, "the percent signs survived the camera's form decoding")
        XCTAssertEqual(saved.devicePath, original.devicePath)

        try await client.startRecording()
        try await Task.sleep(for: .seconds(6))
        let recording = try await client.isRecording()
        XCTAssertTrue(recording)
        try await client.stopRecording()
        let after = try await client.isRecording()
        XCTAssertFalse(after)

        var off = try await client.recorderSettings()
        off.autostart = false
        try await client.saveRecorder(off)
        let final = try await client.recorderSettings()
        XCTAssertFalse(final.autostart)
        print("THINGINO card=\(card.sizeBytes) mount=\(saved.mount) ok")
    }
}
