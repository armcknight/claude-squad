import Foundation

/// An achievement earned by reaching a usage milestone.
struct Badge: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let iconName: String

    /// Current value of the measured statistic.
    let currentValue: Double

    /// Value required to earn the badge.
    let threshold: Double

    var isEarned: Bool {
        currentValue >= threshold
    }

    /// Progress toward the badge, clamped to 0...1.
    var progress: Double {
        guard threshold > 0 else { return 1 }
        return min(max(currentValue / threshold, 0), 1)
    }
}

/// Definitions of all badges and the logic that evaluates them.
enum BadgeCatalog {

    static func evaluate(
        totalSessions: Int,
        longestSessionDuration: TimeInterval,
        peakConcurrency: Int,
        longestDailyStreak: Int,
        totalTokens: Int
    ) -> [Badge] {
        let sessions = Double(totalSessions)
        let hours = longestSessionDuration / 3600
        let concurrency = Double(peakConcurrency)
        let streak = Double(longestDailyStreak)
        let tokens = Double(totalTokens)

        return [
            Badge(id: "first-session", title: "First Contact", detail: "Start your first Claude session", iconName: "sparkles", currentValue: sessions, threshold: 1),
            Badge(id: "ten-sessions", title: "Regular", detail: "Start 10 sessions", iconName: "person.fill.checkmark", currentValue: sessions, threshold: 10),
            Badge(id: "hundred-sessions", title: "Centurion", detail: "Start 100 sessions", iconName: "rosette", currentValue: sessions, threshold: 100),
            Badge(id: "marathon", title: "Marathon", detail: "Keep one session active for 4 hours", iconName: "figure.run", currentValue: hours, threshold: 4),
            Badge(id: "multitasker", title: "Multitasker", detail: "Run 3 sessions at the same time", iconName: "square.stack.3d.up.fill", currentValue: concurrency, threshold: 3),
            Badge(id: "squad-leader", title: "Squad Leader", detail: "Run 5 sessions at the same time", iconName: "person.3.fill", currentValue: concurrency, threshold: 5),
            Badge(id: "streak-week", title: "On a Roll", detail: "Start a session on 7 consecutive days", iconName: "flame.fill", currentValue: streak, threshold: 7),
            Badge(id: "million-tokens", title: "Token Millionaire", detail: "Use 1 million tokens", iconName: "dollarsign.circle.fill", currentValue: tokens, threshold: 1_000_000),
            Badge(id: "billion-tokens", title: "Token Billionaire", detail: "Use 1 billion tokens", iconName: "crown.fill", currentValue: tokens, threshold: 1_000_000_000),
        ]
    }
}
