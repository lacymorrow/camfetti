import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CamFetti

final class SnapshotEncoderTests: XCTestCase {
    /// A noisy 1920x1080 JPEG, like a real camera frame.
    private func sourceJPEG(width: Int = 1920, height: Int = 1080) -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt32 = 7
        for i in stride(from: 0, to: pixels.count, by: 4) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let base = UInt8((i / 4 % width) * 255 / width)
            pixels[i] = base; pixels[i + 1] = UInt8(truncatingIfNeeded: seed >> 24) / 4 + 40; pixels[i + 2] = 200; pixels[i + 3] = 255
        }
        let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return FrameGrabber.encode(ctx.makeImage()!, quality: 0.9)!
    }

    private func size(of data: Data) -> (Int, Int)? {
        guard let s = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    func testSnapshotIsDownscaledToFourHundredWideJPEG() throws {
        let source = sourceJPEG()
        let out = try XCTUnwrap(SnapshotEncoder.snapshot(from: source))
        let (w, h) = try XCTUnwrap(size(of: out))
        XCTAssertEqual(w, 400)
        XCTAssertEqual(h, 225)
        XCTAssertLessThanOrEqual(out.count, SnapshotEncoder.snapshotBudget)
        XCTAssertLessThan(out.count, source.count)
        XCTAssertEqual(out.prefix(2), Data([0xFF, 0xD8]), "JPEG magic")
    }

    func testSmallPicturesAreNotUpscaled() throws {
        let out = try XCTUnwrap(SnapshotEncoder.snapshot(from: sourceJPEG(width: 320, height: 180)))
        XCTAssertEqual(size(of: out)?.0, 320)
    }

    func testThumbnailIsSmallerThanSnapshot() throws {
        let source = sourceJPEG()
        let thumb = try XCTUnwrap(SnapshotEncoder.thumbnail(from: source))
        XCTAssertEqual(size(of: thumb)?.0, SnapshotEncoder.thumbnailWidth)
        XCTAssertLessThan(thumb.count, try XCTUnwrap(SnapshotEncoder.snapshot(from: source)).count)
    }

    func testGarbageInputReturnsNil() {
        XCTAssertNil(SnapshotEncoder.snapshot(from: Data("not a picture".utf8)))
    }
}

final class AgeTextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testAges() {
        func text(_ seconds: TimeInterval) -> String { AgeText.text(since: now.addingTimeInterval(-seconds), now: now) }
        XCTAssertEqual(text(0), "Just now")
        XCTAssertEqual(text(59), "Just now")
        XCTAssertEqual(text(60), "1 min ago")
        XCTAssertEqual(text(125), "2 min ago")
        XCTAssertEqual(text(3599), "59 min ago")
        XCTAssertEqual(text(3600), "1 hr ago")
        XCTAssertEqual(text(7 * 3600), "7 hr ago")
        XCTAssertEqual(text(2 * 86_400), "2 d ago")
    }

    func testFutureDateIsJustNow() {
        XCTAssertEqual(AgeText.text(since: now.addingTimeInterval(30), now: now), "Just now")
    }
}

final class WatchProtocolTests: XCTestCase {
    func testCameraListRoundTripCarriesNoSecrets() throws {
        let rows = [WatchProtocol.CameraSummary(id: "A", name: "Porch", thumbnail: Data([1, 2])),
                    WatchProtocol.CameraSummary(id: "B", name: "Garage", thumbnail: nil)]
        let message = WatchProtocol.encode(cameras: rows)
        XCTAssertEqual(WatchProtocol.decodeCameras(message), rows)
        XCTAssertFalse(String(describing: message).lowercased().contains("password"))
    }

    func testSnapshotAndFailureReplies() {
        XCTAssertEqual(WatchProtocol.decodeSnapshot(WatchProtocol.encode(snapshot: Data([9]))), Data([9]))
        XCTAssertNil(WatchProtocol.decodeSnapshot(WatchProtocol.encode(failure: .camera)))
    }

    @MainActor
    func testPhoneAnswersWithoutUIAndRejectsUnknownCamera() async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("w-\(UUID()).json")
        let store = CameraStore(fileURL: file)
        let cam = Camera(name: "Porch", kind: .rtsp, host: "10.0.0.2", mainURL: "rtsp://10.0.0.2/a", username: "u")
        store.add(cam, password: "hunter2")
        let list = await WatchLink.answer(request: WatchProtocol.Request.cameras, id: nil, store: store)
        XCTAssertEqual(WatchProtocol.decodeCameras(list)?.map(\.name), ["Porch"])
        XCTAssertFalse(String(describing: list).contains("hunter2"))
        let bad = await WatchLink.answer(request: WatchProtocol.Request.snapshot, id: UUID().uuidString, store: store)
        XCTAssertEqual(bad[WatchProtocol.Key.error] as? String, WatchProtocol.Failure.badRequest.rawValue)
        store.remove(cam)
    }
}

final class SnapshotFetcherTests: XCTestCase {
    func testOnlyRealJPEGCounts() {
        XCTAssertTrue(SnapshotFetcher.isJPEG(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00])))
        // Reolink answers 200 with JSON when the snapshot needs query-string credentials.
        XCTAssertFalse(SnapshotFetcher.isJPEG(Data(#"[{"cmd":"Snap","code":1,"error":{"rspCode":-6}}]"#.utf8)))
        XCTAssertFalse(SnapshotFetcher.isJPEG(Data()))
    }
}
