import Foundation

/// The operational state of a Claude session inside a tmux pane.
enum SessionStatus: Equatable {
    /// Claude is actively thinking / generating output.
    case running
    /// Claude has finished a turn and is waiting for the user to type.
    case waitingForInput(since: Date)

    var isWaiting: Bool {
        if case .waitingForInput = self { return true }
        return false
    }

    /// Time the session has been idle (0 when running).
    var waitingDuration: TimeInterval {
        if case .waitingForInput(let since) = self {
            return Date().timeIntervalSince(since)
        }
        return 0
    }
}

/// A single Claude CLI session detected inside a tmux session.
struct ClaudeSession: Identifiable {
    /// The tmux session name is used as the unique identifier.
    let id: String

    /// Human-readable label; same as `id` unless the user renames it.
    var displayName: String { id }

    /// Current state of the Claude process inside this tmux session.
    var status: SessionStatus

    /// The TTY device path of the tmux pane (e.g. "/dev/ttys004").
    /// Used to locate the matching iTerm2 window.
    var paneTTY: String?

    // MARK: - Sorting

    /// Sessions waiting for input sort above running sessions.
    /// Among waiting sessions, the one that has waited *longest* sorts first.
    var sortKey: (Int, Double) {
        switch status {
        case .waitingForInput:
            // Negate so that longer waits come first (ascending sort).
            return (0, -status.waitingDuration)
        case .running:
            return (1, 0)
        }
    }
}

extension ClaudeSession: Comparable {
    static func < (lhs: ClaudeSession, rhs: ClaudeSession) -> Bool {
        if lhs.sortKey.0 != rhs.sortKey.0 { return lhs.sortKey.0 < rhs.sortKey.0 }
        return lhs.sortKey.1 < rhs.sortKey.1
    }

    static func == (lhs: ClaudeSession, rhs: ClaudeSession) -> Bool {
        lhs.id == rhs.id
    }
}
