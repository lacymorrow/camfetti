import XCTest
@testable import CamFetti

final class OnvifTests: XCTestCase {
    func testPasswordDigestMatchesSpecExample() {
        // ONVIF Core spec example: nonce, created and password give a known digest.
        let nonce = Data(base64Encoded: "LKqI6G/AikKCQrN0zqZFlg==")!
        XCTAssertEqual(OnvifClient.passwordDigest(password: "userpassword", nonce: nonce, created: "2010-09-16T07:50:45Z"),
                       "tuOSpGlFlIXsozq4HFNeeGeFLEI=")
    }

    func testEnvelopeEscapesUsername() {
        let xml = OnvifClient.envelope(body: "<x/>", username: "a<b", password: "p", nonce: Data([1, 2]), created: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(xml.contains("<wsse:Username>a&lt;b</wsse:Username>"))
        XCTAssertTrue(xml.contains("<s:Body><x/></s:Body>"))
    }

    func testPicksLargestAndSmallestProfiles() throws {
        let xml = """
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:trt="m" xmlns:tt="t"><s:Body><trt:GetProfilesResponse>
        <trt:Profiles token="sub"><tt:VideoEncoderConfiguration><tt:Resolution><tt:Width>640</tt:Width><tt:Height>360</tt:Height></tt:Resolution></tt:VideoEncoderConfiguration></trt:Profiles>
        <trt:Profiles token="main"><tt:VideoEncoderConfiguration><tt:Resolution><tt:Width>2560</tt:Width><tt:Height>1440</tt:Height></tt:Resolution></tt:VideoEncoderConfiguration></trt:Profiles>
        </trt:GetProfilesResponse></s:Body></s:Envelope>
        """
        let node = try XCTUnwrap(XMLNode.parse(Data(xml.utf8)))
        let picked = OnvifClient.pickProfiles(OnvifClient.profiles(in: node))
        XCTAssertEqual(picked.main?.token, "main")
        XCTAssertEqual(picked.sub?.token, "sub")
    }

    func testSingleProfileHasNoSubstream() {
        let picked = OnvifClient.pickProfiles([.init(token: "only", width: 1920, height: 1080)])
        XCTAssertEqual(picked.main?.token, "only")
        XCTAssertNil(picked.sub)
    }

    func testRebasesReportedAddressOntoReachableHost() {
        XCTAssertEqual(OnvifClient.rebase("rtsp://10.10.10.10:554/live", onto: "http://192.168.1.70:8000/onvif/device_service"),
                       "rtsp://192.168.1.70:554/live")
        XCTAssertEqual(OnvifClient.rebase("http://10.10.10.10/onvif/media", onto: "http://192.168.1.70:8000/onvif/device_service"),
                       "http://192.168.1.70:8000/onvif/media")
    }
}

final class ThinginoParsingTests: XCTestCase {
    func testParsesStreamConfig() throws {
        let json = #"{"username":"thingino","password":"s3cret","onvif_port":"80","rtsp_port":"554","rtsp_ch0":"ch0","rtsp_ch1":"ch1","rtsp_mic":"mic"}"#
        let c = try XCTUnwrap(ThinginoClient.parseStreamConfig(Data(json.utf8)))
        XCTAssertEqual(c, .init(username: "thingino", password: "s3cret", port: 554, mainPath: "ch0", subPath: "ch1"))
    }

    func testStreamConfigDefaultsWhenPathsBlank() throws {
        let c = try XCTUnwrap(ThinginoClient.parseStreamConfig(Data(#"{"username":"u","password":"p","rtsp_port":"","rtsp_ch0":"","rtsp_ch1":""}"#.utf8)))
        XCTAssertEqual(c.port, 554)
        XCTAssertEqual(c.mainPath, "ch0")
        XCTAssertEqual(c.subPath, "ch1")
    }

    func testKeyGoesInTokenParameterAndOnlyIfHex() {
        XCTAssertEqual(ThinginoClient.authenticatedPath("/x/json-imp.cgi", apiKey: "abc123"), "/x/json-imp.cgi?token=abc123")
        XCTAssertEqual(ThinginoClient.authenticatedPath("/x/json-motor.cgi?d=j", apiKey: "abc123"), "/x/json-motor.cgi?d=j&token=abc123")
        XCTAssertEqual(ThinginoClient.authenticatedPath("/x/a.cgi", apiKey: nil), "/x/a.cgi")
        XCTAssertEqual(ThinginoClient.authenticatedPath("/x/json-motor.cgi", apiKey: "a;reboot"), "/x/json-motor.cgi", "json-motor evals its query string")
    }

    func testRaptorUsesStreamPaths() {
        XCTAssertEqual(ThinginoClient.defaultPaths(streamer: "raptor").main, "stream0")
        XCTAssertEqual(ThinginoClient.defaultPaths(streamer: "prudynt").sub, "ch1")
    }

    func testReadsAPIKeyAndCookie() {
        XCTAssertEqual(ThinginoClient.apiKey(in: Data(#"{"api_key":"abc","exists":true}"#.utf8)), "abc")
        XCTAssertNil(ThinginoClient.apiKey(in: Data(#"{"exists":false}"#.utf8)))
        let r = HTTPURLResponse(url: URL(string: "http://x")!, statusCode: 200, httpVersion: nil,
                                headerFields: ["Set-Cookie": "session=deadbeef; Path=/; HttpOnly"])!
        XCTAssertEqual(ThinginoClient.sessionCookie(from: r), "session=deadbeef")
    }
}

/// Runs against the fake Thingino and MediaMTX rig (rig/start.sh). Skipped when the rig is down.
final class RigIntegrationTests: XCTestCase {
    let base = URL(string: "http://127.0.0.1:8080")!

    private func requireRig() async throws {
        var r = URLRequest(url: base, timeoutInterval: 4)
        r.httpMethod = "GET"
        guard (try? await URLSession.shared.data(for: r)) != nil else { throw XCTSkip("test rig not running") }
    }

    func testThinginoSignInMintsKeyAndReadsStreams() async throws {
        try await requireRig()
        let key = try await ThinginoClient(base: base).mintAPIKey(password: "root")
        XCTAssertEqual(key.count, 64)
        let client = ThinginoClient(base: base, apiKey: key)
        let config = try await client.streamConfig()
        XCTAssertEqual(config.port, 8554)
        let motors = await client.hasMotors()
        XCTAssertTrue(motors)
        try await client.setDayNight(.night)
        try await client.move(dx: -40, dy: 0)
        let state = try JSONSerialization.jsonObject(with: try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8080/_state?token=\(key)")!).0) as? [String: Any]
        XCTAssertEqual(state?["daynight"] as? String, "night", "the command really reached the camera")
    }

    func testWrongThinginoPasswordIsReported() async throws {
        try await requireRig()
        do {
            _ = try await ThinginoClient(base: base).mintAPIKey(password: "nope")
            XCTFail("expected wrong password")
        } catch let e as ThinginoClient.Failure {
            XCTAssertEqual(e, .wrongPassword)
        }
    }

    func testProberAddsThinginoEndToEnd() async throws {
        try await requireRig()
        let result = try await CameraProber().probe(.init(address: "127.0.0.1", username: "", password: "root",
                                                          isThingino: true, httpPort: 8080, streamer: "prudynt", name: "Rig"))
        XCTAssertEqual(result.camera.kind, .thingino)
        XCTAssertEqual(result.camera.subURL, "rtsp://127.0.0.1:8554/ch1")
        XCTAssertTrue(result.camera.canPan)
        XCTAssertNotNil(result.apiKey)
    }

    func testProberAcceptsRTSPLinkAndRejectsBadPassword() async throws {
        try await requireRig()
        let ok = try await CameraProber().probe(.init(address: "rtsp://thingino:thingino@127.0.0.1:8554/hevc", username: "", password: ""))
        XCTAssertEqual(ok.camera.mainURL, "rtsp://127.0.0.1:8554/hevc")
        XCTAssertEqual(ok.password, "thingino")
        do {
            _ = try await CameraProber().probe(.init(address: "rtsp://127.0.0.1:8554/ch0", username: "thingino", password: "wrong"))
            XCTFail("expected wrong password")
        } catch let e as CameraProber.Failure {
            XCTAssertEqual(e, .wrongPassword)
        }
    }
}
