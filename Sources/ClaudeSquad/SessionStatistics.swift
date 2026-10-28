import Foundation

/// Aggregate usage statistics across all sessions found on disk.
struct SessionStatistics: Equatable {

    /// A single session that holds a record (e.g. the longest-running session).
    struct SessionHighlight: Equatable {
        let sessionId: String
        let projectName: String?
        let duration: TimeInterval
    }

    /// The highest number of sessions active at the same time.
    struct ConcurrencyPeak: Equatable {
        let count: Int
        let date: Date
    }

    /// Number of top-level sessions (subagents excluded).
    let totalSessions: Int

    /// Session with the most active time (idle gaps excluded).
    let longestSession: SessionHighlight?

    /// Session with the longest gap between two consecutive entries.
    let longestIdleGap: SessionHighlight?

    /// Most sessions active at the same time.
    let peakConcurrency: ConcurrencyPeak?

    /// Sessions started on the same calendar day as `now`.
    let sessionsStartedToday: Int

    /// Sessions started during the last 7 days (including today).
    let sessionsStartedLast7Days: Int

    /// Average number of sessions started per day on which at least one session started.
    let averageSessionsPerActiveDay: Double

    /// Longest run of consecutive calendar days with at least one new session.
    let longestDailyStreak: Int

    /// Token usage over all sessions and subagents.
    let tokenUsage: TokenUsage

    /// All badges, earned and not yet earned.
    let badges: [Badge]
}

/// Pure functions that turn `SessionActivityRecord`s into `SessionStatistics`.
enum StatisticsCalculator {

    static func calculate(records: [SessionActivityRecord], now: Date, calendar: Calendar) -> SessionStatistics {
        let sessions = records.filter { !$0.isSubagent }

        let longest = sessions
            .max { $0.activeDuration < $1.activeDuration }
            .map { SessionStatistics.SessionHighlight(sessionId: $0.sessionId, projectName: $0.projectName, duration: $0.activeDuration) }

        let longestIdle = sessions
            .filter { $0.longestIdleGap > 0 }
            .max { $0.longestIdleGap < $1.longestIdleGap }
            .map { SessionStatistics.SessionHighlight(sessionId: $0.sessionId, projectName: $0.projectName, duration: $0.longestIdleGap) }

        let peak = peakConcurrency(segments: sessions.flatMap(\.segments))

        let startDays = sessions.map { calendar.startOfDay(for: $0.start) }
        let today = calendar.startOfDay(for: now)
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let startedToday = startDays.filter { $0 == today }.count
        let startedLast7Days = startDays.filter { $0 >= sevenDaysAgo && $0 <= today }.count
        let distinctDays = Set(startDays)
        let averagePerDay = distinctDays.isEmpty ? 0 : Double(sessions.count) / Double(distinctDays.count)
        let streak = longestStreak(days: distinctDays, calendar: calendar)

        let tokens = records.reduce(TokenUsage.zero) { $0 + $1.tokenUsage }

        let badges = BadgeCatalog.evaluate(
            totalSessions: sessions.count,
            longestSessionDuration: longest?.duration ?? 0,
            peakConcurrency: peak?.count ?? 0,
            longestDailyStreak: streak,
            totalTokens: tokens.total
        )

        return SessionStatistics(
            totalSessions: sessions.count,
            longestSession: longest,
            longestIdleGap: longestIdle,
            peakConcurrency: peak,
            sessionsStartedToday: startedToday,
            sessionsStartedLast7Days: startedLast7Days,
            averageSessionsPerActiveDay: averagePerDay,
            longestDailyStreak: streak,
            tokenUsage: tokens,
            badges: badges
        )
    }

    /// Sweeps over segment boundaries to find the most overlapping segments.
    /// Zero-length segments are ignored. A segment that ends at the same
    /// instant another starts does not count as overlapping.
    static func peakConcurrency(segments: [DateInterval]) -> SessionStatistics.ConcurrencyPeak? {
        let events: [(Date, Int)] = segments
            .filter { $0.duration > 0 }
            .flatMap { segment -> [(Date, Int)] in [(segment.start, 1), (segment.end, -1)] }
            .sorted { (lhs: (Date, Int), rhs: (Date, Int)) -> Bool in
                if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
                // Process ends before starts at the same instant.
                return lhs.1 < rhs.1
            }

        var current = 0
        var best: SessionStatistics.ConcurrencyPeak?
        for (date, delta) in events {
            current += delta
            if current > (best?.count ?? 0) {
                best = SessionStatistics.ConcurrencyPeak(count: current, date: date)
            }
        }
        return best
    }

    /// Longest run of consecutive calendar days present in `days`.
    /// Each element must be a start-of-day date.
    static func longestStreak(days: Set<Date>, calendar: Calendar) -> Int {
        var longest = 0
        for day in days {
            // Only start counting at the first day of a run.
            if let previous = calendar.date(byAdding: .day, value: -1, to: day), days.contains(previous) {
                continue
            }
            var length = 1
            var cursor = day
            while let next = calendar.date(byAdding: .day, value: 1, to: cursor), days.contains(next) {
                length += 1
                cursor = next
            }
            longest = max(longest, length)
        }
        return longest
    }
}
