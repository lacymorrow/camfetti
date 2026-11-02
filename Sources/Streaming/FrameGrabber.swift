import CoreMedia
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// Decodes one keyframe to a JPEG. Used for tile thumbnails and snapshots of cameras
/// that have no snapshot URL.
enum FrameGrabber {
    static func jpeg(from sample: CMSampleBuffer, maxWidth: Int? = nil, quality: Double = 0.8) -> Data? {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        var session: VTDecompressionSession?
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
        guard VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &session) == noErr, let session else { return nil }
        defer { VTDecompressionSessionInvalidate(session) }

        final class Box: @unchecked Sendable { var image: CGImage? }
        let box = Box()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, buffer, _, _ in
            guard status == noErr, let buffer else { return }
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
            box.image = image
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard status == noErr, var image = box.image else { return nil }
        if let maxWidth, image.width > maxWidth, let scaled = scale(image, toWidth: maxWidth) { image = scaled }
        return encode(image, quality: quality)
    }

    static func encode(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func scale(_ image: CGImage, toWidth width: Int) -> CGImage? {
        let height = max(1, image.height * width / image.width)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
