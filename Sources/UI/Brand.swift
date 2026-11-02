import SwiftUI

/// CamFetti's look: quiet system UI, a little confetti where it counts.
enum Brand {
    static let pink = Color(red: 1.00, green: 0.31, blue: 0.47)
    static let yellow = Color(red: 1.00, green: 0.79, blue: 0.24)
    static let teal = Color(red: 0.18, green: 0.77, blue: 0.71)
    static let blue = Color(red: 0.23, green: 0.53, blue: 1.00)
    static let ink = Color(red: 0.07, green: 0.07, blue: 0.10)
    static let confetti = [pink, yellow, teal, blue]
}

struct Wordmark: View {
    var size: CGFloat = 34
    var body: some View {
        (Text("Cam").foregroundStyle(.primary) + Text("Fetti").foregroundStyle(Brand.pink))
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
        let color = Brand.confetti.randomElement()!
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
