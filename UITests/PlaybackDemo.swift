import XCTest

/// Opens a real camera's SD card recordings and saves screenshots. Skipped unless
/// TEST_RUNNER_CAMFETTI_SEED holds the `-seedReal` value (from scripts/shots-seed.py) and
/// TEST_RUNNER_CAMFETTI_OUT names a folder for the PNGs. Prints no secrets.
final class PlaybackDemo: XCTestCase {
    @MainActor
    func testPlaybackOnRealCamera() throws {
        let env = ProcessInfo.processInfo.environment
        guard let seed = env["CAMFETTI_SEED"], let out = env["CAMFETTI_OUT"] else { throw XCTSkip("no real camera seed") }
        let name = env["CAMFETTI_CAMERA"] ?? "Front of House"
        let app = XCUIApplication()
        app.launchArguments = ["-resetForTesting", "-seedReal", seed]
        app.launch()

        let tile = app.descendants(matching: .any)["tile-\(name)"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 30))
        sleep(4)
        tile.tap()
        let recordings = app.buttons["recordingsButton"]
        // Controls fade on a timer and a tap toggles them, so tap the button the moment it shows.
        for _ in 0..<6 {
            if recordings.waitForExistence(timeout: 2), recordings.isHittable {
                save(app, out, "playback-0-live")
                recordings.tap()
                break
            }
            if tile.exists, tile.isHittable { tile.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        }

        if env["CAMFETTI_EXPECT"] == "notrecording" {
            XCTAssertTrue(app.staticTexts["Not recording"].waitForExistence(timeout: 20), "says the camera isn't recording")
            save(app, out, "playback-notrecording")
            app.buttons["backToLive"].tap()
            return
        }
        if env["CAMFETTI_EXPECT"] == "nocard" {
            XCTAssertTrue(app.staticTexts["No SD card"].waitForExistence(timeout: 20), "says the camera has no card")
            save(app, out, "playback-nocard")
            app.buttons["backToLive"].tap()
            return
        }
        XCTAssertTrue(app.descendants(matching: .any)["playbackVideo"].waitForExistence(timeout: 20), "a clip starts")
        sleep(6)
        save(app, out, "playback-1-latest")

        let chips = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Event at'"))
        if chips.count > 1 {
            // The strip opens scrolled to the newest clip, so the one before it is on screen.
            chips.element(boundBy: chips.count - 2).tap()
            sleep(6)
            save(app, out, "playback-2-earlier")
        }
        let yesterday = app.buttons["Yesterday"]
        if yesterday.exists {
            yesterday.tap()
            sleep(7)
            save(app, out, "playback-3-yesterday")
        }
        app.buttons["backToLive"].tap()
        XCTAssertTrue(app.buttons["recordingsButton"].waitForExistence(timeout: 8), "back on live")
    }

    @MainActor
    private func save(_ app: XCUIApplication, _ folder: String, _ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
