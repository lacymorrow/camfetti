import XCTest
@testable import CamFetti

final class CameraTests: XCTestCase {
    func testStripsCredentialsFromURL() {
        let r = Camera.strippingCredentials("rtsp://admin:p%40ss@10.0.0.5:554/stream1")
        XCTAssertEqual(r.url, "rtsp://10.0.0.5:554/stream1")
        XCTAssertEqual(r.user, "admin")
        XCTAssertEqual(r.password, "p@ss")
    }

    func testReplacesHostForAwayAddress() {
        XCTAssertEqual(Camera.replacingHost(in: "rtsp://192.168.1.9:554/ch1", with: "porch.tail1234.ts.net"),
                       "rtsp://porch.tail1234.ts.net:554/ch1")
    }

    func testAddressesTryHomeFirstThenAway() {
        #if AWAY
        // A simulator used for Away testing may still route through the relay.
        AwayConfig.routeThroughRelay = false
        #endif
        var cam = Camera(name: "Porch", kind: .thingino, host: "192.168.1.9", mainURL: "rtsp://192.168.1.9/ch0", username: "thingino")
        XCTAssertEqual(AppModel.addresses(for: cam, url: cam.mainURL), ["rtsp://192.168.1.9/ch0"])
        cam.awayHost = "100.64.0.9"
        XCTAssertEqual(AppModel.addresses(for: cam, url: cam.mainURL), ["rtsp://192.168.1.9/ch0", "rtsp://100.64.0.9/ch0"])
    }

    func testGridUsesSubstreamWhenPresent() {
        var cam = Camera(name: "A", kind: .rtsp, host: "h", mainURL: "rtsp://h/main", username: "")
        XCTAssertEqual(cam.gridURL, "rtsp://h/main")
        cam.subURL = "rtsp://h/sub"
        XCTAssertEqual(cam.gridURL, "rtsp://h/sub")
    }

    func testWebBaseBracketsIPv6() {
        let cam = Camera(name: "A", kind: .thingino, host: "fe80::1", mainURL: "", username: "", httpPort: 8080)
        XCTAssertEqual(cam.webBase()?.absoluteString, "http://[fe80::1]:8080")
    }
}

@MainActor
final class CameraStoreTests: XCTestCase {
    func testPersistsAcrossInstancesWithoutSecrets() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cams-\(UUID()).json")
        let store = CameraStore(fileURL: file)
        let cam = Camera(name: "Garage", kind: .rtsp, host: "10.0.0.7", mainURL: "rtsp://10.0.0.7/a", username: "admin")
        store.add(cam, password: "hunter2")
        let reloaded = CameraStore(fileURL: file)
        XCTAssertEqual(reloaded.cameras.map(\.name), ["Garage"])
        let json = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(json.contains("hunter2"), "passwords must never be written to the camera list")
        reloaded.remove(reloaded.cameras[0])
        XCTAssertTrue(CameraStore(fileURL: file).cameras.isEmpty)
    }

    func testMoveReorders() {
        let store = CameraStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID()).json"))
        let a = Camera(name: "A", kind: .rtsp, host: "a", mainURL: "rtsp://a", username: "")
        let b = Camera(name: "B", kind: .rtsp, host: "b", mainURL: "rtsp://b", username: "")
        store.add(a, password: nil)
        store.add(b, password: nil)
        store.move(b, by: -1)
        XCTAssertEqual(store.cameras.map(\.name), ["B", "A"])
        XCTAssertTrue(store.contains(host: "A"))
    }
}

final class ProberTests: XCTestCase {
    func testParsesAddresses() throws {
        let bare = try XCTUnwrap(CameraProber.parseAddress(" 192.168.1.70 "))
        XCTAssertNil(bare.scheme); XCTAssertEqual(bare.host, "192.168.1.70"); XCTAssertNil(bare.port)
        let withPort = try XCTUnwrap(CameraProber.parseAddress("cam.local:8080"))
        XCTAssertEqual(withPort.host, "cam.local"); XCTAssertEqual(withPort.port, 8080)
        let rtsp = try XCTUnwrap(CameraProber.parseAddress("rtsp://u:p@10.0.0.2:8554/live"))
        XCTAssertEqual(rtsp.scheme, "rtsp"); XCTAssertEqual(rtsp.host, "10.0.0.2")
        XCTAssertNil(CameraProber.parseAddress("   "))
    }

    func testGridFitsFourCamerasOnOnePhoneScreen() {
        // iPhone 17 Pro Max portrait: about 424 x 760 points for the grid.
        let four = GridLayout.best(count: 4, width: 424, height: 760)
        XCTAssertEqual(four.columns, 1)
        let rows: CGFloat = 4
        XCTAssertLessThanOrEqual(four.tileWidth * GridLayout.ratio * rows + GridLayout.spacing * (rows - 1), 760.5)
        XCTAssertEqual(GridLayout.best(count: 1, width: 424, height: 760).tileWidth, 424)
        XCTAssertEqual(GridLayout.best(count: 9, width: 424, height: 760).columns, 2, "many cameras go two-up")
        XCTAssertEqual(GridLayout.best(count: 40, width: 424, height: 760).columns, 2, "and scroll when nothing fits")
        XCTAssertEqual(GridLayout.best(count: 4, width: 900, height: 380).columns, 2, "landscape goes wide")
    }

    func testPanMathMovesOppositeToFinger() {
        let steps = PanMath.motorSteps(for: CGSize(width: 50, height: -25))
        XCTAssertEqual(steps.dx, -200)
        XCTAssertEqual(steps.dy, -100)
        let v = PanMath.velocity(for: CGSize(width: -500, height: 0))
        XCTAssertEqual(v.pan, 1)
        XCTAssertEqual(v.tilt, 0)
    }

    func testSubnetHostsSkipSelfAndStayWithinSlash24() {
        let ip: UInt32 = (192 << 24) | (168 << 16) | (1 << 8) | 252
        let subnet = LocalSubnet(address: ip, mask: 0xFFFF_0000)
        XCTAssertEqual(subnet.hosts.count, 253)
        XCTAssertFalse(subnet.hosts.contains("192.168.1.252"))
        XCTAssertEqual(subnet.hosts.first, "192.168.1.1")
    }

    func testBrandFromPage() {
        XCTAssertEqual(SubnetSweep.brand(inPage: "<title>Reolink</title>"), "Reolink")
        XCTAssertEqual(SubnetSweep.brand(inPage: "<html>thingino</html>"), "Thingino")
        XCTAssertNil(SubnetSweep.brand(inPage: "<html>router</html>"))
    }
}
