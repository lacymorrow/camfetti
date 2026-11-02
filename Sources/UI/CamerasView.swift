import SwiftUI

/// Home screen. Primary action: tap a camera.
struct CamerasView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var showAdd = false
    @State private var showSettings = false
    @State private var finder = CameraFinder()
    @AppStorage("hasCelebrated") private var hasCelebrated = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Group {
                if model.store.cameras.isEmpty {
                    EmptyCamerasView(finder: finder, showAdd: $showAdd)
                } else {
                    grid
                }
            }
            .safeAreaInset(edge: .top) {
                if !model.isOnline { OfflineBanner() }
            }
            .navigationTitle("Cameras")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("settingsButton")
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add camera")
                        .accessibilityIdentifier("addButton")
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddCameraView(finder: finder)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(item: $model.editing) { CameraDetailsView(camera: $0) }
        .fullScreenCover(item: $model.focused) { CameraScreen(camera: $0) }
        .overlay {
            if model.celebrate {
                ConfettiBurst()
                    .ignoresSafeArea()
                    .task {
                        try? await Task.sleep(for: .seconds(2.6))
                        model.celebrate = false
                    }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.stopAll() }
        }
        .onChange(of: model.store.cameras.count) { old, new in
            if old == 0, new == 1, !hasCelebrated {
                hasCelebrated = true
                model.celebrate = true
            }
        }
        .task {
            finder.start()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-openSettings") { showSettings = true }
            #endif
        }
    }

    private var grid: some View {
        GeometryReader { geo in
            let cameras = model.store.cameras
            let layout = GridLayout.best(count: cameras.count, width: geo.size.width - 16, height: geo.size.height - 16)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(layout.tileWidth), spacing: GridLayout.spacing), count: layout.columns),
                          spacing: GridLayout.spacing) {
                    ForEach(cameras) { camera in
                        CameraTile(camera: camera)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// Picks the column count and tile size that shows every camera on one screen as large as possible.
/// Tiles stay 16:9. When no layout fits, it falls back to two columns and the grid scrolls.
enum GridLayout {
    static let spacing: CGFloat = 8
    static let ratio: CGFloat = 9.0 / 16.0

    static func best(count: Int, width: CGFloat, height: CGFloat) -> (columns: Int, tileWidth: CGFloat) {
        guard count > 0, width > 0, height > 0 else { return (1, max(width, 1)) }
        var best: (columns: Int, tileWidth: CGFloat)?
        for columns in 1...3 {
            let rows = CGFloat((count + columns - 1) / columns)
            var w = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let fitHeight = (height - spacing * (rows - 1)) / rows
            if w * ratio > fitHeight { w = fitHeight / ratio }
            guard w >= 150 else { continue }
            if best == nil || w > best!.tileWidth { best = (columns, w) }
        }
        let twoUp = (width - spacing) / 2
        return best ?? (count == 1 ? 1 : 2, count == 1 ? width : twoUp)
    }
}

struct OfflineBanner: View {
    var body: some View {
        Label("No connection", systemImage: "wifi.slash")
            .font(.footnote.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(.thinMaterial)
    }
}

/// First run. Shows what was found on the network, or how to add one by hand.
struct EmptyCamerasView: View {
    let finder: CameraFinder
    @Binding var showAdd: Bool

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Wordmark(size: 44)
            Text("Your cameras, live, in one tap.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if finder.found.isEmpty && finder.isSearching {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Looking on your Wi-Fi")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else if !finder.found.isEmpty {
                Text(finder.found.count == 1 ? "Found 1 camera on your Wi-Fi" : "Found \(finder.found.count) cameras on your Wi-Fi")
                    .font(.subheadline.weight(.medium))
            }
            Spacer()
            Button { showAdd = true } label: {
                Text(finder.found.isEmpty ? "Add a Camera" : "Add Your Cameras")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("emptyAddButton")
        }
        .padding(24)
    }
}
