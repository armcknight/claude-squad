import Foundation

/// Token counts reported by the Anthropic API in assistant message `usage` blocks.
struct TokenUsage: Equatable {
    var input: Int = 0
    var output: Int = 0
    var cacheCreation: Int = 0
    var cacheRead: Int = 0

    static let zero = TokenUsage()

    /// Sum of all token categories.
    var total: Int {
        input + output + cacheCreation + cacheRead
    }

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheCreation: lhs.cacheCreation + rhs.cacheCreation,
            cacheRead: lhs.cacheRead + rhs.cacheRead
        )
    }

    static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
        lhs = lhs + rhs
    }
}

/// Historical activity extracted from a single session or subagent JSONL file.
/// This is the input to `StatisticsCalculator`.
struct SessionActivityRecord: Equatable {
    /// Session UUID (or subagent id) from the JSONL.
    let sessionId: String

    /// Project working directory, if present in the JSONL.
    let projectPath: String?

    /// True when this record comes from a `subagents/agent-*.jsonl` file.
    /// Subagent records contribute token usage only, not session counts.
    let isSubagent: Bool

    /// Timestamp of the first entry in the file.
    let start: Date

    /// Timestamp of the last entry in the file.
    let end: Date

    /// Periods of continuous activity. A gap between consecutive entries that
    /// is longer than `SessionActivityRecord.idleThreshold` splits a segment.
    let segments: [DateInterval]

    /// Longest gap between two consecutive entries.
    let longestIdleGap: TimeInterval

    /// Token usage summed over all unique assistant messages.
    let tokenUsage: TokenUsage

    /// Gaps between entries longer than this count as idle time and split activity segments.
    static let idleThreshold: TimeInterval = 10 * 60

    /// Sum of all activity segment durations (idle gaps excluded).
    var activeDuration: TimeInterval {
        segments.reduce(0) { $0 + $1.duration }
    }

    /// Last path component of `projectPath`, if any.
    var projectName: String? {
        projectPath.map { ($0 as NSString).lastPathComponent }
    }
}

extension SessionActivityRecord {
    /// Builds a record from the timestamps of a file's entries. Returns nil
    /// when there are no timestamps.
    init?(
        sessionId: String,
        projectPath: String?,
        isSubagent: Bool,
        timestamps: [Date],
        tokenUsage: TokenUsage,
        idleThreshold: TimeInterval = SessionActivityRecord.idleThreshold
    ) {
        let sorted = timestamps.sorted()
        guard let first = sorted.first, let last = sorted.last else { return nil }

        var segments: [DateInterval] = []
        var segmentStart = first
        var previous = first
        var longestGap: TimeInterval = 0
        for timestamp in sorted.dropFirst() {
            let gap = timestamp.timeIntervalSince(previous)
            longestGap = max(longestGap, gap)
            if gap > idleThreshold {
                segments.append(DateInterval(start: segmentStart, end: previous))
                segmentStart = timestamp
            }
            previous = timestamp
        }
        segments.append(DateInterval(start: segmentStart, end: previous))

        self.init(
            sessionId: sessionId,
            projectPath: projectPath,
            isSubagent: isSubagent,
            start: first,
            end: last,
            segments: segments,
            longestIdleGap: longestGap,
            tokenUsage: tokenUsage
        )
    }
}
