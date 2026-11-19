import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Where the add sheet opens: the list, the address form, or straight to signing in to a camera.
enum AddStart: Identifiable, Hashable {
    case pick
    case address
    case camera(FoundCamera)

    var id: String {
        switch self {
        case .pick: "pick"
        case .address: "address"
        case .camera(let camera): "camera-\(camera.host)"
        }
    }
}

enum FindHelp {
    /// What to try when a camera doesn't show up. Kept on the site so it can change without a release.
    static let url = URL(string: "https://camfetti.lacy.sh/support#find")!

    /// The app's Local Network switch, or the closest Settings page the platform can open.
    static var settingsURL: URL? {
        #if os(macOS)
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
        #else
        URL(string: UIApplication.openSettingsURLString)
        #endif
    }
}

/// One camera seen on the Wi-Fi. Cameras already in the app stay on the list, checked, so a
/// finished search never looks like a failed one.
struct FoundCameraRow: View {
    let camera: FoundCamera
    let others: [FoundCamera]
    /// The name it was added under, when it's already in the app.
    var addedAs: String? = nil
    let action: () -> Void

    private var added: Bool { addedAs != nil }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: "web.camera")
                    .font(.title3)
                    .foregroundStyle(added ? AnyShapeStyle(Theme.tertiaryText) : AnyShapeStyle(Theme.accent))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(addedAs ?? camera.title).foregroundStyle(added ? AnyShapeStyle(Theme.secondaryText) : AnyShapeStyle(.primary))
                    if let detail = added ? "Added" : camera.detail(among: others) {
                        Text(detail).font(Theme.captionFont).foregroundStyle(Theme.secondaryText)
                    }
                }
                Spacer()
                Image(systemName: added ? "checkmark" : "chevron.right")
                    .font(Theme.tileLabelFont)
                    .foregroundStyle(added ? AnyShapeStyle(Theme.success) : AnyShapeStyle(Theme.tertiaryText))
            }
            .contentShape(Rectangle())
        }
        #if os(tvOS)
        .buttonStyle(RowFocusStyle())
        #else
        .buttonStyle(.plain)
        #endif
        .disabled(added)
        .accessibilityIdentifier("found-\(camera.host)")
        .accessibilityValue(added ? "Added" : "")
    }
}

/// Shown when iOS won't let CamFetti look on the Wi-Fi. The fix is one switch in Settings.
struct LocalNetworkNote: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            Label("CamFetti can't look on your Wi-Fi", systemImage: "wifi.exclamationmark")
                .font(Theme.headlineFont)
            Text("Turn on Local Network for CamFetti in Settings, and it will find your cameras.")
                .font(Theme.footnoteFont)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            if let url = FindHelp.settingsURL {
                Button("Open Settings") { openURL(url) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("openSettingsButton")
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The small "can't find it?" link under every list of found cameras.
struct FindHelpLink: View {
    var body: some View {
        Link(destination: FindHelp.url) {
            Label("Camera not showing up?", systemImage: "questionmark.circle")
                .font(Theme.footnoteFont)
        }
        .accessibilityIdentifier("findHelpLink")
    }
}

#if os(tvOS)
/// A found camera on Apple TV: a quiet platter that brightens and lifts when the remote lands
/// on it, with the text staying readable instead of taking the accent color.
struct RowFocusStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, Theme.Space.md)
            .background(.white.opacity(focused ? 0.22 : 0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.card * 1.5))
            .scaleEffect(focused ? 1.03 : 1)
            .animation(.easeOut(duration: Theme.Motion.quick), value: focused)
    }
}
#endif
