import Foundation

/// The operational state of a Claude session.
enum SessionStatus: Equatable {
    /// Claude is actively processing (generating output or executing a tool).
    case running
    /// Finished a turn, idle at the prompt.
    case waitingIdle(since: Date)
    /// Asked AskUserQuestion, awaiting a response.
    case waitingForQuestion(since: Date, question: String?)
    /// Process was killed mid-work (user hit Esc / Ctrl-C).
    case interrupted(lastActivity: Date)
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
        case .interrupted, .inactive: return false
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

    /// Section title for grouping in the UI.
    var sectionTitle: String {
        switch self {
        case .waitingForQuestion: return "Needs Input"
        case .waitingIdle: return "Idle"
        case .running: return "Running"
        case .interrupted: return "Interrupted"
        case .inactive: return "Inactive"
        }
    }

    /// SF Symbol name for this status.
    var iconName: String {
        switch self {
        case .running: return "bolt.circle.fill"
        case .waitingForQuestion: return "questionmark.circle.fill"
        case .waitingIdle: return "pause.circle.fill"
        case .interrupted: return "exclamationmark.octagon.fill"
        case .inactive: return "moon.circle.fill"
        }
    }


    /// Time since the status started, for display.
    var elapsed: TimeInterval {
        switch self {
        case .running: return 0
        case .waitingIdle(let since), .waitingForQuestion(let since, _):
            return Date().timeIntervalSince(since)
        case .interrupted(let d), .inactive(let d):
            return Date().timeIntervalSince(d)
        }
    }

    /// Sort priority: lower = sorts first.
    /// waitingForQuestion > waitingIdle > running > interrupted > inactive
    var sortPriority: Int {
        switch self {
        case .waitingForQuestion: return 0
        case .waitingIdle: return 1
        case .running: return 2
        case .interrupted: return 3
        case .inactive: return 4
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

    /// Abbreviated path: `~/C/o/g/r/p/project-name`
    /// First letter of each intermediate directory, full last component.
    var displayName: String {
        abbreviatePath(projectPath)
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
            && lhs.status == rhs.status
            && lhs.taskSummary == rhs.taskSummary
            && lhs.processPID == rhs.processPID
            && lhs.gitBranch == rhs.gitBranch
    }
}

extension ClaudeSession: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Path abbreviation

/// Abbreviates an absolute path: first letter of each intermediate directory,
/// full last component. Home directory becomes `~`.
/// e.g. `/Users/me/Code/org/repos/project` → `~/C/o/r/project`
func abbreviatePath(_ path: String) -> String {
    var components = (path as NSString).pathComponents
    // Replace /Users/<username> with ~
    let home = NSHomeDirectory()
    if path.hasPrefix(home) {
        let homeComponents = (home as NSString).pathComponents
        components = Array(components.dropFirst(homeComponents.count))
        components.insert("~", at: 0)
    }
    guard components.count > 2 else { return path }
    let last = components.removeLast()
    let abbreviated = components.map { component in
        if component == "~" || component == "/" { return component }
        return String(component.prefix(1))
    }
    return abbreviated.joined(separator: "/")
        .replacingOccurrences(of: "//", with: "/") + "/" + last
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
