import SwiftUI

struct WatchRootView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.cameras.count == 1, let only = model.cameras.first {
                    CameraSnapshotView(camera: only)
                } else {
                    CameraListView()
                }
            }
        }
        .task { await model.refresh() }
    }
}

struct CameraListView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        Group {
            if model.heardFromPhone && model.cameras.isEmpty {
                MessageView(symbol: "video.slash", text: "Add cameras in CamFetti on your iPhone.")
            } else if model.cameras.isEmpty {
                // First run, nothing cached yet: a tile, never a blank screen.
                ScrollView {
                    PlaceholderTile(message: model.link == .notNearby ? "iPhone not nearby" : nil,
                                    showsProgress: model.link != .notNearby)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.Space.xs) {
                        if model.link == .notNearby {
                            Text("iPhone not nearby")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        ForEach(model.cameras) { camera in
                            NavigationLink(value: camera) { CameraRow(camera: camera) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .navigationTitle("CamFetti")
        .navigationDestination(for: WatchProtocol.CameraSummary.self) { CameraSnapshotView(camera: $0) }
    }
}

private struct CameraRow: View {
    let camera: WatchProtocol.CameraSummary

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let data = camera.thumbnail, let image = UIImage(data: data) {
                Color.clear
                    .aspectRatio(Theme.tileAspect, contentMode: .fit)
                    .overlay { Image(uiImage: image).resizable().aspectRatio(contentMode: .fill) }
                    .clipped()
            } else {
                PlaceholderTile(message: nil, showsProgress: false)
            }
            Rectangle().fill(Theme.scrim)
            Text(camera.name)
                .font(Theme.tileLabelFont)
                .foregroundStyle(Theme.onVideo)
                .lineLimit(1)
                .padding(Theme.Space.xs)
        }
        .aspectRatio(Theme.tileAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile))
    }
}

struct CameraSnapshotView: View {
    let camera: WatchProtocol.CameraSummary
    @State private var loader: SnapshotLoader
    @Environment(\.scenePhase) private var scenePhase

    init(camera: WatchProtocol.CameraSummary) {
        self.camera = camera
        _loader = State(initialValue: SnapshotLoader(camera: camera))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(loader.isError ? Theme.dimmedOpacity : 1)
                    .ignoresSafeArea()
            } else {
                PlaceholderTile(message: nil, showsProgress: false)
            }
            if let message = loader.message {
                ErrorNote(message: message, date: loader.imageDate)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.videoBackground.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            if !loader.hasFresh && !loader.isError {
                ProgressView().padding(Theme.Space.xs)
            }
        }
        .navigationTitle(camera.name)
        .navigationBarTitleDisplayMode(.inline)
        // Runs only while the app is on screen. Dropping the wrist cancels it.
        .task(id: scenePhase) {
            if scenePhase == .active { await loader.run() }
        }
    }
}

private struct ErrorNote: View {
    let message: String
    let date: Date?

    var body: some View {
        VStack(spacing: Theme.Space.xxs) {
            Text(message).font(Theme.tileMessageFont)
            if let date {
                TimelineView(.periodic(from: .now, by: Theme.Timing.ageRefresh)) { context in
                    Text(AgeText.text(since: date, now: context.date))
                        .font(Theme.tileDetailFont)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(Theme.onVideo)
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, Theme.Space.xs)
        .background(Theme.pillMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .padding(Theme.Space.xs)
    }
}

struct PlaceholderTile: View {
    let message: String?
    let showsProgress: Bool

    var body: some View {
        ZStack {
            Theme.tileBackground
            VStack(spacing: Theme.Space.xs) {
                Image(systemName: "video.fill")
                    .font(Theme.stateSymbolFont)
                    .foregroundStyle(Theme.tertiaryText)
                if let message {
                    Text(message).font(Theme.tileMessageFont).foregroundStyle(Theme.onVideo)
                } else if showsProgress {
                    ProgressView()
                }
            }
        }
        .aspectRatio(Theme.tileAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile))
    }
}

struct MessageView: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: symbol)
                .font(Theme.stateSymbolFont)
                .foregroundStyle(Theme.tertiaryText)
            Text(text)
                .font(Theme.bodyFont)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Space.sm)
    }
}
