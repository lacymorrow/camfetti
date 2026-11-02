import XCTest

/// Needs the test rig (rig/start.sh) on this Mac.
final class CamFettiUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAddCameraByLinkThenWatchFullScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-resetForTesting"]
        app.launch()

        XCTAssertTrue(app.buttons["emptyAddButton"].waitForExistence(timeout: 5), "first run shows the add button")
        attach(app, "1-empty")
        app.buttons["emptyAddButton"].tap()

        let address = app.textFields["addressField"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        address.typeText("rtsp://thingino:thingino@127.0.0.1:8554/ch0")
        app.buttons["connectButton"].tap()

        let save = app.buttons["saveCameraButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 15), "preview step appears after the stream answers")
        let name = app.textFields["nameField"]
        name.tap()
        name.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        name.typeText("Front Porch")
        attach(app, "2-preview")
        save.tap()

        let tile = app.buttons["tile-Front Porch"].firstMatch
        let anyTile = tile.exists ? tile : app.descendants(matching: .any)["tile-Front Porch"].firstMatch
        XCTAssertTrue(anyTile.waitForExistence(timeout: 5))
        let live = NSPredicate(format: "value == 'live'")
        expectation(for: live, evaluatedWith: anyTile)
        waitForExpectations(timeout: 15)
        sleep(3)
        attach(app, "3-grid")

        anyTile.tap()
        XCTAssertTrue(app.buttons["closeCamera"].waitForExistence(timeout: 5))
        sleep(4)
        attach(app, "4-fullscreen")
        // Controls fade after three seconds. A tap brings them back.
        XCTAssertFalse(app.buttons["closeCamera"].isHittable)
        app.otherElements["liveVideo"].firstMatch.tap()
        XCTAssertTrue(app.buttons["closeCamera"].waitForExistence(timeout: 3))
        attach(app, "5-controls")

        // Snapshot saves to Photos without crashing (regression: 2026-10-31 crash on save).
        if !app.buttons["snapshotButton"].isHittable { app.otherElements["liveVideo"].firstMatch.tap() }
        app.buttons["snapshotButton"].tap()
        // Either the Photos permission prompt or the toast comes first. Watch for both.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let toast = app.staticTexts["Saved to Photos"]
        var sawToast = false
        for _ in 0..<40 {
            if toast.exists { sawToast = true; break }
            let alert = springboard.alerts.firstMatch
            if alert.exists {
                alert.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Allow' OR label == 'OK'")).firstMatch.tap()
            }
            usleep(250_000)
        }
        XCTAssertTrue(sawToast, "snapshot toast appears and the app is still running")
        XCTAssertEqual(app.state, .runningForeground)
        attach(app, "6-snapshot")
        closeFullScreen(app)

        // Persists across launches.
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["tile-Front Porch"].firstMatch.waitForExistence(timeout: 5))
    }

    /// Controls fade after three seconds, so reveal and tap in one go, retrying if they faded mid-tap.
    private func closeFullScreen(_ app: XCUIApplication) {
        let close = app.buttons["closeCamera"]
        for _ in 0..<4 {
            if !close.exists { app.otherElements["liveVideo"].firstMatch.tap() }
            if close.waitForExistence(timeout: 1) && close.isHittable {
                close.tap()
                if app.otherElements["liveVideo"].firstMatch.waitForNonExistence(timeout: 3) { return }
            }
        }
        XCTFail("could not close full screen")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
