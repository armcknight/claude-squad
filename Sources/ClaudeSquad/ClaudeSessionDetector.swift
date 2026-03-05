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

    /// Cache: JSONL file path → session metadata extracted from early lines.
    private var firstLineCache: [String: FirstLineInfo] = [:]

    /// Cache: JSONL file path → (last modification date, last analyzed session).
    /// If the file hasn't changed since last check, reuse the cached session.
    private var sessionCache: [String: (modDate: Date, session: ClaudeSession)] = [:]

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
        Logger.info("detectSessions() START — claudeDir=\(claudeDir)")

        guard FileManager.default.fileExists(atPath: projectsDir) else {
            Logger.info("No projects directory at \(projectsDir) — returning empty")
            return []
        }

        // Step 1: Find all project directories and their most recent JSONL files.
        let projectJSONLFiles = findProjectJSONLFiles(projectsDir: projectsDir)
        Logger.info("Found \(projectJSONLFiles.count) project JSONL file(s)")

        // Step 2: Analyze each session, skipping unchanged files.
        var sessions: [ClaudeSession] = []
        for jsonlPath in projectJSONLFiles {
            // Check if file has changed since last analysis.
            if let cached = sessionCache[jsonlPath] {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: jsonlPath),
                   let modDate = attrs[.modificationDate] as? Date,
                   modDate == cached.modDate {
                    Logger.debug("Skipping unchanged session: \(cached.session.displayName)")
                    sessions.append(cached.session)
                    continue
                }
            }

            if let session = analyzeSession(jsonlPath: jsonlPath, claudeDir: claudeDir) {
                // Cache the result with the file's current modification date.
                if let attrs = try? FileManager.default.attributesOfItem(atPath: jsonlPath),
                   let modDate = attrs[.modificationDate] as? Date {
                    sessionCache[jsonlPath] = (modDate: modDate, session: session)
                }
                sessions.append(session)
            }
        }

        // Step 3: Clean caches of stale entries.
        let currentPaths = Set(projectJSONLFiles)
        firstLineCache = firstLineCache.filter { currentPaths.contains($0.key) }
        sessionCache = sessionCache.filter { currentPaths.contains($0.key) }

        Logger.info("detectSessions() END — \(sessions.count) session(s): \(sessions.map { "\($0.displayName) [\($0.status)]" })")
        return sessions
    }

    // MARK: - Path helpers

    func claudeBasePath() -> String {
        let home = NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".claude")
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
    /// Status is determined purely from JSONL content + file modification time.
    func analyzeSession(jsonlPath: String, claudeDir: String) -> ClaudeSession? {
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

        // Read tail lines to determine status.
        let tailLines = readTailLines(filePath: jsonlPath, lineCount: tailLineCount)
        Logger.debug("  Read \(tailLines.count) tail lines")
        let status = determineStatus(tailLines: tailLines, lastModified: lastModified)
        Logger.debug("  Status: \(status)")

        // Prefer git branch from JSONL metadata, fall back to .git/HEAD.
        let gitBranch = meta.gitBranch ?? readGitBranch(projectPath: cwd)

        // Read task summary.
        let taskSummary = readTaskSummary(sessionId: sessionId, claudeDir: claudeDir)

        // Read full task items.
        let taskItems = readTaskItems(sessionId: sessionId, claudeDir: claudeDir)

        // Find PR URL.
        let prURL = findPullRequestURL(jsonlPath: jsonlPath)

        var session = ClaudeSession(
            id: sessionId,
            projectPath: cwd,
            gitBranch: gitBranch,
            slug: meta.slug,
            status: status,
            taskSummary: taskSummary,
            lastModified: lastModified
        )
        session.taskItems = taskItems
        session.pullRequestURL = prURL
        session.jsonlPath = jsonlPath
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
        // Check if the most recent message entry is an assistant tool_use with no
        // following tool_result. If so, the tool is pending user approval.
        let hasToolResultAfterLastAssistant = checkForToolResultAfterLastAssistant(tailLines: tailLines)

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
                return analyzeAssistantMessage(json: json, lastModified: lastModified, toolResultFollows: hasToolResultAfterLastAssistant)
            }

            // User message — check if it's an interruption or a normal message.
            if type == "user" || messageRole == "user" {
                // Check for user interruption patterns.
                if let message = json["message"] as? [String: Any] {
                    if let contentStr = message["content"] as? String,
                       contentStr.contains("[Request interrupted by user") {
                        Logger.debug("    -> interrupted (user interruption text)")
                        return .interrupted(lastActivity: lastModified)
                    }
                    if let contentArray = message["content"] as? [[String: Any]] {
                        // Check for rejected tool_result or interruption text
                        for block in contentArray {
                            if let blockType = block["type"] as? String {
                                if blockType == "text",
                                   let text = block["text"] as? String,
                                   text.contains("[Request interrupted by user") {
                                    Logger.debug("    -> interrupted (user interruption text in content block)")
                                    return .interrupted(lastActivity: lastModified)
                                }
                                if blockType == "tool_result",
                                   let content = block["content"] as? String,
                                   content.contains("user doesn't want to proceed") {
                                    Logger.debug("    -> interrupted (rejected tool use)")
                                    return .interrupted(lastActivity: lastModified)
                                }
                            }
                        }
                    }
                }
                // Normal user message → Claude should be processing.
                // If file is stale, Claude stopped responding → interrupted.
                let staleness = Date().timeIntervalSince(lastModified)
                if staleness > 30 {
                    Logger.debug("    -> interrupted (user message but file stale \(Int(staleness))s)")
                    return .interrupted(lastActivity: lastModified)
                }
                Logger.debug("    -> running (user message, file fresh)")
                return .running
            }

            // Skip non-message types (file-history-snapshot, progress, system).
        }

        return .inactive(lastActivity: lastModified)
    }

    /// Checks whether the last assistant message in the tail lines is followed by a
    /// user tool_result. If not, the assistant's tool_use is still pending approval.
    private func checkForToolResultAfterLastAssistant(tailLines: [String]) -> Bool {
        // Walk from the end. Once we hit an assistant message, check if any user
        // tool_result appeared between it and the end of the file.
        var sawUserToolResult = false
        for line in tailLines.reversed() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let type = json["type"] as? String
            let messageRole = (json["message"] as? [String: Any])?["role"] as? String

            if type == "assistant" || messageRole == "assistant" {
                return sawUserToolResult
            }
            if type == "user" || messageRole == "user" {
                // Check if this user message contains a tool_result
                if let message = json["message"] as? [String: Any] {
                    if let contentArray = message["content"] as? [[String: Any]] {
                        for block in contentArray {
                            if (block["type"] as? String) == "tool_result" {
                                sawUserToolResult = true
                            }
                        }
                    }
                }
            }
        }
        return sawUserToolResult
    }

    /// Analyzes an assistant message to determine if it's waiting or still working.
    /// `toolResultFollows` indicates whether a user tool_result appears after this
    /// assistant message in the JSONL. If false, the tool_use is pending approval.
    func analyzeAssistantMessage(json: [String: Any], lastModified: Date, toolResultFollows: Bool = true) -> SessionStatus {
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
            // If no tool_result follows this assistant tool_use AND the file is
            // stale (>3s), the tool is pending user approval — treat as needs input.
            if !toolResultFollows {
                let staleness = Date().timeIntervalSince(lastModified)
                if staleness > 3 {
                    Logger.debug("    -> waitingForQuestion (tool_use \(toolName) pending approval, file stale \(Int(staleness))s)")
                    return .waitingForQuestion(since: lastModified, question: "Approve \(toolName) tool use?")
                }
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

    // MARK: - Task items reading

    /// Reads full task items (with text content) for a session.
    func readTaskItems(sessionId: String, claudeDir: String) -> [TaskItem] {
        let tasksDir = (claudeDir as NSString).appendingPathComponent("tasks")
        let sessionTasksDir = (tasksDir as NSString).appendingPathComponent(sessionId)
        let todosDir = (claudeDir as NSString).appendingPathComponent("todos")
        let fm = FileManager.default
        var items: [TaskItem] = []

        // Read from tasks/<sessionId>/*.json
        if let files = try? fm.contentsOfDirectory(atPath: sessionTasksDir) {
            for file in files.sorted() where file.hasSuffix(".json") {
                let path = (sessionTasksDir as NSString).appendingPathComponent(file)
                if let item = parseTaskFile(path: path) {
                    items.append(item)
                }
            }
        }

        // Read from todos/<sessionId>-*.json
        if let files = try? fm.contentsOfDirectory(atPath: todosDir) {
            for file in files.sorted() where file.hasSuffix(".json") && file.hasPrefix(sessionId) {
                let path = (todosDir as NSString).appendingPathComponent(file)
                if let data = fm.contents(atPath: path),
                   let json = try? JSONSerialization.jsonObject(with: data) {
                    if let tasks = json as? [[String: Any]] {
                        for task in tasks {
                            if let item = parseTaskJSON(task) { items.append(item) }
                        }
                    } else if let task = json as? [String: Any] {
                        if let item = parseTaskJSON(task) { items.append(item) }
                    }
                }
            }
        }

        return items
    }

    private func parseTaskFile(path: String) -> TaskItem? {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parseTaskJSON(json)
    }

    private func parseTaskJSON(_ json: [String: Any]) -> TaskItem? {
        guard let subject = json["subject"] as? String else { return nil }
        let id = (json["id"] as? String) ?? UUID().uuidString
        let description = json["description"] as? String
        let status = (json["status"] as? String) ?? "pending"
        let activeForm = json["activeForm"] as? String
        return TaskItem(id: id, subject: subject, description: description, status: status, activeForm: activeForm)
    }

    // MARK: - Transcript reading

    /// How many tail lines to read for the transcript.
    /// We read more lines than we display because many are progress/system lines that get filtered.
    private let transcriptTailLineCount = 200

    /// Reads the most recent conversation messages from a JSONL file using tail reading.
    func readTranscript(jsonlPath: String) -> [TranscriptMessage] {
        let tailLines = readTailLines(filePath: jsonlPath, lineCount: transcriptTailLineCount)
        if tailLines.isEmpty {
            Logger.debug("readTranscript: no tail lines from \(jsonlPath)")
            return []
        }

        var messages: [TranscriptMessage] = []

        for line in tailLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            guard let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let type = json["type"] as? String
            // Skip non-message types
            if type == "file-history-snapshot" || type == "progress" || type == "system"
                || type == "queue-operation" {
                continue
            }

            guard let message = json["message"] as? [String: Any],
                  let role = message["role"] as? String else {
                continue
            }

            let uuid = (json["uuid"] as? String) ?? UUID().uuidString
            let timestamp = parseTimestamp(json["timestamp"] as? String)

            var textParts: [String] = []
            var toolCalls: [ToolCallSummary] = []

            if let contentStr = message["content"] as? String {
                let cleaned = contentStr.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { textParts.append(cleaned) }
            } else if let contentArray = message["content"] as? [[String: Any]] {
                for block in contentArray {
                    let blockType = block["type"] as? String
                    if blockType == "text", let text = block["text"] as? String {
                        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleaned.isEmpty { textParts.append(cleaned) }
                    } else if blockType == "tool_use" {
                        let name = block["name"] as? String ?? "unknown"
                        let summary = toolCallSummary(name: name, input: block["input"] as? [String: Any])
                        toolCalls.append(ToolCallSummary(name: name, summary: summary))
                    } else if blockType == "tool_result" {
                        continue
                    }
                }
            }

            if textParts.isEmpty && toolCalls.isEmpty { continue }

            let fullText = textParts.joined(separator: "\n\n")
            messages.append(TranscriptMessage(
                id: uuid,
                role: role,
                text: fullText,
                timestamp: timestamp,
                toolCalls: toolCalls
            ))
        }

        Logger.debug("readTranscript: parsed \(messages.count) messages from \(tailLines.count) tail lines")
        return messages
    }

    private func parseTimestamp(_ str: String?) -> Date? {
        guard let str else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: str) { return date }
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: str)
    }

    private func toolCallSummary(name: String, input: [String: Any]?) -> String? {
        guard let input else { return nil }
        switch name {
        case "Bash":
            return input["command"] as? String
        case "Read":
            return input["file_path"] as? String
        case "Edit":
            return input["file_path"] as? String
        case "Write":
            return input["file_path"] as? String
        case "Glob":
            return input["pattern"] as? String
        case "Grep":
            return input["pattern"] as? String
        case "Task":
            return input["description"] as? String
        case "AskUserQuestion":
            if let questions = input["questions"] as? [[String: Any]],
               let first = questions.first {
                return first["question"] as? String
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: - PR URL detection

    /// Scans the tail of a JSONL file for GitHub PR URLs or `pr-link` type entries.
    func findPullRequestURL(jsonlPath: String) -> String? {
        // Read a generous tail — PR links are typically near the end.
        let tailLines = readTailLines(filePath: jsonlPath, lineCount: 100)
        let prPattern = "https://github\\.com/[^/]+/[^/]+/pull/\\d+"
        guard let regex = try? NSRegularExpression(pattern: prPattern) else { return nil }

        // Scan in reverse to find the most recent PR link.
        for line in tailLines.reversed() {
            // Check for explicit pr-link type entries first.
            if line.contains("\"pr-link\"") || line.contains("\"type\":\"pr-link\"") {
                let range = NSRange(line.startIndex..., in: line)
                if let match = regex.firstMatch(in: line, range: range),
                   let matchRange = Range(match.range, in: line) {
                    return String(line[matchRange])
                }
            }
        }

        // Fall back to regex search across all tail lines.
        for line in tailLines.reversed() {
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, range: range),
               let matchRange = Range(match.range, in: line) {
                return String(line[matchRange])
            }
        }
        return nil
    }

}
