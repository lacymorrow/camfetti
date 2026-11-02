import XCTest

/// App Store screenshots from whatever cameras are already in the app. Skipped unless
/// TEST_RUNNER_CAMFETTI_SHOTS=1. Attachments: store-1-grid, store-2-full, store-3-add.
final class StoreScreenshots: XCTestCase {
    @MainActor
    func testCaptureStoreScreenshots() throws {
        guard ProcessInfo.processInfo.environment["CAMFETTI_SHOTS"] == "1" else { throw XCTSkip("screenshots not requested") }
        let app = XCUIApplication()
        app.launch()
        let tiles = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tile-'"))
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 10))
        sleep(8)
        shot(app, "store-1-grid")

        let target = app.descendants(matching: .any)["tile-Front Porch"].firstMatch
        (target.exists ? target : tiles.firstMatch).tap()
        sleep(6)
        if !app.buttons["closeCamera"].exists { app.otherElements["liveVideo"].firstMatch.tap() }
        XCTAssertTrue(app.buttons["closeCamera"].waitForExistence(timeout: 3))
        shot(app, "store-2-full")
        app.buttons["closeCamera"].tap()

        app.buttons["addButton"].tap()
        sleep(7)
        shot(app, "store-3-add")
    }

    /// First run: what the add screen finds on the Wi-Fi. Clears the camera list.
    @MainActor
    func testCaptureFreshAddScreen() throws {
        guard ProcessInfo.processInfo.environment["CAMFETTI_SHOTS"] == "fresh" else { throw XCTSkip("fresh screenshots not requested") }
        let app = XCUIApplication()
        app.launchArguments = ["-resetForTesting"]
        app.launch()
        XCTAssertTrue(app.buttons["emptyAddButton"].waitForExistence(timeout: 10))
        sleep(10)
        shot(app, "store-4-empty")
        app.buttons["emptyAddButton"].tap()
        sleep(8)
        shot(app, "store-3-add")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
