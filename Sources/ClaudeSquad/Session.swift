import Foundation

/// Git repository status information.
struct GitStatus: Equatable {
    /// Whether the working directory has uncommitted changes (modified, added, deleted files).
    let isDirty: Bool
    
    /// Number of commits ahead of the remote tracking branch (unpushed commits).
    let commitsAhead: Int
    
    /// Number of commits behind the remote tracking branch (commits available to pull).
    let commitsBehind: Int
    
    /// Whether the repository has a configured remote tracking branch.
    let hasRemote: Bool
    
    /// Returns a human-readable summary of the git status.
    var summary: String {
        var parts: [String] = []
        
        if isDirty {
            parts.append("uncommitted changes")
        }
        
        if commitsAhead > 0 {
            parts.append("\(commitsAhead) unpushed")
        }
        
        if commitsBehind > 0 {
            parts.append("\(commitsBehind) to pull")
        }
        
        if parts.isEmpty {
            return hasRemote ? "up to date" : "no remote"
        }
        
        return parts.joined(separator: ", ")
    }
    
    /// Returns true if there are any notable changes (dirty, ahead, or behind).
    var hasChanges: Bool {
        isDirty || commitsAhead > 0 || commitsBehind > 0
    }
}

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
    /// waitingForQuestion > interrupted > waitingIdle > running > inactive
    /// (Interrupted ranks above idle because an abandoned session usually
    /// demands more attention than a normally-idle one. This same ordering
    /// is used to roll a session's status up from its subagents — see
    /// `ClaudeSession.status` vs `ownStatus`.)
    var sortPriority: Int {
        switch self {
        case .waitingForQuestion: return 0
        case .interrupted: return 1
        case .waitingIdle: return 2
        case .running: return 3
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

/// A single task item with its full content.
struct TaskItem: Identifiable, Equatable {
    let id: String
    let subject: String
    let description: String?
    let status: String
    let activeForm: String?
}

/// A single message in the conversation transcript.
struct TranscriptMessage: Identifiable, Equatable {
    let id: String  // uuid from JSONL
    let role: String // "user" or "assistant"
    let text: String
    let timestamp: Date?
    let toolCalls: [ToolCallSummary]
    /// Parsed answers to AskUserQuestion tool_result blocks on this user message.
    var askAnswers: [AskUserAnswer] = []
}

/// Brief summary of a tool call for display in the transcript.
struct ToolCallSummary: Equatable {
    let name: String
    let summary: String?
    /// Structured AskUserQuestion content (questions + options), when applicable.
    var askQuestions: [AskUserQuestionContent] = []
}

/// A single question posed by AskUserQuestion, with its multiple-choice options.
struct AskUserQuestionContent: Equatable {
    let question: String
    let header: String?
    let multiSelect: Bool
    let options: [Option]

    struct Option: Equatable {
        let label: String
        let description: String?
    }
}

/// The user's parsed response to an AskUserQuestion prompt.
struct AskUserAnswer: Equatable {
    let question: String
    let selection: String
    let notes: String?
    let preview: String?
}

/// A subagent spawned from a parent Claude session. Lives in
/// `<parentJSONL_without_ext>/subagents/agent-<agentId>.jsonl`. Subagents
/// inherit the parent's project path and git branch (per CLA-7) so those
/// fields are omitted here.
struct Subagent: Identifiable, Equatable, Hashable {
    /// The subagent's `agentId` from the JSONL (used as `id`).
    let id: String

    /// Human-friendly short name from the JSONL `slug` field.
    var slug: String?

    /// Subagent type from the `.meta.json` `agentType` field (e.g. "Explore", "general-purpose").
    var subagentType: String?

    /// Short description of the subagent's task from the `.meta.json` `description` field.
    var taskDescription: String?

    /// Full launch prompt (the first user message in the subagent JSONL).
    var launchPrompt: String?

    /// Current state of the subagent.
    var status: SessionStatus

    /// Conversation transcript messages.
    var transcript: [TranscriptMessage] = []

    /// Path to this subagent's JSONL file.
    var jsonlPath: String

    /// Modification time of the JSONL file.
    var lastModified: Date

    /// Subagents spawned by this subagent (recursive).
    var subagents: [Subagent] = []

    /// Display label: `subagentType · slug`, falling back to whichever is available.
    var displayLabel: String {
        switch (subagentType, slug) {
        case let (type?, slug?): return "\(type) · \(slug)"
        case let (type?, nil): return type
        case let (nil, slug?): return slug
        case (nil, nil): return String(id.prefix(8))
        }
    }

    /// Stable transcript loader key (distinct from parent's sessionId).
    var transcriptKey: String { "subagent:\(id)" }

    static func == (lhs: Subagent, rhs: Subagent) -> Bool {
        lhs.id == rhs.id
            && lhs.status == rhs.status
            && lhs.subagents == rhs.subagents
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension Subagent {
    /// Returns all subagents in the subtree rooted at this node, including self.
    var flattenedSelfAndDescendants: [Subagent] {
        [self] + subagents.flatMap { $0.flattenedSelfAndDescendants }
    }

    /// Depth-first search for a subagent with the given id within this subtree.
    func findDescendant(id: String) -> Subagent? {
        if self.id == id { return self }
        for child in subagents {
            if let found = child.findDescendant(id: id) { return found }
        }
        return nil
    }
}

/// Identifies the active selection in the sidebar. Used as a SwiftUI `List`
/// selection value and resolved to a concrete session or subagent via
/// `Array<ClaudeSession>.find(_:)` below.
enum SidebarSelection: Hashable {
    case session(sessionId: String)
    case subagent(agentId: String)
}

/// Resolved selection target: a session, or a subagent with its parent.
enum SidebarSelectionTarget {
    case session(ClaudeSession)
    case subagent(parent: ClaudeSession, subagent: Subagent)
}

extension Array where Element == ClaudeSession {
    /// Resolves a `SidebarSelection` into a concrete session or subagent within this
    /// array. Returns nil if the referenced item no longer exists (e.g. subagent
    /// finished and parent was rewritten).
    func find(_ selection: SidebarSelection) -> SidebarSelectionTarget? {
        switch selection {
        case .session(let id):
            return first(where: { $0.id == id }).map(SidebarSelectionTarget.session)
        case .subagent(let agentId):
            for session in self {
                for sub in session.subagents {
                    if let found = sub.findDescendant(id: agentId) {
                        return .subagent(parent: session, subagent: found)
                    }
                }
            }
            return nil
        }
    }
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

    /// Git repository status information.
    var gitStatus: GitStatus?

    /// The claude-squad slug (human-friendly short name), if available.
    var slug: String?

    /// Abbreviated path: `~/C/o/g/r/p/project-name`
    /// First letter of each intermediate directory, full last component.
    var displayName: String {
        abbreviatePath(projectPath)
    }

    /// Status read directly from this session's JSONL tail.
    var ownStatus: SessionStatus

    /// Effective status used for sidebar grouping/sorting. Computed as the
    /// highest-priority status among (ownStatus, all descendant subagents),
    /// so that a session whose deepest subagent needs input bubbles up to
    /// the "Needs Input" section. Defaults to `ownStatus` until rollup runs.
    var status: SessionStatus

    /// Task progress summary, if tasks/todos exist.
    var taskSummary: TaskSummary?

    /// Full task items with text content.
    var taskItems: [TaskItem] = []

    /// Conversation transcript messages.
    var transcript: [TranscriptMessage] = []

    /// GitHub PR URL, if detected in the conversation.
    var pullRequestURL: String?

    /// Path to the JSONL file (for lazy loading).
    var jsonlPath: String?

    /// Modification time of the JSONL file.
    var lastModified: Date

    /// Subagents spawned from this session, in launch order.
    var subagents: [Subagent] = []

    /// Most recent Claude Code permission mode recorded in the JSONL, if any.
    var permissionMode: PermissionMode?

    /// Stable transcript loader key.
    var transcriptKey: String { "session:\(id)" }

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
            && lhs.ownStatus == rhs.ownStatus
            && lhs.taskSummary == rhs.taskSummary
            && lhs.gitBranch == rhs.gitBranch
            && lhs.gitStatus == rhs.gitStatus
            && lhs.subagents == rhs.subagents
            && lhs.permissionMode == rhs.permissionMode
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
