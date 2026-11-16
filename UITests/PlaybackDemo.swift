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
        // Opens Recordings at launch. Tapping through the fading controls misses on a loaded machine.
        app.launchArguments = ["-resetForTesting", "-seedReal", seed, "-focusCamera", name, "-openRecordings"]
        app.launch()

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
        XCTAssertTrue(app.descendants(matching: .any)["playbackVideo"].waitForExistence(timeout: 90), "a clip starts")
        sleep(6)
        save(app, out, "playback-1-latest")

        // A camera that records nonstop opens on its activity, one tap from every clip.
        let activity = app.buttons["activityOnly"]
        if activity.exists {
            activity.tap()
            sleep(6)
            save(app, out, "playback-1b-every-clip")
            activity.tap()
            sleep(6)
            save(app, out, "playback-1c-activity")
        }

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
