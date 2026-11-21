import XCTest
@testable import CamFetti

/// Replies trimmed from Lacy's cameras, 2026-11-20: an RLC-410 on 2020 firmware (GetRec only) and an RLC-510A (GetRecV20).
final class ReolinkRecorderTests: XCTestCase {
    static let ones = String(repeating: "1", count: 168)
    static let zeros = String(repeating: "0", count: 168)
    let legacy = Data(#"[{"cmd":"GetRec","code":0,"value":{"Rec":{"channel":0,"overwrite":1,"postRec":"15 Seconds","preRec":1,"schedule":{"enable":1,"table":"\#(ones)"}}}}]"#.utf8)
    let v20 = Data(#"[{"cmd":"GetRecV20","code":0,"value":{"Rec":{"enable":1,"overwrite":1,"postRec":"15 Seconds","preRec":1,"schedule":{"channel":0,"table":{"AI_PEOPLE":"\#(ones)","AI_VEHICLE":"\#(ones)","MD":"\#(ones)","TIMING":"\#(zeros)"}}}}}]"#.utf8)
    let unsupported = Data(#"[{"cmd":"Unknown","code":1,"error":{"detail":"not support","rspCode":-9}}]"#.utf8)

    func testLegacyOnlyTurnsOnAndOff() throws {
        XCTAssertNil(ReolinkClient.parseRecord(unsupported, v20: true))
        let c = try XCTUnwrap(ReolinkClient.parseRecord(legacy, v20: false))
        XCTAssertTrue(c.enabled)
        XCTAssertEqual(c.modes, [])
        XCTAssertNil(c.mode)
        var off = c
        off.enabled = false
        let body = try XCTUnwrap(ReolinkClient.recordBody(off))
        XCTAssertEqual((body["schedule"] as? [String: Any])?["enable"] as? Int, 0)
        XCTAssertEqual((body["schedule"] as? [String: Any])?["table"] as? String, Self.ones, "keeps the schedule for next time")
        XCTAssertEqual(body["postRec"] as? String, "15 Seconds", "sends back what it doesn't own")
        XCTAssertNil(body["enable"], "legacy has no top-level enable")
    }

    func testV20ReadsMotionWithPeopleAndVehicles() throws {
        let c = try XCTUnwrap(ReolinkClient.parseRecord(v20, v20: true))
        XCTAssertEqual(c.modes, [.nonstop, .motion, .smart])
        XCTAssertEqual(c.mode, .motion)
        XCTAssertEqual(c.aiTriggers, ["AI_PEOPLE", "AI_VEHICLE"])
        XCTAssertEqual(CameraDetailsView.modeName(.smart, ai: c.aiTriggers), "People and Vehicles")
    }

    func testModesWriteTheTables() throws {
        var c = try XCTUnwrap(ReolinkClient.parseRecord(v20, v20: true))
        c.apply(.nonstop)
        XCTAssertEqual(c.mode, .nonstop)
        XCTAssertEqual(c.tables["MD"], Self.ones, "nonstop still marks motion for playback")
        c.apply(.smart)
        XCTAssertEqual(c.mode, .smart)
        XCTAssertEqual(c.tables["MD"], Self.zeros)
        XCTAssertEqual(c.tables["TIMING"], Self.zeros)
        let body = try XCTUnwrap(ReolinkClient.recordBody(c))
        let table = try XCTUnwrap((body["schedule"] as? [String: Any])?["table"] as? [String: Any])
        XCTAssertEqual(table["AI_PEOPLE"] as? String, Self.ones)
        XCTAssertEqual(body["enable"] as? Int, 1)
    }

    func testAScheduleFromReolinksAppIsCustomAndLeftAlone() throws {
        var c = try XCTUnwrap(ReolinkClient.parseRecord(v20, v20: true))
        c.tables["MD"] = String(repeating: "0", count: 84) + String(repeating: "1", count: 84)
        XCTAssertNil(c.mode)
        c.turnOn()
        XCTAssertEqual(c.tables["MD"]?.filter { $0 == "1" }.count, 84, "turning on doesn't flatten someone's schedule")
    }

    func testTurningOnAnEmptyScheduleRecordsMotionAndOverwrites() throws {
        var c = try XCTUnwrap(ReolinkClient.parseRecord(v20, v20: true))
        for key in c.tables.keys { c.tables[key] = Self.zeros }
        c.enabled = false
        c.overwrite = false
        XCTAssertTrue(c.recordsNothing)
        c.turnOn()
        XCTAssertEqual(c.mode, .motion)
        XCTAssertTrue(c.overwrite)
        var old = try XCTUnwrap(ReolinkClient.parseRecord(legacy, v20: false))
        old.tables["MD"] = Self.zeros
        old.turnOn()
        XCTAssertEqual(old.tables["MD"], Self.ones)
    }

    func testCardSize() throws {
        let card = Data(#"[{"cmd":"GetHddInfo","code":0,"value":{"HddInfo":[{"capacity":30524,"format":1,"mount":1,"number":0,"size":400,"storageType":2}]}}]"#.utf8)
        XCTAssertEqual(try ReolinkClient.parseCardBytes(card), 30524 * 1_048_576)
        XCTAssertNil(try ReolinkClient.parseCardBytes(Data(#"[{"cmd":"GetHddInfo","code":0,"value":{"HddInfo":[]}}]"#.utf8)))
    }

    @MainActor
    func testRefusedChangeSaysWhatToDo() {
        guard case .failed(let text) = RecordingSettings.describe(ReolinkClient.Failure.notAllowed) else { return XCTFail() }
        XCTAssertTrue(text.contains("Reolink app"))
        XCTAssertEqual(CameraDetailsView.cardSize(30524 * 1_048_576), "32 GB")
    }

    func testNotes() {
        let card: Int64 = 30524 * 1_048_576
        let on = RecordingSettings.Phase.ready(on: true, recordingNow: true)
        XCTAssertTrue(CameraDetailsView.reolinkNote(on, mode: .smart, hasModes: true, card: card, ai: ["AI_PEOPLE", "AI_VEHICLE"]).text
            .contains("sees people and vehicles"))
        XCTAssertTrue(CameraDetailsView.reolinkNote(on, mode: nil, hasModes: true, card: card, ai: []).text.contains("Reolink's app"))
        XCTAssertTrue(CameraDetailsView.reolinkNote(on, mode: nil, hasModes: false, card: card, ai: []).text.contains("when something moves"))
        XCTAssertTrue(CameraDetailsView.reolinkNote(.wrongPassword, mode: nil, hasModes: false, card: nil, ai: []).isError)
        XCTAssertFalse(CameraDetailsView.reolinkNote(.ready(on: false, recordingNow: false), mode: nil, hasModes: true, card: card, ai: []).text.contains("—"))
    }
}
