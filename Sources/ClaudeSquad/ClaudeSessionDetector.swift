import Foundation

/// Detects Claude sessions by reading on-disk data (`~/.claude/`) and correlating
/// with running processes. Replaces the tmux-based detection approach.
final class ClaudeSessionDetector {

    static let shared = ClaudeSessionDetector()

    /// How many lines to read from the tail of each JSONL file.
    private let tailLineCount = 20

    /// How many lines to scan from the head looking for session metadata.
    private let headScanLineCount = 20

    /// Chunk size for backward-seeking tail reads and forward head reads.
    private let chunkSize = 8192

    /// Skip inactive sessions older than this.
    private let maxInactiveAge: TimeInterval = 24 * 60 * 60

    /// Cache: JSONL file path → session metadata extracted from early lines.
    private var firstLineCache: [String: FirstLineInfo] = [:]

    struct FirstLineInfo {
        let cwd: String
        let sessionId: String
        let gitBranch: String?
        let slug: String?
    }

    // MARK: - Public API

    /// Detects all active Claude sessions. Called each poll cycle.
    func detectSessions() throws -> [ClaudeSession] {
        let claudeDir = claudeBasePath()
        let projectsDir = (claudeDir as NSString).appendingPathComponent("projects")
        Logger.info("detectSessions() START — NSHomeDirectory()=\(NSHomeDirectory()), claudeDir=\(claudeDir), projectsDir=\(projectsDir)")
        Logger.info("projectsDir exists: \(FileManager.default.fileExists(atPath: projectsDir))")

        guard FileManager.default.fileExists(atPath: projectsDir) else {
            Logger.info("No projects directory at \(projectsDir) — returning empty")
            return []
        }

        // Step 1: Get all running claude processes with their cwds.
        let runningProcesses = scanRunningClaudeProcesses()
        Logger.info("Running claude processes: \(runningProcesses.map { "pid=\($0.pid) cwd=\($0.cwd)" })")

        // Step 2: Find all project directories and their most recent JSONL files.
        let projectJSONLFiles = findProjectJSONLFiles(projectsDir: projectsDir)
        Logger.info("Found \(projectJSONLFiles.count) project JSONL file(s): \(projectJSONLFiles.map { ($0 as NSString).lastPathComponent })")

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

        Logger.info("detectSessions() END — \(sessions.count) session(s): \(sessions.map { "\($0.displayName) [\($0.status)]" })")
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
        let psPids = findClaudePIDs()
        guard !psPids.isEmpty else {
            Logger.info("No claude PIDs found via ps")
            return []
        }
        Logger.info("Found claude PIDs: \(psPids)")

        let cwdMap = getProcessCWDs(pids: psPids)
        Logger.debug("lsof cwd map: \(cwdMap)")

        let result = psPids.compactMap { pid -> RunningClaude? in
            guard let cwd = cwdMap[pid] else {
                Logger.debug("No cwd from lsof for pid \(pid)")
                return nil
            }
            return RunningClaude(pid: pid, cwd: cwd)
        }
        return result
    }

    /// Returns PIDs of all running `claude` processes.
    func findClaudePIDs() -> [Int32] {
        guard let output = try? runShell("/bin/ps", args: ["-eo", "pid,comm"]) else {
            Logger.warning("Failed to run ps -eo pid,comm")
            return []
        }
        let lines = output.components(separatedBy: "\n")
        Logger.debug("ps returned \(lines.count) lines")
        var pids: [Int32] = []
        var claudeRelated: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2, let pid = Int32(parts[0]) else { continue }
            let comm = parts[1...].joined(separator: " ")
            let basename = (comm as NSString).lastPathComponent.lowercased()
            // Collect any process with "claude" in the name for diagnostics.
            if basename.contains("claude") {
                claudeRelated.append("pid=\(pid) comm=\(comm) basename=\(basename)")
            }
            if basename == "claude" || basename.hasPrefix("claude ") {
                pids.append(pid)
            }
        }
        if !claudeRelated.isEmpty {
            Logger.info("Claude-related processes found: \(claudeRelated)")
        } else {
            Logger.info("No claude-related processes found in ps output")
        }
        return pids
    }

    /// Returns a map of PID → cwd for the given PIDs using `proc_pidinfo`.
    /// Unlike lsof, this uses a direct Darwin syscall that works under hardened runtime.
    func getProcessCWDs(pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        var result: [Int32: String] = [:]
        let infoSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        for pid in pids {
            var vnodeInfo = proc_vnodepathinfo()
            let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, infoSize)
            guard ret == infoSize else {
                Logger.debug("proc_pidinfo failed for pid \(pid) (ret=\(ret))")
                continue
            }
            let cwd = withUnsafePointer(to: &vnodeInfo.pvi_cdir.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                    String(cString: $0)
                }
            }
            if !cwd.isEmpty {
                result[pid] = cwd
            }
        }
        return result
    }

    // MARK: - Project JSONL discovery

    /// Finds the most recent `.jsonl` file in each project subdirectory of `~/.claude/projects/`.
    func findProjectJSONLFiles(projectsDir: String) -> [String] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else {
            Logger.info("Cannot list contents of \(projectsDir)")
            return []
        }
        Logger.info("Project directories (\(projectDirs.count)): \(projectDirs)")

        var results: [String] = []
        for dir in projectDirs {
            let fullDir = (projectsDir as NSString).appendingPathComponent(dir)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullDir, isDirectory: &isDir), isDir.boolValue else { continue }

            guard let files = try? fm.contentsOfDirectory(atPath: fullDir) else { continue }
            let jsonlFiles = files.filter { $0.hasSuffix(".jsonl") }
            if jsonlFiles.isEmpty {
                Logger.debug("  \(dir): no .jsonl files")
                continue
            }

            var bestPath: String?
            var bestDate: Date?
            for file in jsonlFiles {
                let path = (fullDir as NSString).appendingPathComponent(file)
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mod = attrs[.modificationDate] as? Date else { continue }
                if bestDate == nil || mod > bestDate! {
                    bestPath = path
                    bestDate = mod
                }
            }
            if let path = bestPath {
                Logger.debug("  \(dir): selected \((path as NSString).lastPathComponent) (mod: \(bestDate!))")
                results.append(path)
            }
        }
        return results
    }

    // MARK: - Session analysis

    /// Analyzes a single JSONL file to build a `ClaudeSession`.
    func analyzeSession(jsonlPath: String, runningProcesses: [RunningClaude], claudeDir: String) -> ClaudeSession? {
        let fm = FileManager.default
        let fileName = (jsonlPath as NSString).lastPathComponent

        // Get file modification date.
        guard let attrs = try? fm.attributesOfItem(atPath: jsonlPath),
              let lastModified = attrs[.modificationDate] as? Date else {
            Logger.warning("Cannot read attributes for \(fileName)")
            return nil
        }

        // Read session metadata (cached).
        guard let meta = readFirstLineInfo(jsonlPath: jsonlPath) else {
            Logger.debug("Cannot extract session metadata from \(fileName), skipping")
            return nil
        }

        let cwd = meta.cwd
        let sessionId = meta.sessionId
        Logger.debug("Analyzing session \(sessionId): cwd=\(cwd)")

        // Check if inactive too long.
        let matchingProcess = runningProcesses.first { $0.cwd == cwd }
        if let proc = matchingProcess {
            Logger.debug("  Matched running process pid=\(proc.pid)")
        } else {
            Logger.debug("  No matching running process for cwd=\(cwd)")
            let age = Date().timeIntervalSince(lastModified)
            if age > maxInactiveAge {
                Logger.debug("  Skipping stale session (inactive \(Int(age/3600))h)")
                return nil
            }
        }

        // Read tail lines to determine status.
        let tailLines = readTailLines(filePath: jsonlPath, lineCount: tailLineCount)
        Logger.debug("  Read \(tailLines.count) tail lines")
        var status = determineStatus(tailLines: tailLines, lastModified: lastModified)
        Logger.debug("  JSONL-derived status: \(status)")

        if matchingProcess != nil {
            // We have a running process. If JSONL analysis couldn't determine
            // an active status (e.g. tail lines were unparseable), trust the
            // process signal — the session is running.
            if !status.isActive {
                Logger.debug("  Process matched but JSONL says inactive — overriding to running")
                status = .running
            }
        } else {
            // No matching process. Use file recency as a secondary signal:
            // if the file was modified very recently, something is writing to
            // it, so trust the JSONL-derived status instead of forcing inactive.
            let timeSinceModified = Date().timeIntervalSince(lastModified)
            if timeSinceModified > 30 {
                status = .inactive(lastActivity: lastModified)
                Logger.debug("  Overridden to inactive (no process, file stale \(Int(timeSinceModified))s)")
            } else {
                Logger.debug("  No process but file recently modified (\(Int(timeSinceModified))s) — keeping JSONL status")
            }
        }

        // Prefer git branch from JSONL metadata, fall back to .git/HEAD.
        let gitBranch = meta.gitBranch ?? readGitBranch(projectPath: cwd)

        // Read task summary.
        let taskSummary = readTaskSummary(sessionId: sessionId, claudeDir: claudeDir)

        let session = ClaudeSession(
            id: sessionId,
            projectPath: cwd,
            gitBranch: gitBranch,
            slug: meta.slug,
            status: status,
            processPID: matchingProcess?.pid,
            taskSummary: taskSummary,
            lastModified: lastModified
        )
        Logger.debug("  -> \(session.displayName) [\(status)]")
        return session
    }

    // MARK: - Session metadata reading (cached)

    /// Scans the first few lines of a JSONL file to find session metadata (`cwd`, `sessionId`, etc.).
    /// The first line is often a `file-history-snapshot`; the metadata is on the first `user` or `assistant` line.
    /// Results are cached by file path.
    func readFirstLineInfo(jsonlPath: String) -> FirstLineInfo? {
        if let cached = firstLineCache[jsonlPath] {
            return cached
        }

        guard let handle = FileHandle(forReadingAtPath: jsonlPath) else {
            Logger.debug("Cannot open \(jsonlPath) for reading")
            return nil
        }
        defer { handle.closeFile() }

        // Read enough data to cover the first several lines.
        // Most metadata lines are within the first few KB, but user messages
        // can be very large (the prompt). Read multiple chunks if needed.
        var accumulated = ""
        var linesScanned = 0
        let maxChunks = 10 // Up to ~80KB of head data
        var done = false

        for chunkIndex in 0..<maxChunks {
            let data = handle.readData(ofLength: chunkSize)
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                accumulated += str
            }

            let atEOF = data.isEmpty

            // Split into lines. If not at EOF, the last element may be incomplete.
            let lines = accumulated.components(separatedBy: "\n")
            let completeLines = atEOF ? lines : Array(lines.dropLast())

            for line in completeLines {
                if linesScanned >= headScanLineCount { done = true; break }
                linesScanned += 1

                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }

                if let info = parseSessionMetadata(trimmed) {
                    Logger.debug("Found session metadata on line \(linesScanned) (chunk \(chunkIndex)): id=\(info.sessionId), cwd=\(info.cwd), branch=\(info.gitBranch ?? "nil"), slug=\(info.slug ?? "nil")")
                    firstLineCache[jsonlPath] = info
                    return info
                }
            }

            if done || atEOF { break }

            // Keep only the incomplete last line for the next iteration.
            accumulated = lines.last ?? ""
        }

        Logger.debug("No session metadata found in first \(linesScanned) lines of \((jsonlPath as NSString).lastPathComponent)")
        return nil
    }

    /// Parses a JSONL line to extract session metadata. Returns nil if this line
    /// doesn't contain `cwd` (e.g. it's a `file-history-snapshot` or `progress` line).
    func parseSessionMetadata(_ line: String) -> FirstLineInfo? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let type = json["type"] as? String

        // Skip non-message line types that don't carry session metadata.
        if type == "file-history-snapshot" || type == "progress" || type == "system" {
            return nil
        }

        // `cwd` and `sessionId` are top-level fields on user/assistant lines.
        guard let cwd = json["cwd"] as? String else {
            return nil
        }

        let sessionId: String
        if let s = json["sessionId"] as? String {
            sessionId = s
        } else if let s = json["session_id"] as? String {
            sessionId = s
        } else {
            // Fall back to the JSONL filename (without extension).
            return nil
        }

        let gitBranch = json["gitBranch"] as? String
        let slug = json["slug"] as? String

        return FirstLineInfo(cwd: cwd, sessionId: sessionId, gitBranch: gitBranch, slug: slug)
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
            let readSize = min(UInt64(chunkSize), offset)
            offset -= readSize
            handle.seek(toFileOffset: offset)
            let chunk = handle.readData(ofLength: Int(readSize))
            collectedData.insert(contentsOf: chunk, at: 0)

            for byte in chunk {
                if byte == 0x0A { newlineCount += 1 }
            }
        }

        guard let str = String(data: collectedData, encoding: .utf8) else { return [] }
        let allLines = str.components(separatedBy: "\n").filter { !$0.isEmpty }
        return Array(allLines.suffix(lineCount))
    }

    // MARK: - Status determination

    /// Determines session status from the tail lines of the JSONL conversation log.
    func determineStatus(tailLines: [String], lastModified: Date) -> SessionStatus {
        for line in tailLines.reversed() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let type = json["type"] as? String
            let messageRole = (json["message"] as? [String: Any])?["role"] as? String

            Logger.debug("    tail line: type=\(type ?? "nil"), message.role=\(messageRole ?? "nil")")

            // Assistant message — analyze content blocks to determine waiting vs running.
            if type == "assistant" || messageRole == "assistant" {
                return analyzeAssistantMessage(json: json, lastModified: lastModified)
            }

            // User message (including tool_result content) → Claude should be processing.
            if type == "user" || messageRole == "user" {
                return .running
            }

            // Skip non-message types (file-history-snapshot, progress, system).
        }

        return .inactive(lastActivity: lastModified)
    }

    /// Analyzes an assistant message to determine if it's waiting or still working.
    func analyzeAssistantMessage(json: [String: Any], lastModified: Date) -> SessionStatus {
        // Content blocks are nested inside `message.content`.
        let content: [[String: Any]]
        if let message = json["message"] as? [String: Any],
           let contentArray = message["content"] as? [[String: Any]] {
            content = contentArray
        } else if let contentArray = json["content"] as? [[String: Any]] {
            content = contentArray
        } else {
            // Plain text response with no structured content → waiting idle.
            Logger.debug("    assistant message has no content blocks -> waitingIdle")
            return .waitingIdle(since: lastModified)
        }

        let blockTypes = content.compactMap { $0["type"] as? String }
        let lastBlockName = (content.last?["name"] as? String) ?? "(none)"
        Logger.debug("    assistant content: \(content.count) blocks, types=\(blockTypes), lastTool=\(lastBlockName)")

        // Check if the last content block is a tool_use.
        if let lastBlock = content.last,
           let blockType = lastBlock["type"] as? String,
           blockType == "tool_use" {
            let toolName = lastBlock["name"] as? String ?? ""
            if toolName == "AskUserQuestion" || toolName == "TodoWrite" || toolName == "ExitPlanMode" {
                let question = extractQuestion(from: lastBlock)
                Logger.debug("    -> waitingForQuestion (tool=\(toolName), question=\(question ?? "nil"))")
                return .waitingForQuestion(since: lastModified, question: question)
            }
            Logger.debug("    -> running (tool_use: \(toolName))")
            return .running
        }

        // Has content blocks but last one is text → finished output, waiting idle.
        let hasTextBlock = content.contains { ($0["type"] as? String) == "text" }
        if hasTextBlock {
            Logger.debug("    -> waitingIdle (text output, no pending tool)")
            return .waitingIdle(since: lastModified)
        }

        Logger.debug("    -> running (no text, no tool_use)")
        return .running
    }

    /// Extracts the question text from an AskUserQuestion tool_use block.
    func extractQuestion(from toolUseBlock: [String: Any]) -> String? {
        guard let input = toolUseBlock["input"] as? [String: Any] else { return nil }
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

    func readTaskSummary(sessionId: String, claudeDir: String) -> TaskSummary? {
        let todosDir = (claudeDir as NSString).appendingPathComponent("todos")
        let tasksDir = (claudeDir as NSString).appendingPathComponent("tasks")

        var total = 0
        var completed = 0
        var inProgress = 0
        var pending = 0

        readTasksFromDirectory(todosDir, sessionId: sessionId, total: &total, completed: &completed, inProgress: &inProgress, pending: &pending)

        let sessionTasksDir = (tasksDir as NSString).appendingPathComponent(sessionId)
        readTasksFromDirectory(sessionTasksDir, sessionId: nil, total: &total, completed: &completed, inProgress: &inProgress, pending: &pending)

        // When tasks are completed, Claude Code deletes the JSON files and writes
        // a .highwatermark file containing the total task count. Account for
        // cleaned-up tasks by reading the highwatermark.
        let hwPath = (sessionTasksDir as NSString).appendingPathComponent(".highwatermark")
        if let hwStr = try? String(contentsOfFile: hwPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let hwTotal = Int(hwStr), hwTotal > total {
            let cleanedUp = hwTotal - total
            completed += cleanedUp
            total = hwTotal
        }

        guard total > 0 else { return nil }
        return TaskSummary(total: total, completed: completed, inProgress: inProgress, pending: pending)
    }

    private func readTasksFromDirectory(_ dir: String, sessionId: String?, total: inout Int, completed: inout Int, inProgress: inout Int, pending: inout Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return }

        for file in files where file.hasSuffix(".json") {
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

        // Read pipe data BEFORE waitUntilExit to avoid deadlock when output
        // exceeds the pipe buffer size (~64KB). The child process blocks on
        // write if the buffer is full, and waitUntilExit blocks on the child.
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(data: data, encoding: .utf8) ?? ""
    }
}
