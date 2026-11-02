import SwiftUI

#if os(iOS)
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
        #if os(iOS)
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
