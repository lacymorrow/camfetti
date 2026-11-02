import AVFoundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import SwiftUI

/// Shows a LiveStream's display layer inside SwiftUI.
#if canImport(UIKit)
struct VideoSurface: UIViewRepresentable {
    let stream: LiveStream
    var fill = true
    var onReady: ((UIView) -> Void)?

    func makeUIView(context: Context) -> Host { Host() }

    func updateUIView(_ view: Host, context: Context) {
        view.attach(stream.layer, fill: fill)
    }

    final class Host: UIView {
        private weak var attached: CALayer?

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        func attach(_ video: AVSampleBufferDisplayLayer, fill: Bool) {
            video.videoGravity = fill ? .resizeAspectFill : .resizeAspect
            guard attached !== video else { return }
            attached?.removeFromSuperlayer()
            layer.addSublayer(video)
            attached = video
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            attached?.frame = bounds
            CATransaction.commit()
        }
    }
}
#else
struct VideoSurface: NSViewRepresentable {
    let stream: LiveStream
    var fill = true

    func makeNSView(context: Context) -> Host { Host() }

    func updateNSView(_ view: Host, context: Context) {
        view.attach(stream.layer, fill: fill)
    }

    final class Host: NSView {
        private weak var attached: CALayer?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        func attach(_ video: AVSampleBufferDisplayLayer, fill: Bool) {
            video.videoGravity = fill ? .resizeAspectFill : .resizeAspect
            guard attached !== video else { return }
            attached?.removeFromSuperlayer()
            layer?.addSublayer(video)
            attached = video
            needsLayout = true
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            attached?.frame = bounds
            CATransaction.commit()
        }
    }
}
#endif

#if os(iOS)
import AVKit

/// Picture in Picture for a live stream. Starts automatically when the person swipes home.
@MainActor
final class PiPController: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    private var controller: AVPictureInPictureController?

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func attach(to stream: LiveStream) {
        guard Self.isSupported, controller == nil else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: stream.layer, playbackDelegate: self)
        let pip = AVPictureInPictureController(contentSource: source)
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        pip.requiresLinearPlayback = true
        controller = pip
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            controller.startPictureInPicture()
        }
    }

    func detach() {
        controller?.stopPictureInPicture()
        controller = nil
    }

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {}
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { false }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime) async {}
}
#endif
