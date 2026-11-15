import XCTest

/// App Store stills and the app preview walk, on the real cameras already in the app.
/// Skipped unless TEST_RUNNER_CAMFETTI_MEDIA names a folder for the PNGs. Paced for a
/// screen recording: grid, full screen, landscape, recordings, add a camera.
final class StoreMedia: XCTestCase {
    @MainActor
    func testStoreMediaWalk() throws {
        guard let out = ProcessInfo.processInfo.environment["CAMFETTI_MEDIA"] else { throw XCTSkip("store media not requested") }
        let live = ProcessInfo.processInfo.environment["CAMFETTI_LIVE"] ?? "Driveway"
        let recorded = ProcessInfo.processInfo.environment["CAMFETTI_RECORDED"] ?? "Library"
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()

        let tile = app.descendants(matching: .any)["tile-\(live)"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20))
        sleep(7)
        save(out, "1-grid")

        tile.tap()
        let close = app.buttons["closeCamera"]
        sleep(3)
        if !close.isHittable { app.otherElements["liveVideo"].firstMatch.tap() }
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        save(out, "2-full")
        sleep(1)

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(4)
        if !close.isHittable { app.otherElements["liveVideo"].firstMatch.tap(); sleep(1) }
        save(out, "3-landscape")
        sleep(2)
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        if !close.isHittable { app.otherElements["liveVideo"].firstMatch.tap() }
        close.tap()
        sleep(1)

        app.descendants(matching: .any)["tile-\(recorded)"].firstMatch.tap()
        let recordings = app.buttons["recordingsButton"]
        for _ in 0..<6 {
            if recordings.waitForExistence(timeout: 2), recordings.isHittable { recordings.tap(); break }
            app.otherElements["liveVideo"].firstMatch.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["playbackVideo"].waitForExistence(timeout: 20), "a clip starts")
        sleep(6)
        save(out, "4-recordings")
        app.buttons["backToLive"].tap()
        sleep(1)
        if !close.isHittable { app.otherElements["liveVideo"].firstMatch.tap() }
        close.tap()
        sleep(1)

        app.buttons["addButton"].tap()
        sleep(6)
        save(out, "5-add")
    }

    @MainActor
    private func save(_ folder: String, _ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
