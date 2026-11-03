import Foundation

/// "2 min ago" for the dimmed picture on the watch. Shared by the watch app and the tests.
enum AgeText {
    static func text(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "Just now"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86_400: return "\(seconds / 3600) hr ago"
        default: return "\(seconds / 86_400) d ago"
        }
    }
}
