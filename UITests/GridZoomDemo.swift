import XCTest

/// Pinches the iPhone camera grid through every tile size and saves a screenshot of each.
/// Skipped unless TEST_RUNNER_CAMFETTI_GRID names an output folder. Needs the rig (rig/start.sh).
final class GridZoomDemo: XCTestCase {
    @MainActor
    func testPinchResizesTheGrid() throws {
        guard let out = ProcessInfo.processInfo.environment["CAMFETTI_GRID"] else { throw XCTSkip("no output folder") }
        let app = XCUIApplication()
        app.launchArguments = ["-resetForTesting", "-seedDemo", "127.0.0.1", "-manyCameras"]
        app.launch()
        let first = app.descendants(matching: .any)["tile-Front Porch"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 30))
        sleep(6)
        save(out, "1-two-up-default")
        let width = { first.frame.width }
        let twoUp = width()

        // Spread: bigger tiles, one per row, filling the width.
        app.scrollViews.firstMatch.pinch(withScale: 2, velocity: 2)
        sleep(4)
        XCTAssertGreaterThan(width(), twoUp * 1.8, "one column fills the width")
        save(out, "2-one-up")

        // Squeeze twice from two-up: three, then four across, names dropped at four.
        app.scrollViews.firstMatch.pinch(withScale: 0.5, velocity: -2)
        sleep(2)
        app.scrollViews.firstMatch.pinch(withScale: 0.5, velocity: -2)
        sleep(4)
        save(out, "3-three-up")
        app.scrollViews.firstMatch.pinch(withScale: 0.5, velocity: -2)
        sleep(4)
        XCTAssertLessThan(width(), twoUp * 0.6, "four across")
        save(out, "4-four-up")
        app.scrollViews.firstMatch.pinch(withScale: 0.5, velocity: -2)
        sleep(2)
        save(out, "5-four-is-the-floor")

        // The size sticks across launches.
        app.terminate()
        app.launchArguments = ["-seedDemo", "127.0.0.1", "-manyCameras"]
        app.launch()
        XCTAssertTrue(first.waitForExistence(timeout: 30))
        XCTAssertLessThan(width(), twoUp * 0.6, "remembered")

        // Sideways: one more column than portrait.
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(5)
        save(out, "6-landscape")
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    private func save(_ folder: String, _ name: String) {
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
