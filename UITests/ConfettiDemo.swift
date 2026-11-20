import XCTest

/// Confetti after every added camera, not just the first. Needs the rig (rig/start.sh).
/// Skipped unless TEST_RUNNER_CAMFETTI_CONFETTI names a folder for the PNGs.
final class ConfettiDemo: XCTestCase {
    @MainActor
    func testConfettiOnEveryAdd() throws {
        guard let out = ProcessInfo.processInfo.environment["CAMFETTI_CONFETTI"] else { throw XCTSkip("confetti shots not requested") }
        let app = XCUIApplication()
        app.launchArguments = ["-resetForTesting"]
        app.launch()

        XCTAssertTrue(app.buttons["emptyAddButton"].waitForExistence(timeout: 5))
        app.buttons["emptyAddButton"].tap()
        add(app, stream: "ch0", out: out, shot: "1-first-camera")

        app.buttons["addButton"].tap()
        let byAddress = app.buttons["showAddressButton"]
        if byAddress.waitForExistence(timeout: 5) { byAddress.tap() }
        add(app, stream: "ch1", out: out, shot: "2-second-camera")
    }

    @MainActor
    private func add(_ app: XCUIApplication, stream: String, out: String, shot: String) {
        let address = app.textFields["addressField"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        address.typeText("rtsp://thingino:thingino@127.0.0.1:8554/\(stream)")
        app.buttons["connectButton"].tap()
        let save = app.buttons["saveCameraButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        save.tap()
        usleep(700_000)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(shot).png"))
        sleep(4)
    }
}
