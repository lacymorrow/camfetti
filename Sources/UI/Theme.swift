import SwiftUI

/// CamFetti's look, in one place. Views read semantic names from `Theme` and never carry a
/// literal color, padding, radius, font size or duration. Platform differences live inside the
/// values here, so a view reads the same on iPhone and Mac.
enum Theme {
    // MARK: Color

    /// The one brand color: buttons, links, "on" states, the good news in a status line.
    static let accent = Palette.pink
    /// Reserved for confirmations that are not the brand moment.
    static let success = Palette.teal
    /// Something needs attention but nothing is broken.
    static let warning = Color.orange
    /// An error the person should fix.
    static let danger = Color.red
    /// Behind a camera picture while it loads.
    static let tileBackground = Palette.ink
    /// Behind a camera shown large.
    static let videoBackground = Color.black
    /// Text and controls drawn over video.
    static let onVideo = Color.white
    /// Dark gradient under a tile's name so white text stays readable on any picture.
    static let scrim = LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
    /// Status that is neither good nor bad: off, waiting, connecting.
    static let idle = Color.secondary
    static let secondaryText: HierarchicalShapeStyle = .secondary
    static let tertiaryText: HierarchicalShapeStyle = .tertiary
    /// Footnote color under a field: quiet, or red when something went wrong.
    static func noteColor(isError: Bool) -> Color { isError ? danger : idle }
    static let confetti = [Palette.pink, Palette.yellow, Palette.teal, Palette.blue]

    // MARK: Material

    /// Floating pills and banners over content.
    static let pillMaterial: Material = .thinMaterial
    /// Round buttons over video.
    static let controlMaterial: Material = .ultraThinMaterial

    // MARK: Spacing

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 6
        static let sm: CGFloat = 8
        static let snug: CGFloat = 10
        static let md: CGFloat = 12
        static let cozy: CGFloat = 14
        static let lg: CGFloat = 16
        static let roomy: CGFloat = 20
        static let xl: CGFloat = 24
        static let section: CGFloat = 28
    }

    // MARK: Shape and layout

    enum Radius {
        static let tile: CGFloat = 12
        static let card: CGFloat = 12
        static let popover: CGFloat = 12
    }

    /// Camera tiles are always 16:9.
    static let tileAspect: CGFloat = 16.0 / 9.0
    /// Smallest tile before the grid drops a column.
    static let tileMinWidth: CGFloat = {
        #if os(macOS)
        280
        #elseif os(tvOS)
        360
        #elseif os(visionOS)
        240
        #else
        150
        #endif
    }()
    static let tileMaxWidth: CGFloat = 640
    /// Gap between tiles.
    static let gridSpacing: CGFloat = {
        #if os(macOS) || os(visionOS)
        16
        #elseif os(tvOS)
        40
        #else
        8
        #endif
    }()
    /// Space between the grid and the window or screen edge.
    static let gridInset: CGFloat = {
        #if os(macOS) || os(visionOS)
        24
        #elseif os(tvOS)
        60
        #else
        8
        #endif
    }()
    static let shadowRadius: CGFloat = 4
    /// How much of the last thumbnail shows while a camera is still connecting.
    static let placeholderOpacityTile = 0.55
    static let placeholderOpacityLarge = 0.7
    /// Video runs edge to edge on iPhone. On the Mac it stops under the title bar, so the
    /// window keeps its title and traffic lights.
    static let videoSafeAreaEdges: Edge.Set = {
        #if os(macOS)
        [.bottom, .horizontal]
        #else
        .all
        #endif
    }()
    static let readableWidth: CGFloat = 320
    /// Width of explanatory text on an empty screen.
    static let emptyTextWidth: CGFloat = {
        #if os(tvOS)
        900
        #else
        480
        #endif
    }()
    static let controlSize: CGFloat = {
        #if os(tvOS)
        88
        #else
        46
        #endif
    }()
    /// A focused tile on Apple TV: how much it grows and how far its shadow reaches.
    static let focusScale: CGFloat = 1.08
    static let focusShadowRadius: CGFloat = 24
    static let heroSymbolSize: CGFloat = 64
    /// The symbol above a message on a small screen (a placeholder tile, an empty state).
    static let stateSymbolFont: Font = {
        #if os(watchOS)
        Font.title2
        #else
        Font.system(size: heroSymbolSize, weight: .regular)
        #endif
    }()
    /// A camera picture that is out of date: kept, but quieter than a fresh one.
    static let dimmedOpacity = 0.4
    /// Gap below a full-screen toast, clear of the control row.
    static let toastBottomInset: CGFloat = {
        #if os(tvOS)
        180
        #else
        96
        #endif
    }()
    static let popoverWidth: CGFloat = 290
    static let windowMin = CGSize(width: 520, height: 360)
    static let windowDefault: CGSize = {
        #if os(visionOS)
        CGSize(width: 1100, height: 700)
        #else
        CGSize(width: 960, height: 640)
        #endif
    }()
    /// A camera opened in its own Vision Pro window: 16:9.
    static let cameraWindowDefault = CGSize(width: 1280, height: 720)
    static let settingsSize = CGSize(width: 480, height: 420)

    // MARK: Type

    static let wordmarkSize: CGFloat = 34
    static let wordmarkHeroSize: CGFloat = {
        #if os(tvOS)
        96
        #else
        44
        #endif
    }()
    static let titleFont = Font.title2.bold()
    static let subtitleFont = Font.title3
    static let bodyFont = Font.body
    static let headlineFont = Font.headline
    static let tileLabelFont: Font = {
        #if os(tvOS)
        Font.title3.weight(.semibold)
        #else
        Font.caption.weight(.semibold)
        #endif
    }()
    static let tileDetailFont: Font = {
        #if os(tvOS)
        Font.callout
        #else
        Font.caption2
        #endif
    }()
    static let tileMessageFont: Font = {
        #if os(tvOS)
        Font.headline
        #else
        Font.caption.weight(.medium)
        #endif
    }()
    static let captionFont = Font.caption
    static let pillFont = Font.subheadline.weight(.semibold)
    static let bannerFont = Font.footnote.weight(.semibold)
    static let footnoteFont = Font.footnote
    static let statusLineFont = Font.callout
    static let controlGlyphFont: Font = {
        #if os(tvOS)
        Font.system(size: 36, weight: .semibold)
        #else
        Font.system(size: 17, weight: .semibold)
        #endif
    }()
    static let heroSymbolFont = Font.system(size: heroSymbolSize, weight: .regular)

    // MARK: Motion

    /// Durations in seconds. Pass them to `Theme.animation`, which returns nil under Reduce Motion.
    enum Motion {
        static let quick = 0.2
        static let relaxed = 0.3
    }

    static func animation(_ duration: Double, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: duration)
    }

    /// Waits and hold times, in seconds.
    enum Timing {
        /// Full-screen controls fade this long after the last touch.
        static let controlsHide: Double = {
            #if os(tvOS)
            10.0
            #else
            3.0
            #endif
        }()
        static let toastHold = 1.8
        /// Watch: pause between one snapshot landing and the next request.
        static let snapshotRefresh = 2.0
        /// Watch: pause before asking again after a failure.
        static let snapshotRetry = 5.0
        /// Watch: give up on the iPhone after this long.
        static let requestTimeout = 15.0
        /// Watch: how often "2 min ago" is recomputed while it is on screen.
        static let ageRefresh = 30.0
        /// A silent camera gets a plain message after this long.
        static let cameraSilent = 8.0
        static let confettiRun = 2.6
    }

    // MARK: Base palette

    /// Raw colors. Only this file reads them.
    private enum Palette {
        static let pink = Color(red: 1.00, green: 0.31, blue: 0.47)
        static let yellow = Color(red: 1.00, green: 0.79, blue: 0.24)
        static let teal = Color(red: 0.18, green: 0.77, blue: 0.71)
        static let blue = Color(red: 0.23, green: 0.53, blue: 1.00)
        static let ink = Color(red: 0.07, green: 0.07, blue: 0.10)
    }
}

struct Wordmark: View {
    var size: CGFloat = Theme.wordmarkSize
    var body: some View {
        (Text("Cam").foregroundStyle(.primary) + Text("Fetti").foregroundStyle(Theme.accent))
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .accessibilityLabel("CamFetti")
    }
}

/// One short burst of confetti. Skipped under Reduce Motion.
struct ConfettiBurst: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    private let pieces: [Piece] = (0..<70).map { _ in Piece() }

    struct Piece {
        let x = Double.random(in: 0...1)
        let delay = Double.random(in: 0...0.35)
        let speed = Double.random(in: 0.55...1.0)
        let drift = Double.random(in: -40...40)
        let spin = Double.random(in: 2...9)
        let color = Theme.confetti.randomElement()!
        let size = CGSize(width: Double.random(in: 6...10), height: Double.random(in: 8...14))
    }

    var body: some View {
        if !reduceMotion {
            TimelineView(.animation) { timeline in
                Canvas { ctx, size in
                    let t = timeline.date.timeIntervalSince(start)
                    for p in pieces {
                        let local = t - p.delay
                        guard local > 0 else { continue }
                        let y = -20 + local * p.speed * size.height * 0.75
                        let x = p.x * size.width + sin(local * 2.5) * p.drift
                        var c = ctx
                        c.opacity = max(0, 1 - (local - 1.6) / 0.6)
                        c.translateBy(x: x, y: y)
                        c.rotate(by: .radians(local * p.spin))
                        c.fill(Path(CGRect(origin: CGPoint(x: -p.size.width / 2, y: -p.size.height / 2), size: p.size)), with: .color(p.color))
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
