// Example: How Git Status Data Flows Through the App

// 1. SessionMonitor polls for updates
//    └─> ClaudeSessionDetector.detectSessions()

// 2. For each session JSONL file:
//    ClaudeSessionDetector.analyzeSession()
//        ├─> Reads session metadata (cwd, sessionId, branch)
//        ├─> GitHelper.readBranch(projectPath)  // "main"
//        └─> GitHelper.readStatus(projectPath)
//            ├─> Runs: git status --porcelain
//            │   Output: " M file1.swift\n?? file2.swift"
//            │   Result: isDirty = true
//            │
//            ├─> Runs: git rev-parse --abbrev-ref main@{upstream}
//            │   Output: "origin/main"
//            │   Result: hasRemote = true
//            │
//            ├─> Runs: git rev-list --count origin/main..HEAD
//            │   Output: "3"
//            │   Result: commitsAhead = 3
//            │
//            └─> Runs: git rev-list --count HEAD..origin/main
//                Output: "1"
//                Result: commitsBehind = 1

// 3. Creates ClaudeSession with GitStatus:
let exampleGitStatus = GitStatus(
    isDirty: true,
    commitsAhead: 3,
    commitsBehind: 1,
    hasRemote: true
)

let exampleSession = ClaudeSession(
    id: "abc-123",
    projectPath: "/Users/dev/Code/my-project",
    gitBranch: "feature/new-thing",
    gitStatus: exampleGitStatus,  // ← New!
    slug: nil,
    status: .waitingIdle(since: Date()),
    taskSummary: nil,
    lastModified: Date()
)

// 4. SessionListView renders the session
//    └─> SessionRowView displays:
//        Line 1: "~/C/my-project"
//        Line 2: "feature/new-thing  •  ↑3  ↓1"
//                                   │   │   └─ 1 commit to pull (green)
//                                   │   └───── 3 unpushed commits (blue)
//                                   └───────── Dirty working dir (orange)

// 5. User sees at a glance:
//    "This session has uncommitted changes, 3 commits ready to push,
//     and 1 commit from the remote to pull down."

// Example git status summaries:
print(exampleGitStatus.summary)
// → "uncommitted changes, 3 unpushed, 1 to pull"

let cleanStatus = GitStatus(isDirty: false, commitsAhead: 0, commitsBehind: 0, hasRemote: true)
print(cleanStatus.summary)
// → "up to date"

let noRemoteStatus = GitStatus(isDirty: false, commitsAhead: 0, commitsBehind: 0, hasRemote: false)
print(noRemoteStatus.summary)
// → "no remote"
