import Foundation

/// The operational state of a Claude session.
enum SessionStatus: Equatable {
    /// Claude is actively processing (generating output or executing a tool).
    case running
    /// Finished a turn, idle at the prompt.
    case waitingIdle(since: Date)
    /// Asked AskUserQuestion, awaiting a response.
    case waitingForQuestion(since: Date, question: String?)
    /// No running process; session file exists on disk.
    case inactive(lastActivity: Date)

    var isWaiting: Bool {
        switch self {
        case .waitingIdle, .waitingForQuestion: return true
        default: return false
        }
    }

    var isActive: Bool {
        switch self {
        case .running, .waitingIdle, .waitingForQuestion: return true
        case .inactive: return false
        }
    }

    /// Time the session has been waiting (0 when running or inactive).
    var waitingDuration: TimeInterval {
        switch self {
        case .waitingIdle(let since), .waitingForQuestion(let since, _):
            return Date().timeIntervalSince(since)
        default:
            return 0
        }
    }

    /// Sort priority: lower = sorts first.
    /// waitingForQuestion > waitingIdle > running > inactive
    var sortPriority: Int {
        switch self {
        case .waitingForQuestion: return 0
        case .waitingIdle: return 1
        case .running: return 2
        case .inactive: return 3
        }
    }
}

/// Summary of task/todo progress for a session.
struct TaskSummary: Equatable {
    let total: Int
    let completed: Int
    let inProgress: Int
    let pending: Int
}

/// A single Claude CLI session detected from on-disk data and process inspection.
struct ClaudeSession: Identifiable {
    /// The session UUID from the JSONL conversation log.
    let id: String

    /// Absolute path to the project directory.
    let projectPath: String

    /// Just the last path component of projectPath.
    var projectName: String {
        (projectPath as NSString).lastPathComponent
    }

    /// Current git branch, if detected.
    var gitBranch: String?

    /// The claude-squad slug (human-friendly short name), if available.
    var slug: String?

    /// Best display name: slug if available, otherwise projectName.
    var displayName: String {
        slug ?? projectName
    }

    /// Current state of the session.
    var status: SessionStatus

    /// PID of the running claude process, if any.
    var processPID: Int32?

    /// Task progress summary, if tasks/todos exist.
    var taskSummary: TaskSummary?

    /// Modification time of the JSONL file.
    var lastModified: Date

    // MARK: - Sorting

    /// Sort key: by status priority, then by waiting duration (longest first).
    var sortKey: (Int, Double) {
        (status.sortPriority, -status.waitingDuration)
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

extension ClaudeSession: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Duration formatting

extension TimeInterval {
    /// Formats a duration in seconds into a human-readable string (e.g. "3m 12s", "1h 5m").
    var formattedDuration: String {
        let seconds = Int(self)
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if minutes < 60 { return "\(minutes)m \(remainingSeconds)s" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return "\(hours)h \(remainingMinutes)m"
    }
}
