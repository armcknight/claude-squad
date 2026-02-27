import Foundation

/// Detects Claude sessions by reading on-disk data (`~/.claude/`) and correlating
/// with running processes. Replaces the tmux-based detection approach.
final class ClaudeSessionDetector {

    static let shared = ClaudeSessionDetector()

    /// How many lines to read from the tail of each JSONL file.
    private let tailLineCount = 20

    /// Chunk size for backward-seeking tail reads.
    private let tailChunkSize = 8192

    /// Skip inactive sessions older than this.
    private let maxInactiveAge: TimeInterval = 24 * 60 * 60

    /// Cache: project directory path → session info extracted from the first JSONL line.
    /// Keyed by the JSONL file path so we don't re-read unchanged files.
    private var firstLineCache: [String: FirstLineInfo] = [:]

    struct FirstLineInfo {
        let cwd: String
        let sessionId: String
    }

    // MARK: - Public API

    /// Detects all active Claude sessions. Called each poll cycle.
    func detectSessions() throws -> [ClaudeSession] {
        let claudeDir = claudeBasePath()
        let projectsDir = (claudeDir as NSString).appendingPathComponent("projects")

        guard FileManager.default.fileExists(atPath: projectsDir) else {
            return []
        }

        // Step 1: Get all running claude processes with their cwds.
        let runningProcesses = scanRunningClaudeProcesses()

        // Step 2: Find all project directories and their most recent JSONL files.
        let projectJSONLFiles = findProjectJSONLFiles(projectsDir: projectsDir)

        // Step 3: Analyze each session.
        var sessions: [ClaudeSession] = []
        for jsonlPath in projectJSONLFiles {
            if let session = analyzeSession(jsonlPath: jsonlPath, runningProcesses: runningProcesses, claudeDir: claudeDir) {
                sessions.append(session)
            }
        }

        // Step 4: Clean first-line cache of stale entries.
        let currentPaths = Set(projectJSONLFiles)
        firstLineCache = firstLineCache.filter { currentPaths.contains($0.key) }

        return sessions
    }

    // MARK: - Path helpers

    func claudeBasePath() -> String {
        let home = NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".claude")
    }

    // MARK: - Process scanning

    struct RunningClaude {
        let pid: Int32
        let cwd: String
    }

    /// Scans for running `claude` processes and their working directories.
    func scanRunningClaudeProcesses() -> [RunningClaude] {
        // Step 1: Find claude PIDs via `ps`.
        let psPids = findClaudePIDs()
        guard !psPids.isEmpty else { return [] }

        // Step 2: Get cwds via `lsof` for those PIDs.
        let cwdMap = getProcessCWDs(pids: psPids)

        return psPids.compactMap { pid in
            guard let cwd = cwdMap[pid] else { return nil }
            return RunningClaude(pid: pid, cwd: cwd)
        }
    }

    /// Returns PIDs of all running `claude` processes.
    func findClaudePIDs() -> [Int32] {
        guard let output = try? runShell("/bin/ps", args: ["-eo", "pid,comm"]) else {
            return []
        }
        var pids: [Int32] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2, let pid = Int32(parts[0]) else { continue }
            let comm = parts[1...].joined(separator: " ")
            let basename = (comm as NSString).lastPathComponent.lowercased()
            if basename == "claude" || basename.hasPrefix("claude ") {
                pids.append(pid)
            }
        }
        return pids
    }

    /// Returns a map of PID → cwd for the given PIDs using `lsof`.
    func getProcessCWDs(pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let pidArgs = pids.map(String.init)
        // Use lsof to get cwd (file descriptor "cwd") for specific PIDs.
        var args = ["-a", "-d", "cwd", "-Fn"]
        for pid in pidArgs {
            args += ["-p", pid]
        }
        guard let output = try? runShell("/usr/bin/lsof", args: args) else {
            return [:]
        }
        var result: [Int32: String] = [:]
        var currentPID: Int32?
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("p"), let pid = Int32(line.dropFirst()) {
                currentPID = pid
            } else if line.hasPrefix("n"), let pid = currentPID {
                result[pid] = String(line.dropFirst())
            }
        }
        return result
    }

    // MARK: - Project JSONL discovery

    /// Finds the most recent `.jsonl` file in each project subdirectory of `~/.claude/projects/`.
    func findProjectJSONLFiles(projectsDir: String) -> [String] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else {
            return []
        }
        var results: [String] = []
        for dir in projectDirs {
            let fullDir = (projectsDir as NSString).appendingPathComponent(dir)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullDir, isDirectory: &isDir), isDir.boolValue else { continue }

            // Find the most recently modified .jsonl in this directory.
            guard let files = try? fm.contentsOfDirectory(atPath: fullDir) else { continue }
            var bestPath: String?
            var bestDate: Date?
            for file in files where file.hasSuffix(".jsonl") {
                let path = (fullDir as NSString).appendingPathComponent(file)
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mod = attrs[.modificationDate] as? Date else { continue }
                if bestDate == nil || mod > bestDate! {
                    bestPath = path
                    bestDate = mod
                }
            }
            if let path = bestPath {
                results.append(path)
            }
        }
        return results
    }

    // MARK: - Session analysis

    /// Analyzes a single JSONL file to build a `ClaudeSession`.
    func analyzeSession(jsonlPath: String, runningProcesses: [RunningClaude], claudeDir: String) -> ClaudeSession? {
        let fm = FileManager.default

        // Get file modification date.
        guard let attrs = try? fm.attributesOfItem(atPath: jsonlPath),
              let lastModified = attrs[.modificationDate] as? Date else {
            return nil
        }

        // Read first line info (cached).
        guard let firstLine = readFirstLineInfo(jsonlPath: jsonlPath) else {
            return nil
        }

        let cwd = firstLine.cwd
        let sessionId = firstLine.sessionId

        // Check if inactive too long.
        let matchingProcess = runningProcesses.first { $0.cwd == cwd }
        if matchingProcess == nil && Date().timeIntervalSince(lastModified) > maxInactiveAge {
            return nil
        }

        // Read tail lines to determine status.
        let tailLines = readTailLines(filePath: jsonlPath, lineCount: tailLineCount)
        var status = determineStatus(tailLines: tailLines, lastModified: lastModified)

        // If no matching process, override to inactive.
        if matchingProcess == nil {
            status = .inactive(lastActivity: lastModified)
        }

        // Read git branch.
        let gitBranch = readGitBranch(projectPath: cwd)

        // Read task summary.
        let taskSummary = readTaskSummary(sessionId: sessionId, claudeDir: claudeDir)

        return ClaudeSession(
            id: sessionId,
            projectPath: cwd,
            gitBranch: gitBranch,
            status: status,
            processPID: matchingProcess?.pid,
            taskSummary: taskSummary,
            lastModified: lastModified
        )
    }

    // MARK: - First line reading (cached)

    /// Reads the first line of a JSONL file to extract `cwd` and `sessionId`.
    /// Results are cached by file path.
    func readFirstLineInfo(jsonlPath: String) -> FirstLineInfo? {
        if let cached = firstLineCache[jsonlPath] {
            return cached
        }

        guard let handle = FileHandle(forReadingAtPath: jsonlPath) else { return nil }
        defer { handle.closeFile() }

        // Read a generous first chunk to get the first line.
        let data = handle.readData(ofLength: tailChunkSize)
        guard let str = String(data: data, encoding: .utf8) else { return nil }

        guard let firstNewline = str.firstIndex(of: "\n") else { return nil }
        let firstLine = String(str[str.startIndex..<firstNewline])

        guard let info = parseFirstLine(firstLine) else { return nil }
        firstLineCache[jsonlPath] = info
        return info
    }

    /// Parses the first JSONL line to extract cwd and sessionId.
    func parseFirstLine(_ line: String) -> FirstLineInfo? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // The first line is typically a "system" message containing cwd info.
        // Look for cwd in the message content or at top level.
        let cwd: String?
        if let c = json["cwd"] as? String {
            cwd = c
        } else if let message = json["message"] as? [String: Any], let c = message["cwd"] as? String {
            cwd = c
        } else {
            cwd = nil
        }

        let sessionId: String?
        if let s = json["sessionId"] as? String {
            sessionId = s
        } else if let s = json["session_id"] as? String {
            sessionId = s
        } else {
            // Fall back to using the filename (without extension) as session ID.
            sessionId = nil
        }

        guard let resolvedCwd = cwd else { return nil }
        let resolvedId = sessionId ?? (URL(fileURLWithPath: "dummy").lastPathComponent)

        return FirstLineInfo(cwd: resolvedCwd, sessionId: resolvedId)
    }

    // MARK: - JSONL tail reading (performance critical)

    /// Reads the last N lines of a file using backward-seeking. O(1) relative to file size.
    func readTailLines(filePath: String, lineCount: Int) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: filePath) else { return [] }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        guard fileSize > 0 else { return [] }

        var collectedData = Data()
        var newlineCount = 0
        var offset = fileSize

        while offset > 0 && newlineCount <= lineCount {
            let chunkSize = min(UInt64(tailChunkSize), offset)
            offset -= chunkSize
            handle.seek(toFileOffset: offset)
            let chunk = handle.readData(ofLength: Int(chunkSize))
            collectedData.insert(contentsOf: chunk, at: 0)

            // Count newlines in this chunk.
            for byte in chunk {
                if byte == 0x0A { // '\n'
                    newlineCount += 1
                }
            }
        }

        guard let str = String(data: collectedData, encoding: .utf8) else { return [] }
        let allLines = str.components(separatedBy: "\n").filter { !$0.isEmpty }

        // Return only the last `lineCount` lines.
        return Array(allLines.suffix(lineCount))
    }

    // MARK: - Status determination

    /// Determines session status from the tail lines of the JSONL conversation log.
    func determineStatus(tailLines: [String], lastModified: Date) -> SessionStatus {
        // Work backwards from the last line to find the most recent meaningful entry.
        for line in tailLines.reversed() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let type = json["type"] as? String
            let role = json["role"] as? String

            // Check for assistant messages.
            if type == "assistant" || role == "assistant" {
                return analyzeAssistantMessage(json: json, lastModified: lastModified)
            }

            // User message or tool_result → Claude should be processing.
            if type == "human" || role == "user" || type == "tool_result" {
                return .running
            }
        }

        // No recognizable entries → treat as inactive.
        return .inactive(lastActivity: lastModified)
    }

    /// Analyzes an assistant message to determine if it's waiting or still working.
    func analyzeAssistantMessage(json: [String: Any], lastModified: Date) -> SessionStatus {
        // Check the message content for tool_use blocks.
        let content: [[String: Any]]
        if let contentArray = json["content"] as? [[String: Any]] {
            content = contentArray
        } else if let message = json["message"] as? [String: Any],
                  let contentArray = message["content"] as? [[String: Any]] {
            content = contentArray
        } else {
            // Plain text response with no tool use → waiting idle.
            return .waitingIdle(since: lastModified)
        }

        // Check if the last content block is a tool_use.
        if let lastBlock = content.last,
           let blockType = lastBlock["type"] as? String,
           blockType == "tool_use" {
            let toolName = lastBlock["name"] as? String ?? ""
            if toolName == "AskUserQuestion" || toolName == "TodoWrite" {
                let question = extractQuestion(from: lastBlock)
                return .waitingForQuestion(since: lastModified, question: question)
            }
            // Other tool_use → Claude is running (tool executing).
            return .running
        }

        // Has content blocks but last one is text → finished output, waiting idle.
        let hasTextBlock = content.contains { ($0["type"] as? String) == "text" }
        if hasTextBlock {
            return .waitingIdle(since: lastModified)
        }

        return .running
    }

    /// Extracts the question text from an AskUserQuestion tool_use block.
    func extractQuestion(from toolUseBlock: [String: Any]) -> String? {
        guard let input = toolUseBlock["input"] as? [String: Any] else { return nil }
        // AskUserQuestion has a "questions" array with "question" fields.
        if let questions = input["questions"] as? [[String: Any]],
           let first = questions.first,
           let q = first["question"] as? String {
            return q
        }
        if let question = input["question"] as? String {
            return question
        }
        return nil
    }

    // MARK: - Git branch detection

    func readGitBranch(projectPath: String) -> String? {
        let headPath = (projectPath as NSString).appendingPathComponent(".git/HEAD")
        guard let content = try? String(contentsOfFile: headPath, encoding: .utf8) else {
            return nil
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let refPrefix = "ref: refs/heads/"
        if trimmed.hasPrefix(refPrefix) {
            return String(trimmed.dropFirst(refPrefix.count))
        }
        return nil
    }

    // MARK: - Task summary reading

    /// Reads task/todo files for the given session and returns a summary.
    func readTaskSummary(sessionId: String, claudeDir: String) -> TaskSummary? {
        let todosDir = (claudeDir as NSString).appendingPathComponent("todos")
        let tasksDir = (claudeDir as NSString).appendingPathComponent("tasks")

        var total = 0
        var completed = 0
        var inProgress = 0
        var pending = 0

        // Check todos directory for files matching the session.
        readTasksFromDirectory(todosDir, sessionId: sessionId, total: &total, completed: &completed, inProgress: &inProgress, pending: &pending)

        // Check tasks directory.
        let sessionTasksDir = (tasksDir as NSString).appendingPathComponent(sessionId)
        readTasksFromDirectory(sessionTasksDir, sessionId: nil, total: &total, completed: &completed, inProgress: &inProgress, pending: &pending)

        guard total > 0 else { return nil }
        return TaskSummary(total: total, completed: completed, inProgress: inProgress, pending: pending)
    }

    private func readTasksFromDirectory(_ dir: String, sessionId: String?, total: inout Int, completed: inout Int, inProgress: inout Int, pending: inout Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return }

        for file in files where file.hasSuffix(".json") {
            // If sessionId is provided, only read files that match.
            if let sid = sessionId, !file.hasPrefix(sid) { continue }

            let path = (dir as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }

            if let tasks = json as? [[String: Any]] {
                for task in tasks {
                    total += 1
                    let status = task["status"] as? String ?? ""
                    switch status {
                    case "completed": completed += 1
                    case "in_progress": inProgress += 1
                    default: pending += 1
                    }
                }
            } else if let task = json as? [String: Any] {
                total += 1
                let status = task["status"] as? String ?? ""
                switch status {
                case "completed": completed += 1
                case "in_progress": inProgress += 1
                default: pending += 1
                }
            }
        }
    }

    // MARK: - Shell execution

    func runShell(_ executable: String, args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
