import SwiftUI
import UIKit

/// Full screen. Primary action: watch. Controls fade away on their own.
struct CameraScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let camera: Camera

    @State private var stream: LiveStream?
    @State private var pip = PiPController()
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var offsetBase: CGSize = .zero
    @State private var fill = false
    @State private var toast: String?
    @State private var dayNight: ThinginoClient.DayNight?
    @State private var ptzActive = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            video
                .scaleEffect(zoom)
                .offset(offset)
                .ignoresSafeArea()
                .gesture(magnify)
                .simultaneousGesture(drag)
                .onTapGesture(count: 2) { withAnimation(.easeOut(duration: 0.2)) { doubleTap() } }
                .onTapGesture { toggleControls() }
            status
            if controlsVisible { controls.transition(.opacity) }
            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 96)
                }
                .transition(.opacity)
            }
        }
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
        .onAppear(perform: begin)
        .onDisappear(perform: end)
        .onChange(of: stream?.phase) { _, phase in
            if phase == .live, let stream { pip.attach(to: stream) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { stream?.start() }
        }
    }

    @ViewBuilder private var video: some View {
        ZStack {
            if let data = stream?.thumbnail, let image = UIImage(data: data), stream?.phase != .live {
                Image(uiImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit).opacity(0.7)
            }
            if let stream {
                VideoSurface(stream: stream, fill: fill)
                    .opacity(stream.phase == .live ? 1 : 0)
                    .accessibilityLabel("\(camera.name) live video")
                    .accessibilityIdentifier("liveVideo")
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch stream?.phase {
        case .connecting:
            ProgressView().tint(.white).controlSize(.large)
        case .reconnecting:
            Label("Reconnecting", systemImage: "arrow.triangle.2.circlepath")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
        case .failed(.wrongPassword):
            failure("Wrong password", action: "Sign In Again") {
                model.editing = camera
                dismiss()
            }
        case .failed:
            failure("No video from this camera", action: "Try Again") { stream?.retry() }
        default:
            EmptyView()
        }
    }

    private func failure(_ text: String, action: String, perform: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Text(text).font(.headline).foregroundStyle(.white)
            Button(action, action: perform).buttonStyle(.borderedProminent)
        }
    }

    private var controls: some View {
        VStack {
            HStack {
                Button { dismiss() } label: { ControlIcon(symbol: "xmark") }
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("closeCamera")
                Spacer()
                Text(camera.name).font(.headline).foregroundStyle(.white).shadow(radius: 4).lineLimit(1)
                Spacer()
                Button { model.editing = camera; dismiss() } label: { ControlIcon(symbol: "info") }
                    .accessibilityLabel("Details")
            }
            Spacer()
            HStack(spacing: 20) {
                if stream?.hasAudio == true {
                    Button { stream?.muted.toggle(); keepControls() } label: {
                        ControlIcon(symbol: stream?.muted == false ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    }
                    .accessibilityLabel(stream?.muted == false ? "Mute" : "Listen")
                }
                Button { Task { await snapshot() } } label: { ControlIcon(symbol: "camera.fill") }
                    .accessibilityLabel("Save snapshot")
                    .accessibilityIdentifier("snapshotButton")
                if camera.kind == .thingino, CameraSecrets(id: camera.id).apiKey != nil {
                    Menu {
                        ForEach(ThinginoClient.DayNight.allCases, id: \.self) { mode in
                            Button { setDayNight(mode) } label: {
                                Label(mode.rawValue.capitalized, systemImage: symbol(for: mode))
                            }
                        }
                    } label: {
                        ControlIcon(symbol: symbol(for: dayNight ?? .auto))
                    }
                    .accessibilityLabel("Day and night mode")
                    .accessibilityIdentifier("dayNightMenu")
                }
                if PiPController.isSupported {
                    Button { pip.toggle() } label: { ControlIcon(symbol: "pip.enter") }
                        .accessibilityLabel("Picture in Picture")
                }
            }
            .padding(.bottom, 8)
        }
        .padding(16)
    }

    private func symbol(for mode: ThinginoClient.DayNight) -> String {
        switch mode {
        case .auto: "circle.lefthalf.filled"
        case .day: "sun.max.fill"
        case .night: "moon.fill"
        }
    }

    // MARK: Gestures

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { zoom = max(1, min(6, zoomBase * $0.magnification)) }
            .onEnded { _ in
                zoomBase = zoom
                if zoom == 1 { offset = .zero; offsetBase = .zero }
            }
    }

    /// Dragging moves around a zoomed picture. At normal zoom it moves the camera's motors.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if zoom > 1 {
                    offset = CGSize(width: offsetBase.width + value.translation.width,
                                    height: offsetBase.height + value.translation.height)
                } else if camera.onvif?.ptzURL != nil, !ptzActive {
                    ptzActive = true
                    onvifMove(value.translation)
                }
            }
            .onEnded { value in
                if zoom > 1 {
                    offsetBase = offset
                } else if camera.canPan {
                    finishPan(value.translation)
                }
            }
    }

    private func doubleTap() {
        if zoom > 1 {
            zoom = 1; zoomBase = 1; offset = .zero; offsetBase = .zero
        } else {
            fill.toggle()
        }
    }

    private func onvifMove(_ translation: CGSize) {
        guard let client = model.onvifClient(for: camera), let ptz = camera.onvif?.ptzURL,
              let token = camera.onvif?.profileToken else { return }
        let v = PanMath.velocity(for: translation)
        Task { try? await client.move(ptzURL: ptz, profile: token, pan: v.pan, tilt: v.tilt) }
    }

    private func finishPan(_ translation: CGSize) {
        if camera.kind == .thingino, let client = model.thinginoClient(for: camera) {
            let steps = PanMath.motorSteps(for: translation)
            Task { try? await client.move(dx: steps.dx, dy: steps.dy) }
        } else if let client = model.onvifClient(for: camera), let ptz = camera.onvif?.ptzURL,
                  let token = camera.onvif?.profileToken {
            ptzActive = false
            Task { try? await client.move(ptzURL: ptz, profile: token, pan: 0, tilt: 0) }
        }
    }

    // MARK: Actions

    private func begin() {
        let s = model.mainStream(for: camera)
        stream = s
        s.start()
        keepControls()
    }

    private func end() {
        hideTask?.cancel()
        pip.detach()
        stream?.stop()
    }

    private func toggleControls() {
        withAnimation(.easeOut(duration: 0.2)) { controlsVisible.toggle() }
        if controlsVisible { keepControls() }
    }

    private func keepControls() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { controlsVisible = false }
        }
    }

    private func snapshot() async {
        keepControls()
        guard let jpeg = await stream?.snapshot() else {
            show("No picture yet")
            return
        }
        switch await model.save(jpeg: jpeg) {
        case .saved: show("Saved to Photos")
        case .denied: show("Allow Photos access in Settings")
        case .failed: show("Couldn't save the snapshot")
        }
    }

    private func setDayNight(_ mode: ThinginoClient.DayNight) {
        keepControls()
        guard let client = model.thinginoClient(for: camera) else { return }
        Task {
            do {
                try await client.setDayNight(mode)
                dayNight = mode
                show("\(mode.rawValue.capitalized) mode")
            } catch {
                show("Camera didn't respond")
            }
        }
    }

    private func show(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation { if toast == text { toast = nil } }
        }
    }
}

/// Converts a finger drag into camera movement. Dragging moves the picture with the finger,
/// so the camera turns the opposite way.
enum PanMath {
    /// Thingino motor steps per point dragged.
    static let stepsPerPoint = 4.0

    static func motorSteps(for translation: CGSize) -> (dx: Int, dy: Int) {
        (Int((-translation.width * stepsPerPoint).rounded()), Int((translation.height * stepsPerPoint).rounded()))
    }

    static func velocity(for translation: CGSize) -> (pan: Double, tilt: Double) {
        let scale = 120.0
        return (max(-1, min(1, -translation.width / scale)), max(-1, min(1, translation.height / scale)))
    }
}

private struct ControlIcon: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 46, height: 46)
            .background(.ultraThinMaterial, in: Circle())
            .environment(\.colorScheme, .dark)
    }
}
