import SwiftUI

/// Full screen. Primary action: watch. Controls fade away on their own.
struct CameraScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let camera: Camera

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stream: LiveStream?
    #if os(iOS)
    @State private var pip = PiPController()
    #endif
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
            Theme.videoBackground.ignoresSafeArea(edges: Theme.videoSafeAreaEdges)
            video
                .scaleEffect(zoom)
                .offset(offset)
                .ignoresSafeArea(edges: Theme.videoSafeAreaEdges)
                .gesture(magnify)
                .simultaneousGesture(drag)
                .onTapGesture(count: 2) { withAnimation(fade(Theme.Motion.quick)) { doubleTap() } }
                .onTapGesture { toggleControls() }
            status
            if controlsVisible { controls.transition(.opacity) }
            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(Theme.pillFont)
                        .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.snug)
                        .background(Theme.pillMaterial, in: Capsule())
                        .padding(.bottom, Theme.toastBottomInset)
                }
                .transition(.opacity)
            }
        }
        .immersive(!controlsVisible)
        .background { backShortcut }
        .onAppear(perform: begin)
        .onDisappear(perform: end)
        .onChange(of: stream?.phase) { _, phase in
            #if os(iOS)
            if phase == .live, let stream { pip.attach(to: stream) }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { stream?.start() }
        }
    }

    @ViewBuilder private var video: some View {
        ZStack {
            if let data = stream?.thumbnail, let image = Image(imageData: data), stream?.phase != .live {
                image.resizable().aspectRatio(contentMode: fill ? .fill : .fit).opacity(Theme.placeholderOpacityLarge)
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
            ProgressView().tint(Theme.onVideo).controlSize(.large)
        case .reconnecting:
            Label("Reconnecting", systemImage: "arrow.triangle.2.circlepath")
                .font(Theme.pillFont)
                .padding(.horizontal, Theme.Space.cozy).padding(.vertical, Theme.Space.sm)
                .background(Theme.pillMaterial, in: Capsule())
        case .failed(.wrongPassword):
            failure("Wrong password", action: "Sign In Again") {
                model.editing = camera
                close()
            }
        case .failed:
            failure("No video from this camera", action: "Try Again") { stream?.retry() }
        default:
            EmptyView()
        }
    }

    private func failure(_ text: String, action: String, perform: @escaping () -> Void) -> some View {
        VStack(spacing: Theme.Space.md) {
            Text(text).font(Theme.headlineFont).foregroundStyle(Theme.onVideo)
            Button(action, action: perform).buttonStyle(.borderedProminent)
        }
    }

    private var controls: some View {
        VStack {
            HStack {
                Button { close() } label: { ControlIcon(symbol: Self.closeSymbol) }
                    .accessibilityLabel(Self.closeLabel)
                    .accessibilityIdentifier("closeCamera")
                Spacer()
                Text(camera.name).font(Theme.headlineFont).foregroundStyle(Theme.onVideo).shadow(radius: Theme.shadowRadius).lineLimit(1)
                Spacer()
                Button { model.editing = camera; close() } label: { ControlIcon(symbol: "info") }
                    .accessibilityLabel("Details")
            }
            Spacer()
            HStack(spacing: Theme.Space.roomy) {
                if stream?.hasAudio == true {
                    Button { stream?.muted.toggle(); keepControls() } label: {
                        ControlIcon(symbol: stream?.muted == false ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    }
                    .accessibilityLabel(stream?.muted == false ? "Mute" : "Listen")
                }
                Button { Task { await snapshot() } } label: { ControlIcon(symbol: "camera.fill") }
                    .accessibilityLabel("Save snapshot")
                    .accessibilityIdentifier("snapshotButton")
                #if os(iOS)
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
                #endif
            }
            .padding(.bottom, Theme.Space.sm)
        }
        .padding(Theme.Space.lg)
        .buttonStyle(.plain)
    }

    /// Dragging to turn a camera is a touch gesture. The Mac has no PTZ in v1.
    private static var hasMotors: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    private static var closeSymbol: String {
        #if os(iOS)
        "xmark"
        #else
        "chevron.backward"
        #endif
    }

    private static var closeLabel: String {
        #if os(iOS)
        "Close"
        #else
        "Back"
        #endif
    }

    /// Returns to the grid. Always present, so Esc works even after the controls fade away.
    private var backShortcut: some View {
        Button("Back") { close() }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .accessibilityHidden(true)
    }

    private func close() { model.focused = nil }

    private func fade(_ duration: Double) -> Animation? {
        Theme.animation(duration, reduceMotion: reduceMotion)
    }

    #if os(iOS)
    private func symbol(for mode: ThinginoClient.DayNight) -> String {
        switch mode {
        case .auto: "circle.lefthalf.filled"
        case .day: "sun.max.fill"
        case .night: "moon.fill"
        }
    }

    #endif

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
                } else if Self.hasMotors, camera.onvif?.ptzURL != nil, !ptzActive {
                    ptzActive = true
                    onvifMove(value.translation)
                }
            }
            .onEnded { value in
                if zoom > 1 {
                    offsetBase = offset
                } else if Self.hasMotors, camera.canPan {
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
        #if os(iOS)
        pip.detach()
        #endif
        stream?.stop()
    }

    private func toggleControls() {
        withAnimation(fade(Theme.Motion.quick)) { controlsVisible.toggle() }
        if controlsVisible { keepControls() }
    }

    private func keepControls() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(Theme.Timing.controlsHide))
            guard !Task.isCancelled else { return }
            withAnimation(fade(Theme.Motion.relaxed)) { controlsVisible = false }
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
        withAnimation(fade(Theme.Motion.quick)) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(Theme.Timing.toastHold))
            withAnimation(fade(Theme.Motion.quick)) { if toast == text { toast = nil } }
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
            .font(Theme.controlGlyphFont)
            .foregroundStyle(Theme.onVideo)
            .frame(width: Theme.controlSize, height: Theme.controlSize)
            .background(Theme.controlMaterial, in: Circle())
            .environment(\.colorScheme, .dark)
    }
}
