import XCTest
@testable import CamFetti

final class TelemetryTests: XCTestCase {
    private func body(_ event: Telemetry.Event) throws -> [String: Any] {
        let request = Telemetry.makeRequest(event, sessionId: "s", now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(request.value(forHTTPHeaderField: "App-Key"), "A-US-4230698939")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testAppOpenCarriesNoProps() throws {
        let b = try body(.appOpen)
        XCTAssertEqual(b["eventName"] as? String, "app_open")
        XCTAssertNil(b["props"])
    }

    func testPropsAreOnlyFeatureNameAndErrorClass() throws {
        XCTAssertEqual(try body(.featureUsed("add_camera"))["props"] as? [String: String], ["name": "add_camera"])
        XCTAssertEqual(try body(.error("URLError"))["props"] as? [String: String], ["class": "URLError"])
    }

    func testOffSendsNothingAndIsRemembered() {
        UserDefaults.standard.set(false, forKey: Telemetry.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: Telemetry.defaultsKey) }
        XCTAssertFalse(Telemetry.isEnabled)
    }

    func testOnByDefault() {
        UserDefaults.standard.removeObject(forKey: Telemetry.defaultsKey)
        #if !os(tvOS)
        XCTAssertTrue(Telemetry.isEnabled)
        #endif
    }
}
