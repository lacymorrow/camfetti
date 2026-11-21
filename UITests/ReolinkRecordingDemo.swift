import XCTest

/// Walks the Reolink recording controls on the rig's fake Reolinks (rig/start.sh) and saves a screenshot of
/// each state. Skipped unless TEST_RUNNER_CAMFETTI_REOLINK names an output folder.
final class ReolinkRecordingDemo: XCTestCase {
    @MainActor
    func testReolinkRecording() throws {
        guard let out = ProcessInfo.processInfo.environment["CAMFETTI_REOLINK"] else { throw XCTSkip("no output folder") }
        let app = XCUIApplication()
        app.launchArguments = ["-resetForTesting", "-seedDemo", "127.0.0.1", "-reolinkRig"]
        app.launch()

        // Newer firmware: off, on (motion), then People and Vehicles.
        let note = openDetails(app, "Driveway")
        wait(note, "label BEGINSWITH 'Turn on'")
        save(out, "1-off")
        app.switches["recordToggle"].firstMatch.switches.firstMatch.tap()
        wait(note, "label CONTAINS 'when anything moves'")
        save(out, "2-on-motion")
        app.buttons["recordMode"].firstMatch.tap()
        app.buttons["People and Vehicles"].firstMatch.tap()
        wait(note, "label CONTAINS 'sees people and vehicles'")
        save(out, "3-people-and-vehicles")
        app.buttons["Cancel"].firstMatch.tap()

        // 2020 firmware: just the switch.
        let old = openDetails(app, "Back Yard")
        wait(old, "label BEGINSWITH 'Turn on'")
        app.switches["recordToggle"].firstMatch.switches.firstMatch.tap()
        wait(old, "label CONTAINS 'when something moves'")
        XCTAssertFalse(app.buttons["recordMode"].exists, "2020 firmware has no modes")
        save(out, "4-older-firmware-on")
        app.buttons["Cancel"].firstMatch.tap()

        // 2020 firmware that won't let this account change it: the switch stays on and says what to do.
        let locked = openDetails(app, "Garage")
        wait(locked, "label CONTAINS 'when something moves'")
        app.switches["recordToggle"].firstMatch.switches.firstMatch.tap()
        wait(locked, "label CONTAINS 'Reolink app'")
        XCTAssertEqual(app.switches["recordToggle"].firstMatch.value as? String, "1", "still shows what the camera does")
        save(out, "5-refused")
        app.buttons["Cancel"].firstMatch.tap()

        // No card: the switch is off and disabled.
        let empty = openDetails(app, "Front Porch")
        wait(empty, "label CONTAINS 'microSD'")
        save(out, "6-no-card")
    }

    @MainActor
    private func openDetails(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let tile = app.descendants(matching: .any)["tile-\(name)"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 30))
        tile.press(forDuration: 1.2)
        app.buttons["Details"].firstMatch.tap()
        let toggle = app.switches["recordToggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        return app.staticTexts["recordNote"]
    }

    @MainActor
    private func wait(_ element: XCUIElement, _ format: String) {
        expectation(for: NSPredicate(format: format), evaluatedWith: element)
        waitForExpectations(timeout: 20)
    }

    @MainActor
    private func save(_ folder: String, _ name: String) {
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
