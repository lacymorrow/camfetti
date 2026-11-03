import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

extension Image {
    /// An image from encoded bytes (JPEG thumbnails), on either platform.
    init?(imageData: Data) {
        guard let image = PlatformImage(data: imageData) else { return nil }
        #if canImport(UIKit)
        self.init(uiImage: image)
        #else
        self.init(nsImage: image)
        #endif
    }
}

extension View {
    /// Small inline navigation title. A Mac sheet title is always inline.
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Lowercase, no autocorrect-style capitalization for addresses and usernames.
    func plainTextEntry(url: Bool = false) -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never).keyboardType(url ? .URL : .default)
        #else
        self
        #endif
    }
}

extension View {
    /// Hides system chrome (status bar, home indicator) while a camera is full screen.
    func immersive(_ hidden: Bool) -> some View {
        #if os(iOS)
        statusBarHidden(hidden).persistentSystemOverlays(hidden ? .hidden : .automatic)
        #else
        self
        #endif
    }
}

/// What this platform can do. Views ask these questions instead of asking which OS they run on.
enum Platform {
    /// Saving a snapshot: Photos on iPhone and Vision Pro, a save panel on the Mac. Apple TV has neither.
    static let canSaveSnapshot: Bool = {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }()
    /// Settings: iPhone, Vision Pro and Mac. Apple TV only adds and removes cameras.
    static let hasSettings: Bool = {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }()
    /// The remote and not a pointer or finger picks things: focus moves, a focused tile lifts.
    static let usesFocus: Bool = {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }()
}

extension View {
    /// A tile that opens something. Apple TV: a focusable button that lifts. Vision Pro: a
    /// pinch target with a hover highlight. Elsewhere a plain tap.
    @ViewBuilder func tileButton(perform: @escaping () -> Void) -> some View {
        #if os(tvOS)
        Button(action: perform) { self }.buttonStyle(TileFocusStyle())
        #elseif os(visionOS)
        hoverEffect(.highlight).onTapGesture(perform: perform)
        #else
        onTapGesture(perform: perform)
        #endif
    }

    /// The window's own backdrop: glass on Vision Pro, nothing elsewhere.
    @ViewBuilder func platformWindowBackground() -> some View {
        #if os(visionOS)
        glassBackgroundEffect()
        #else
        self
        #endif
    }

    /// Returns from a camera shown large. Esc on a keyboard, Menu or Back on the Apple TV remote.
    @ViewBuilder func backShortcut(perform: @escaping () -> Void) -> some View {
        #if os(tvOS)
        onExitCommand(perform: perform)
        #else
        background {
            Button("Back", action: perform)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        #endif
    }
}

#if os(tvOS)
/// The Apple TV focus look: a focused tile grows and casts a shadow.
struct TileFocusStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(focused ? Theme.focusScale : 1)
            .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: focused ? Theme.focusShadowRadius : 0, y: Theme.focusShadowRadius / 2)
            .animation(.easeOut(duration: Theme.Motion.quick), value: focused)
    }
}
#endif
