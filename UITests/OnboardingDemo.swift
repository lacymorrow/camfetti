import XCTest

/// First-run screens on a real network, for review and store shots. Skipped unless
/// TEST_RUNNER_CAMFETTI_ONBOARD names a folder for the PNGs. TEST_RUNNER_CAMFETTI_SEED (from
/// scripts/shots-seed.py) adds the "already added" pass. Taps only cameras that don't sign in
/// on their own, so no camera sees a login attempt.
final class OnboardingDemo: XCTestCase {
    @MainActor
    func testFirstRunFindsCameras() throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["CAMFETTI_ONBOARD"] else { throw XCTSkip("onboarding shots not requested") }
        let pick = env["CAMFETTI_PICK"] ?? "192.168.1.70"
        let app = XCUIApplication()
        app.launchArguments = ["-resetForTesting"]
        app.launch()

        let row = app.buttons["found-\(pick)"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the camera shows up on its own")
        sleep(6)
        save(out, "first-run-found")
        row.tap()
        XCTAssertTrue(app.secureTextFields["Password"].waitForExistence(timeout: 5), "straight to signing in")
        save(out, "first-run-sign-in")
        app.buttons["Cancel"].tap()

        guard let seed = env["CAMFETTI_SEED"] else { return }
        app.terminate()
        app.launchArguments = ["-resetForTesting", "-seedReal", seed]
        app.launch()
        XCTAssertTrue(app.buttons["addButton"].waitForExistence(timeout: 30))
        // -seedReal signs in to each camera in the background; give the slow ones time.
        sleep(25)
        // A tap can land while the grid is still settling; try again before giving up.
        let sheet = app.navigationBars["Add Camera"]
        for _ in 0..<3 where !sheet.exists {
            app.buttons["addButton"].tap()
            _ = sheet.waitForExistence(timeout: 5)
        }
        // Only save the sheet. The grid behind it shows live cameras, which can catch people.
        guard sheet.exists, app.buttons["found-\(pick)"].waitForExistence(timeout: 30) else {
            return XCTFail("add sheet with found cameras")
        }
        sleep(8)
        save(out, "add-sheet-with-added")
    }

    @MainActor
    private func save(_ folder: String, _ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
