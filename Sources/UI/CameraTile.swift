import SwiftUI

/// One camera in the grid. Streams only while visible.
struct CameraTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let camera: Camera
    @State private var stream: LiveStream?
    @State private var stuck = false

    var body: some View {
        // The shape comes from the empty rectangle, so a 4:3 picture can't stretch the tile.
        Rectangle().fill(Brand.ink)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                if let data = stream?.thumbnail, let image = Image(imageData: data) {
                    image.resizable().scaledToFill()
                        .opacity(stream?.phase == .live ? 1 : 0.55)
                }
            }
            .overlay {
                if let stream {
                    VideoSurface(stream: stream)
                        .opacity(stream.phase == .live ? 1 : 0)
                }
            }
            .overlay { overlay }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { model.focused = camera }
        .contextMenu {
            Button("Details", systemImage: "info.circle") { model.editing = camera }
            Button("Move Earlier", systemImage: "arrow.backward") { model.store.move(camera, by: -1) }
            Button("Move Later", systemImage: "arrow.forward") { model.store.move(camera, by: 1) }
            Button("Remove", systemImage: "trash", role: .destructive) { model.remove(camera) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(camera.name)
        .accessibilityValue(statusWords)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("tile-\(camera.name)")
        .onAppear(perform: begin)
        .onDisappear { model.stopGridStream(camera) }
        .onChange(of: model.focused) { _, focused in
            if focused == nil { begin() } else { model.stopGridStream(camera) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.focused == nil { begin() }
        }
        .onChange(of: camera) { _, _ in
            model.resetStream(camera)
            stream = nil
            begin()
        }
        .task(id: stream?.phase) {
            // A camera that stays silent for a while gets a plain message instead of a spinner.
            stuck = false
            guard stream?.phase == .connecting || stream?.phase == .reconnecting else { return }
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { stuck = true }
        }
    }

    private func begin() {
        let s = model.gridStream(for: camera)
        stream = s
        s.start()
    }

    private var statusWords: String {
        switch stream?.phase {
        case .live: "live"
        case .connecting: stuck ? "can't reach camera" : "connecting"
        case .reconnecting: "reconnecting"
        case .failed(.wrongPassword): "wrong password"
        case .failed: "no video"
        default: "paused"
        }
    }

    @ViewBuilder private var overlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 6) {
                Text(camera.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if stream?.phase == .reconnecting {
                    Text("Reconnecting").font(.caption2)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom))
        }
        switch stream?.phase {
        case .connecting, .reconnecting:
            if stuck {
                TileMessage(text: camera.awayHost == nil ? "Can't reach this camera" : "Camera is offline",
                            action: "Retry") { stream?.retry() }
            } else if stream?.phase == .connecting {
                ProgressView().tint(.white)
            }
        case .failed(.wrongPassword):
            TileMessage(text: "Wrong password", action: "Sign In Again") { model.editing = camera }
        case .failed:
            TileMessage(text: "No video from this camera", action: "Details") { model.editing = camera }
        default:
            EmptyView()
        }
    }
}

private struct TileMessage: View {
    let text: String
    let action: String
    let perform: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text(text).font(.caption.weight(.medium)).foregroundStyle(.white).multilineTextAlignment(.center)
            Button(action, action: perform)
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .padding(8)
    }
}
