import CoreMedia
import Foundation
import IPCamKit

/// Turns IPCamKit NAL units into CoreMedia samples that AVSampleBufferDisplayLayer decodes
/// in hardware. Pure functions, so they are unit tested directly.
enum H26x {
    enum Failure: Error { case formatDescription(OSStatus) }

    static func nalType(_ nal: Data, codec: VideoCodec) -> UInt8 {
        guard let first = nal.first else { return 0 }
        return codec == .h264 ? (first & 0x1F) : ((first >> 1) & 0x3F)
    }

    /// True when decoding can start at this frame. IPCamKit flags IDR frames only, but H.265
    /// encoders often open each group with a CRA or BLA frame (types 16 to 21), which is just as good.
    static func isRandomAccess(_ nalus: [Data], codec: VideoCodec, flagged: Bool) -> Bool {
        if flagged { return true }
        return nalus.contains { nal in
            let t = nalType(nal, codec: codec)
            return codec == .h264 ? t == 5 : (16...21).contains(t)
        }
    }

    /// Parameter sets carried in-band, for cameras that leave them out of the SDP.
    static func parameterSets(in nalus: [Data], codec: VideoCodec) -> (vps: Data?, sps: Data?, pps: Data?) {
        var vps: Data?, sps: Data?, pps: Data?
        for nal in nalus {
            switch (codec, nalType(nal, codec: codec)) {
            case (.h264, 7), (.h265, 33): sps = nal
            case (.h264, 8), (.h265, 34): pps = nal
            case (.h265, 32): vps = nal
            default: break
            }
        }
        return (vps, sps, pps)
    }

    static func formatDescription(codec: VideoCodec, sps: Data, pps: Data, vps: Data?) throws -> CMVideoFormatDescription {
        var sets: [Data] = []
        if codec == .h265, let vps { sets.append(vps) }
        sets.append(sps)
        sets.append(pps)
        let arrays = sets.map { [UInt8]($0) }
        var out: CMVideoFormatDescription?
        let status: OSStatus = withPointers(arrays) { ptrs, sizes in
            switch codec {
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: arrays.count, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &out)
            case .h265:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: nil, parameterSetCount: arrays.count, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &out)
            }
        }
        guard status == noErr, let out else { throw Failure.formatDescription(status) }
        return out
    }

    private static func withPointers<R>(_ arrays: [[UInt8]], _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
        let buffers = arrays.map { a -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: a.count)
            p.initialize(from: a, count: a.count)
            return p
        }
        defer { buffers.enumerated().forEach { $1.deallocate() } }
        let ptrs = buffers.map { UnsafePointer($0) }
        let sizes = arrays.map(\.count)
        return ptrs.withUnsafeBufferPointer { p in
            sizes.withUnsafeBufferPointer { s in body(p.baseAddress!, s.baseAddress!) }
        }
    }

    /// AVCC payload: each VCL NAL prefixed with its 4-byte big-endian length. Parameter sets,
    /// SEI and access unit delimiters are dropped; they live in the format description.
    static func avcc(_ nalus: [Data], codec: VideoCodec) -> Data {
        var out = Data()
        for nal in nalus where !nal.isEmpty {
            let t = nalType(nal, codec: codec)
            if codec == .h264, (6...9).contains(t) { continue }
            if codec == .h265, (32...40).contains(t) { continue }
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(nal)
        }
        return out
    }

    static func sampleBuffer(nalus: [Data], codec: VideoCodec, isKeyframe: Bool,
                             format: CMVideoFormatDescription, pts: CMTime = .zero) -> CMSampleBuffer? {
        let payload = avcc(nalus, codec: codec)
        guard !payload.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: payload.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: payload.count, flags: 0,
            blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = payload.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: payload.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = payload.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !isKeyframe {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }

    static func dimensions(_ format: CMVideoFormatDescription) -> (width: Int, height: Int) {
        let d = CMVideoFormatDescriptionGetDimensions(format)
        return (Int(d.width), Int(d.height))
    }
}
