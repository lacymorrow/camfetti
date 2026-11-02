import CoreMedia
import IPCamKit
import XCTest
@testable import CamFetti

final class H26xTests: XCTestCase {
    // 640x360 H.264 baseline parameter sets, captured from the test rig.
    let sps = Data([0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x02, 0x80, 0xBF, 0xE5, 0x84, 0x00, 0x00, 0x03, 0x00, 0x04, 0x00, 0x00, 0x03, 0x00, 0xF0, 0x3C, 0x58, 0xBA, 0x80])
    let pps = Data([0x68, 0xCE, 0x0F, 0xC8])

    func testNalTypes() {
        XCTAssertEqual(H26x.nalType(Data([0x65]), codec: .h264), 5)
        XCTAssertEqual(H26x.nalType(Data([0x67]), codec: .h264), 7)
        XCTAssertEqual(H26x.nalType(Data([0x40, 0x01]), codec: .h265), 32)
        XCTAssertEqual(H26x.nalType(Data([0x26, 0x01]), codec: .h265), 19)
    }

    func testCRAAndIDRAreRandomAccess() {
        XCTAssertTrue(H26x.isRandomAccess([Data([0x40, 0x01]), Data([0x2A, 0x01])], codec: .h265, flagged: false), "CRA")
        XCTAssertTrue(H26x.isRandomAccess([Data([0x26, 0x01])], codec: .h265, flagged: false), "IDR_W_RADL")
        XCTAssertFalse(H26x.isRandomAccess([Data([0x02, 0x01])], codec: .h265, flagged: false), "trailing picture")
        XCTAssertTrue(H26x.isRandomAccess([Data([0x65])], codec: .h264, flagged: false))
        XCTAssertFalse(H26x.isRandomAccess([Data([0x41])], codec: .h264, flagged: false))
        XCTAssertTrue(H26x.isRandomAccess([Data([0x41])], codec: .h264, flagged: true))
    }

    func testFindsInBandParameterSets() {
        let sets = H26x.parameterSets(in: [sps, pps, Data([0x65, 0x88])], codec: .h264)
        XCTAssertEqual(sets.sps, sps)
        XCTAssertEqual(sets.pps, pps)
        XCTAssertNil(sets.vps)
    }

    func testAVCCDropsParameterSetsAndSEI() {
        let idr = Data([0x65, 0xAA, 0xBB])
        let sei = Data([0x06, 0x01])
        let out = H26x.avcc([sps, pps, sei, idr], codec: .h264)
        XCTAssertEqual(out, Data([0, 0, 0, 3, 0x65, 0xAA, 0xBB]))
    }

    func testFormatDescriptionReadsDimensions() throws {
        let format = try H26x.formatDescription(codec: .h264, sps: sps, pps: pps, vps: nil)
        let size = H26x.dimensions(format)
        XCTAssertEqual(size.width, 640)
        XCTAssertEqual(size.height, 360)
    }

    func testSampleBufferMarksNonKeyframes() throws {
        let format = try H26x.formatDescription(codec: .h264, sps: sps, pps: pps, vps: nil)
        let sample = try XCTUnwrap(H26x.sampleBuffer(nalus: [Data([0x41, 0x9A])], codec: .h264, isKeyframe: false, format: format))
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)) as NSArray
        let dict = try XCTUnwrap(attachments.firstObject as? NSDictionary)
        XCTAssertEqual(dict[kCMSampleAttachmentKey_NotSync] as? Bool, true)
        XCTAssertEqual(dict[kCMSampleAttachmentKey_DisplayImmediately] as? Bool, true)
    }

    func testEmptyFrameMakesNoSample() throws {
        let format = try H26x.formatDescription(codec: .h264, sps: sps, pps: pps, vps: nil)
        XCTAssertNil(H26x.sampleBuffer(nalus: [sps, pps], codec: .h264, isKeyframe: true, format: format))
    }
}

final class StreamPumpTests: XCTestCase {
    func testWrongPasswordStopsRetrying() {
        guard case .stop(.wrongPassword) = StreamPump.outcome(for: RTSPError.authenticationFailed) else { return XCTFail() }
        guard case .stop(.wrongPassword) = StreamPump.outcome(for: RTSPError.sessionSetupFailed(statusCode: 401, reason: "")) else { return XCTFail() }
    }

    func testMissingStreamStops() {
        guard case .stop(.notFound) = StreamPump.outcome(for: RTSPError.sessionSetupFailed(statusCode: 404, reason: "")) else { return XCTFail() }
    }

    func testNetworkErrorsRetry() {
        guard case .retry = StreamPump.outcome(for: RTSPError.timeout) else { return XCTFail() }
        guard case .retry = StreamPump.outcome(for: RTSPError.connectionFailed("refused")) else { return XCTFail() }
        guard case .retry = StreamPump.outcome(for: URLError(.timedOut)) else { return XCTFail() }
    }

    func testLoginHangUpsCoverResetAndDisconnect() {
        XCTAssertTrue(StreamPump.isLoginHangUp(RTSPError.unexpectedDisconnection))
        XCTAssertTrue(StreamPump.isLoginHangUp(RTSPError.connectionFailed("Read error: (Network.NWError error 54 - Connection reset by peer)")))
        XCTAssertFalse(StreamPump.isLoginHangUp(RTSPError.connectionFailed("POSIXErrorCode(rawValue: 61): Connection refused")))
        XCTAssertFalse(StreamPump.isLoginHangUp(RTSPError.timeout))
    }

    func testBackoffCapsAtEightSeconds() {
        var d = 0.5
        for _ in 0..<10 { d = StreamPump.nextDelay(after: d) }
        XCTAssertEqual(d, 8)
    }
}
