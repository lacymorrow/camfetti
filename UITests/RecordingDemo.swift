import XCTest

/// Opens a camera's Details and saves screenshots of the Recording switch. Skipped unless
/// TEST_RUNNER_CAMFETTI_SEED holds a `-seedReal` value and TEST_RUNNER_CAMFETTI_OUT names a folder.
/// TEST_RUNNER_CAMFETTI_TOGGLE=1 also flips the switch on, then off again (use it on the rig only).
final class RecordingDemo: XCTestCase {
    @MainActor
    func testRecordingSwitch() throws {
        let env = ProcessInfo.processInfo.environment
        guard let seed = env["CAMFETTI_SEED"], let out = env["CAMFETTI_OUT"] else { throw XCTSkip("no seed") }
        let name = env["CAMFETTI_CAMERA"] ?? "Library"
        let app = XCUIApplication()
        app.launchArguments = ["-resetForTesting", "-seedReal", seed]
        app.launch()

        let tile = app.descendants(matching: .any)["tile-\(name)"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 30))
        sleep(3)
        tile.press(forDuration: 1.2)
        app.buttons["Details"].firstMatch.tap()

        let toggle = app.switches["recordToggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let note = app.staticTexts["recordNote"]
        let settled = NSPredicate(format: "label != 'Checking the SD card.'")
        expectation(for: settled, evaluatedWith: note)
        waitForExpectations(timeout: 20)
        app.swipeUp()
        save(app, out, "recording-0-\(name)")

        guard env["CAMFETTI_TOGGLE"] == "1" else { return }
        toggle.switches.firstMatch.tap()
        expectation(for: NSPredicate(format: "label BEGINSWITH 'Recording now'"), evaluatedWith: note)
        waitForExpectations(timeout: 20)
        save(app, out, "recording-1-on")
        toggle.switches.firstMatch.tap()
        expectation(for: NSPredicate(format: "label BEGINSWITH 'Records nonstop'"), evaluatedWith: note)
        waitForExpectations(timeout: 20)
    }

    @MainActor
    private func save(_ app: XCUIApplication, _ folder: String, _ name: String) {
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
