import SwiftUI

/// Home screen. Primary action: tap a camera.
struct CamerasView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var adding: AddStart?
    @State private var showSettings = false
    @State private var finder = CameraFinder()

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Group {
                if model.store.cameras.isEmpty {
                    EmptyCamerasView(finder: finder) { adding = $0 }
                } else {
                    grid
                }
            }
            .safeAreaInset(edge: .top) {
                if !model.isOnline { OfflineBanner() }
            }
            #if os(macOS)
            .navigationTitle(model.focused?.name ?? "Cameras")
            #elseif os(tvOS)
            .navigationTitle("Cameras")
            #else
            .navigationTitle("Cameras")
            .toolbarTitleDisplayMode(.inlineLarge)
            #endif
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    #if !os(macOS)
                    if Platform.hasSettings {
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("Settings")
                            .accessibilityIdentifier("settingsButton")
                    }
                    #endif
                    // Adding a camera belongs to the grid, not to a camera shown large.
                    if model.focused == nil {
                        Button { adding = .pick } label: { Image(systemName: "plus") }
                            .accessibilityLabel("Add camera")
                            .accessibilityIdentifier("addButton")
                    }
                }
            }
        }
        .sheet(item: $adding) { start in
            AddCameraView(finder: finder, start: start)
        }
        #if !os(tvOS)
        .sheet(isPresented: $showSettings) { SettingsView() }
        #endif
        .sheet(item: $model.editing) { CameraDetailsView(camera: $0) }
        .cameraPresentation(item: $model.focused)
        .overlay {
            if model.celebrate {
                ConfettiBurst()
                    .ignoresSafeArea()
                    .task {
                        try? await Task.sleep(for: .seconds(Theme.Timing.confettiRun))
                        model.celebrate = false
                    }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.stopAll() }
            // Back from Settings after turning Local Network on: look again right away.
            if phase == .active, finder.isBlocked { finder.searchAgain() }
        }
        .task {
            finder.start()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-openSettings") { showSettings = true }
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-focusCamera"), i + 1 < args.count {
                // Seeded cameras arrive as their sign-ins finish, so wait for this one.
                for _ in 0..<120 where model.focused == nil {
                    try? await Task.sleep(for: .seconds(1))
                    model.focused = model.store.cameras.first { $0.name == args[i + 1] }
                }
            }
            #endif
        }
    }

    private var grid: some View {
        GeometryReader { geo in
            let cameras = model.store.cameras
            let width = geo.size.width - Theme.gridInset * 2
            let layout = Platform.isPhone
                ? GridLayout.filling(columns: phoneColumns(landscape: geo.size.width > geo.size.height), width: width)
                : GridLayout.best(count: cameras.count, width: width, height: geo.size.height - Theme.gridInset * 2)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(layout.tileWidth), spacing: Theme.gridSpacing), count: layout.columns),
                          spacing: Theme.gridSpacing) {
                    ForEach(cameras) { camera in
                        CameraTile(camera: camera, compact: layout.tileWidth < Theme.tileLabelMinWidth)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.gridInset)
            }
            .scrollBounceBehavior(.basedOnSize)
            #if os(iOS)
            .simultaneousGesture(Platform.isPhone ? pinch : nil)
            .accessibilityAction(named: "Larger Tiles") { zoom(by: -1) }
            .accessibilityAction(named: "Smaller Tiles") { zoom(by: 1) }
            #endif
        }
    }

    // iPhone: the person picks the tile size by pinching, as in Photos. Tiles always fill the width
    // and the grid scrolls, so adding a camera never shrinks the others.
    @AppStorage("phoneColumns") private var savedColumns = 0
    @State private var pinchStepped = false

    private func phoneColumns(landscape: Bool) -> Int {
        let portrait = savedColumns == 0 ? GridLayout.phoneDefault(count: model.store.cameras.count) : savedColumns
        // Sideways, one 16:9 tile would be taller than the screen, so each size gets one more column.
        return landscape ? portrait + 1 : portrait
    }

    private func zoom(by step: Int) {
        let now = phoneColumns(landscape: false)
        let next = min(max(now + step, 1), GridLayout.phoneMaxColumns)
        guard next != now else { return }
        withAnimation(Theme.gridZoom) { savedColumns = next }
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    #if os(iOS)
    /// One step per pinch: spread for bigger tiles, squeeze for smaller ones.
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard !pinchStepped else { return }
                if value.magnification > 1.2 { pinchStepped = true; zoom(by: -1) }
                else if value.magnification < 0.83 { pinchStepped = true; zoom(by: 1) }
            }
            .onEnded { _ in pinchStepped = false }
    }
    #endif
}

extension View {
    /// A camera opened large. Full screen on iPhone; on the Mac it takes over the window, and
    /// Esc or Back returns to the grid.
    @ViewBuilder func cameraPresentation(item: Binding<Camera?>) -> some View {
        #if os(iOS) || os(tvOS)
        fullScreenCover(item: item) { CameraScreen(camera: $0) }
        #elseif os(visionOS)
        modifier(CameraWindowOpener(item: item))
        #else
        overlay {
            if let camera = item.wrappedValue {
                CameraScreen(camera: camera)
                    .id(camera.id)
                    .background(Theme.videoBackground, ignoresSafeAreaEdges: Theme.videoSafeAreaEdges)
                    .transition(.opacity)
            }
        }
        #endif
    }
}

/// Picks the column count and tile size that shows every camera on one screen as large as possible.
/// Tiles stay 16:9. When no layout fits, it falls back to two columns and the grid scrolls.
enum GridLayout {
    static let spacing = Theme.gridSpacing
    static let ratio = 1 / Theme.tileAspect

    static func best(count: Int, width: CGFloat, height: CGFloat) -> (columns: Int, tileWidth: CGFloat) {
        guard count > 0, width > 0, height > 0 else { return (1, max(width, 1)) }
        var best: (columns: Int, tileWidth: CGFloat)?
        for columns in 1...3 {
            let rows = CGFloat((count + columns - 1) / columns)
            var w = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let fitHeight = (height - spacing * (rows - 1)) / rows
            if w * ratio > fitHeight { w = fitHeight / ratio }
            guard w >= Theme.tileMinWidth else { continue }
            if best == nil || w > best!.tileWidth { best = (columns, w) }
        }
        let twoUp = (width - spacing) / 2
        return best ?? (count == 1 ? 1 : 2, count == 1 ? width : twoUp)
    }

    static let phoneMaxColumns = 4

    /// Tiles that fill the width in the given number of columns.
    static func filling(columns: Int, width: CGFloat) -> (columns: Int, tileWidth: CGFloat) {
        let columns = max(columns, 1)
        return (columns, max((width - spacing * CGFloat(columns - 1)) / CGFloat(columns), 1))
    }

    /// Before anyone pinches: one camera per row while a few fit, two-up after that.
    static func phoneDefault(count: Int) -> Int { count <= 3 ? 1 : 2 }
}

struct OfflineBanner: View {
    var body: some View {
        Label("No connection", systemImage: "wifi.slash")
            .font(Theme.bannerFont)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.sm)
            .background(Theme.pillMaterial)
    }
}

/// First run. Primary action: tap a camera CamFetti found on the Wi-Fi. When nothing turns up,
/// adding by address takes over, with a link that explains what to check.
struct EmptyCamerasView: View {
    let finder: CameraFinder
    let add: (AddStart) -> Void

    private var searchedEmpty: Bool { finder.found.isEmpty && !finder.isSearching }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.section) {
                VStack(spacing: Theme.Space.sm) {
                    Wordmark(size: Theme.wordmarkHeroSize)
                    Text(Platform.usesFocus ? "Your cameras, live, in one click." : "Your cameras, live, in one tap.")
                        .font(Theme.subtitleFont)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, Theme.Space.section * 2)
                found
                #if os(tvOS)
                // No bottom bar on a TV: the remote moves down the list and lands on these.
                actions
                #endif
            }
            .padding(.horizontal, Theme.Space.xl)
            .frame(maxWidth: Theme.onboardingWidth)
            .frame(maxWidth: .infinity)
        }
        #if !os(tvOS)
        .safeAreaInset(edge: .bottom) { actions }
        #endif
    }

    @ViewBuilder private var found: some View {
        if finder.isBlocked {
            LocalNetworkNote()
        } else if finder.found.isEmpty && finder.isSearching {
            HStack(spacing: Theme.Space.sm) {
                ProgressView()
                Text("Looking for cameras on your Wi-Fi")
            }
            .font(.subheadline)
            .foregroundStyle(Theme.secondaryText)
        } else if searchedEmpty {
            VStack(spacing: Theme.Space.sm) {
                Text("No cameras found on this Wi-Fi").font(Theme.headlineFont)
                Text("Make sure the camera is on and on the same Wi-Fi as this device, or add it by its address.")
                    .font(Theme.footnoteFont)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                Button("Search Again") { finder.searchAgain() }
                    .accessibilityIdentifier("searchAgainButton")
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack {
                    Text(finder.found.count == 1 ? "Found 1 camera" : "Found \(finder.found.count) cameras")
                        .font(Theme.headlineFont)
                    Spacer()
                    if finder.isSearching { ProgressView() }
                }
                #if os(tvOS)
                VStack(spacing: Theme.Space.md) {
                    ForEach(finder.found) { camera in
                        FoundCameraRow(camera: camera, others: finder.found) { add(.camera(camera)) }
                    }
                }
                #else
                VStack(spacing: 0) {
                    ForEach(finder.found) { camera in
                        FoundCameraRow(camera: camera, others: finder.found) { add(.camera(camera)) }
                            .padding(.vertical, Theme.Space.md)
                            .padding(.horizontal, Theme.Space.lg)
                        if camera != finder.found.last { Divider().padding(.leading, Theme.Space.lg) }
                    }
                }
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.card * 1.5))
                #endif
                Text(Platform.usesFocus ? "Select a camera to sign in to it." : "Tap a camera to sign in to it.")
                    .font(Theme.footnoteFont)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: Theme.Space.md) {
            if searchedEmpty && !finder.isBlocked {
                Button { add(.address) } label: {
                    Text("Add by Address").font(.headline).frame(maxWidth: .infinity).padding(.vertical, Theme.Space.xs)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("emptyAddButton")
            } else {
                Button("Add by Address") { add(.address) }
                    .accessibilityIdentifier("emptyAddButton")
            }
            #if !os(tvOS)
            if !finder.isSearching || !finder.found.isEmpty { FindHelpLink() }
            #endif
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.lg)
        .frame(maxWidth: Theme.onboardingWidth)
        .frame(maxWidth: .infinity)
        #if !os(tvOS)
        .background(.bar)
        #endif
    }
}
