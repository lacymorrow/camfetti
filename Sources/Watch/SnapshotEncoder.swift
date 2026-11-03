import CoreGraphics
import Foundation
import ImageIO

/// Shrinks a camera picture to something that fits through WatchConnectivity quickly:
/// about 400 px wide, JPEG quality 0.6, about 30 KB.
enum SnapshotEncoder {
    static let snapshotWidth = 400
    static let snapshotQuality = 0.6
    /// Ceiling for one reply. Quality steps down when a busy picture goes past it.
    static let snapshotBudget = 40_000
    static let thumbnailWidth = 160
    static let thumbnailQuality = 0.5

    static func snapshot(from jpeg: Data) -> Data? {
        encode(jpeg, width: snapshotWidth, quality: snapshotQuality, budget: snapshotBudget)
    }

    static func thumbnail(from jpeg: Data) -> Data? {
        encode(jpeg, width: thumbnailWidth, quality: thumbnailQuality, budget: nil)
    }

    static func encode(_ jpeg: Data, width: Int, quality: Double, budget: Int?) -> Data? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        if image.width > width, let scaled = FrameGrabber.scale(image, toWidth: width) { image = scaled }
        var q = quality
        var data = FrameGrabber.encode(image, quality: q)
        while let budget, let current = data, current.count > budget, q > 0.3 {
            q -= 0.1
            data = FrameGrabber.encode(image, quality: q)
        }
        return data
    }
}
