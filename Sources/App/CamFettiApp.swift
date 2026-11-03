import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct CamFettiApp: App {
    @State private var model: AppModel
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    #endif

    init() {
        if ProcessInfo.processInfo.arguments.contains("-resetForTesting") {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("cameras.json"))
        }
        AppModel.configureAudioSession()
        #if os(iOS)
        WatchLink.shared.activate()
        #endif
        #if AWAY
        AwayConfig.installFromLaunchArguments()
        #endif
        let model = AppModel()
        #if DEBUG
        Self.seedDemoCameras(into: model.store)
        Self.seedRealCameras(into: model.store)
        #endif
        _model = State(initialValue: model)
    }

    #if DEBUG
    /// `-seedDemo <host>` fills the grid with the test rig's cameras, for screenshots.
    private static func seedDemoCameras(into store: CameraStore) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-seedDemo"), i + 1 < args.count, store.cameras.isEmpty else { return }
        let host = args[i + 1]
        let demo: [(String, String, String?)] = [("Front Porch", "ch0", "ch1"), ("Driveway", "hevc", nil),
                                                 ("Back Yard", "ch1", nil), ("Garage", "ch0", "ch1")]
        for (name, main, sub) in demo {
            let cam = Camera(name: name, kind: .rtsp, host: host, mainURL: "rtsp://\(host):8554/\(main)",
                             subURL: sub.map { "rtsp://\(host):8554/\($0)" }, username: "thingino")
            store.add(cam, password: "thingino")
        }
    }

    /// `-seedReal <base64 json>` runs the real add flow without typing, for demos on real cameras.
    /// Items: {"name","address","user","pass"}. Debug builds only; never in a store build.
    private static func seedRealCameras(into store: CameraStore) {
        struct Item: Decodable { let name: String; let address: String; let user: String; let pass: String }
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-seedReal"), i + 1 < args.count,
              let data = Data(base64Encoded: args[i + 1]),
              let items = try? JSONDecoder().decode([Item].self, from: data) else { return }
        Task { @MainActor in
            for item in items where !store.contains(host: item.address) {
                let input = CameraProber.Input(address: item.address, username: item.user, password: item.pass, name: item.name)
                if let result = try? await CameraProber().probe(input) {
                    store.add(result.camera, password: result.password, apiKey: result.apiKey)
                } else {
                    NSLog("seedReal: could not add %@", item.name)
                }
            }
        }
    }
    #endif

    var body: some Scene {
        #if os(iOS) || os(tvOS) || os(visionOS)
        WindowGroup {
            CamerasView()
            .environment(model)
            .tint(Theme.accent)
            .platformWindowBackground()
        }
        #if os(visionOS)
        .defaultSize(width: Theme.windowDefault.width, height: Theme.windowDefault.height)
        #endif
        #if os(visionOS)
        // A camera opened from the grid gets its own large window.
        CameraWindowScene(model: model)
        #endif
        #else
        Window("CamFetti", id: "main") {
            Group {
                #if AWAY
                if ProcessInfo.processInfo.arguments.contains("-awayMenuPreview") {
                    AwayMenuPreview()
                } else {
                    CamerasView()
                }
                #else
                CamerasView()
                #endif
            }
            .background(MainWindowHook())
            .frame(minWidth: Theme.windowMin.width, minHeight: Theme.windowMin.height)
            .environment(model)
            .tint(Theme.accent)
        }
        .defaultSize(width: Theme.windowDefault.width, height: Theme.windowDefault.height)
        Settings {
            SettingsView()
                .environment(model)
                .frame(width: Theme.settingsSize.width, height: Theme.settingsSize.height)
                .tint(Theme.accent)
        }
        #if AWAY
        AwayMenuScene()
        #endif
        #endif
    }
}
