import AVFoundation
import IPCamKit

/// Plays camera audio. Starts its engine only while unmuted so silent tiles cost nothing.
/// Supports G.711 (PCMU, PCMA), L16 and AAC.
final class AudioOut: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var codec: PublicAudioCodec?
    private var muted = true
    private var config: (PublicAudioCodec, Double, UInt32, Data?)?

    static func isSupported(_ codec: PublicAudioCodec) -> Bool {
        switch codec {
        case .pcmu, .pcma, .l16, .aac: return true
        default: return false
        }
    }

    func configure(codec: PublicAudioCodec, sampleRate: Double, channels: UInt32, extraData: Data?) {
        lock.lock(); defer { lock.unlock() }
        config = (codec, sampleRate, channels, extraData)
        if !muted { startLocked() }
    }

    func setMuted(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        muted = value
        if value { stopLocked() } else { startLocked() }
    }

    func enqueue(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !muted, let converter, let inputFormat, let node else { return }
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 4096) else { return }
        let input: AVAudioBuffer
        if case .aac = codec {
            let compressed = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: 1, maximumPacketSize: data.count)
            data.withUnsafeBytes { compressed.data.copyMemory(from: $0.baseAddress!, byteCount: data.count) }
            compressed.byteLength = UInt32(data.count)
            compressed.packetCount = 1
            compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
                mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(data.count))
            input = compressed
        } else {
            let bytesPerFrame = Int(inputFormat.streamDescription.pointee.mBytesPerFrame)
            let frames = data.count / max(1, bytesPerFrame)
            guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
            pcm.frameLength = AVAudioFrameCount(frames)
            _ = data.withUnsafeBytes { memcpy(pcm.audioBufferList.pointee.mBuffers.mData, $0.baseAddress!, frames * bytesPerFrame) }
            input = pcm
        }
        nonisolated(unsafe) var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if error == nil, out.frameLength > 0 { node.scheduleBuffer(out) }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopLocked()
    }

    private func startLocked() {
        guard engine == nil, let (codec, rate, channels, extra) = config, Self.isSupported(codec) else { return }
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = rate
        asbd.mChannelsPerFrame = channels
        switch codec {
        case .pcmu, .pcma:
            if case .pcmu = codec { asbd.mFormatID = kAudioFormatULaw } else { asbd.mFormatID = kAudioFormatALaw }
            asbd.mFramesPerPacket = 1
            asbd.mBitsPerChannel = 8
            asbd.mBytesPerFrame = channels
            asbd.mBytesPerPacket = channels
        case .l16:
            asbd.mFormatID = kAudioFormatLinearPCM
            asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsPacked
            asbd.mFramesPerPacket = 1
            asbd.mBitsPerChannel = 16
            asbd.mBytesPerFrame = channels * 2
            asbd.mBytesPerPacket = channels * 2
        case .aac:
            asbd.mFormatID = kAudioFormatMPEG4AAC
            asbd.mFramesPerPacket = 1024
        default:
            return
        }
        guard let inFormat = AVAudioFormat(streamDescription: &asbd),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                            channels: AVAudioChannelCount(channels), interleaved: false),
              let conv = AVAudioConverter(from: inFormat, to: outFormat) else { return }
        if case .aac = codec, let extra { conv.magicCookie = extra }
        let eng = AVAudioEngine()
        let player = AVAudioPlayerNode()
        eng.attach(player)
        eng.connect(player, to: eng.mainMixerNode, format: outFormat)
        do { try eng.start() } catch { return }
        player.play()
        engine = eng; node = player; converter = conv; inputFormat = inFormat; self.codec = codec
    }

    private func stopLocked() {
        node?.stop()
        engine?.stop()
        engine = nil; node = nil; converter = nil; inputFormat = nil
    }
}
