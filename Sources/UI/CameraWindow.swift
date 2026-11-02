#if os(visionOS)
import SwiftUI

/// A camera opened large on Vision Pro: its own window beside the grid.
struct CameraWindow: View {
    static let windowID = "camera"
    @Environment(AppModel.self) private var model
    let id: UUID?

    var body: some View {
        if let camera = model.store.cameras.first(where: { $0.id == id }) {
            CameraScreen(camera: camera)
                .background(Theme.videoBackground)
                // Closing the window by hand returns the grid to normal.
                .onDisappear { if model.focused?.id == camera.id { model.focused = nil } }
        }
    }
}

/// The scene behind `CameraWindow`.
struct CameraWindowScene: Scene {
    let model: AppModel

    var body: some Scene {
        WindowGroup("Camera", id: CameraWindow.windowID, for: UUID.self) { $id in
            CameraWindow(id: id)
                .environment(model)
                .tint(Theme.accent)
        }
        .defaultSize(width: Theme.cameraWindowDefault.width, height: Theme.cameraWindowDefault.height)
    }
}

/// Opens the camera window when a camera is picked and closes it when the pick is cleared.
struct CameraWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Binding var item: Camera?

    func body(content: Content) -> some View {
        content.onChange(of: item) { old, camera in
            if let camera {
                openWindow(id: CameraWindow.windowID, value: camera.id)
            } else if let old {
                dismissWindow(id: CameraWindow.windowID, value: old.id)
            }
        }
    }
}
#endif
