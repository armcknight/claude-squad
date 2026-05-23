import Foundation

/// Detects Claude sessions by reading on-disk data (`~/.claude/`) and correlating
/// with running processes. Replaces the tmux-based detection approach.
final class ClaudeSessionDetector {

    weak var logger: Logger?

    #if DEBUG
    /// Override to point at a different base directory (e.g. for mock data).
    var basePath: String?

    /// JSONL paths to touch before each detection cycle so they appear "fresh".
    /// Used by mock mode to keep running sessions from going stale.
    var runningFixturePaths: [String] = []
    #endif

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

    /// Cache: subagent JSONL file path → (effective subtree mod date, last analyzed Subagent).
    /// Effective mod date includes nested subagents, so any descendant write invalidates.
    private var subagentCache: [String: (modDate: Date, subagent: Subagent)] = [:]

    struct FirstLineInfo {
        let cwd: String
        let sessionId: String
        let gitBranch: String?
        let slug: String?
    }

    /// Live state from `~/.claude/sessions/<pid>.json` for a running Claude
    /// process. The JSONL file does not reflect pending tool-use prompts
    /// (Claude buffers them until the user responds), so this is the only
    /// on-disk signal that a session is awaiting user input.
    struct LiveSessionState: Equatable {
        let sessionId: String
        let status: String      // "busy", "waiting", "idle"
        let waitingFor: String? // e.g., "permission prompt"
        let updatedAt: Date
    }

    // MARK: - Public API

    /// Detects all active Claude sessions. Called each poll cycle.
    func detectSessions() throws -> [ClaudeSession] {
        #if DEBUG
        // Touch fixture files that should appear "fresh" for running status.
        for path in runningFixturePaths {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: path)
        }
        #endif

        let claudeDir = claudeBasePath()
        let projectsDir = (claudeDir as NSString).appendingPathComponent("projects")
        logger?.info("detectSessions() START — claudeDir=\(claudeDir)")

        guard FileManager.default.fileExists(atPath: projectsDir) else {
            logger?.info("No projects directory at \(projectsDir) — returning empty")
            return []
        }

        // Step 1: Find all project directories and their most recent JSONL files.
        let projectJSONLFiles = findProjectJSONLFiles(projectsDir: projectsDir)
        logger?.info("Found \(projectJSONLFiles.count) project JSONL file(s)")

        // Live state from sessions/*.json — used to override JSONL-derived
        // status when a Claude process is paused on a permission prompt that
        // hasn't been persisted to the JSONL yet.
        let liveStates = readLiveSessionStates(claudeDir: claudeDir)

        // Step 2: Analyze each session, skipping unchanged files.
        var sessions: [ClaudeSession] = []
        for jsonlPath in projectJSONLFiles {
            // Effective mod date = max(main JSONL, freshest subagent JSONL). Subagent
            // activity can change the session status without touching the main file,
            // so the cache must invalidate on subagent writes too.
            let currentModDate = effectiveModDate(jsonlPath: jsonlPath)

            if let cached = sessionCache[jsonlPath],
               let currentModDate,
               currentModDate == cached.modDate {
                switch cached.session.status {
                case .running:
                    // Re-evaluate: staleness may have crossed a threshold.
                    logger?.debug("Re-evaluating running session: \(cached.session.displayName)")
                default:
                    // Re-apply the live overlay on cache hit — live state can
                    // change without the JSONL being touched.
                    let overlaid = applyingLiveStateOverlay(cached.session, liveStates: liveStates)
                    logger?.debug("Skipping unchanged session: \(cached.session.displayName)")
                    sessions.append(overlaid)
                    continue
                }
            }

            if let session = analyzeSession(jsonlPath: jsonlPath, claudeDir: claudeDir) {
                let overlaid = applyingLiveStateOverlay(session, liveStates: liveStates)
                if let currentModDate {
                    sessionCache[jsonlPath] = (modDate: currentModDate, session: overlaid)
                }
                sessions.append(overlaid)
            }
        }

        // Step 3: Clean caches of stale entries.
        let currentPaths = Set(projectJSONLFiles)
        var activeSubagentPaths = Set<String>()
        for session in sessions {
            for sub in session.subagents.flatMap({ $0.flattenedSelfAndDescendants }) {
                activeSubagentPaths.insert(sub.jsonlPath)
            }
        }
        let allActivePaths = currentPaths.union(activeSubagentPaths)
        firstLineCache = firstLineCache.filter { allActivePaths.contains($0.key) }
        sessionCache = sessionCache.filter { currentPaths.contains($0.key) }
        subagentCache = subagentCache.filter { activeSubagentPaths.contains($0.key) }

        logger?.info("detectSessions() END — \(sessions.count) session(s): \(sessions.map { "\($0.displayName) [\($0.status)]" })")
        return sessions
    }

    // MARK: - Path helpers

    func claudeBasePath() -> String {
        #if DEBUG
        if let basePath { return basePath }
        #endif
        let home = NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".claude")
    }

    // MARK: - Live session state

    /// Scans `<claudeDir>/sessions/*.json` and returns a map keyed by sessionId.
    /// Each running Claude process writes a small file here describing whether
    /// it is busy, waiting on a permission prompt, etc. Returns an empty map if
    /// the directory does not exist.
    func readLiveSessionStates(claudeDir: String) -> [String: LiveSessionState] {
        let sessionsDir = (claudeDir as NSString).appendingPathComponent("sessions")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: sessionsDir) else {
            return [:]
        }
        var result: [String: LiveSessionState] = [:]
        for entry in entries where entry.hasSuffix(".json") {
            let path = (sessionsDir as NSString).appendingPathComponent(entry)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionId = json["sessionId"] as? String,
                  let status = json["status"] as? String else {
                continue
            }
            let updatedAtMs = (json["updatedAt"] as? Double) ?? 0
            let state = LiveSessionState(
                sessionId: sessionId,
                status: status,
                waitingFor: json["waitingFor"] as? String,
                updatedAt: Date(timeIntervalSince1970: updatedAtMs / 1000.0)
            )
            // If multiple PIDs claim the same sessionId, prefer the most recent.
            if let existing = result[sessionId], existing.updatedAt > state.updatedAt { continue }
            result[sessionId] = state
        }
        return result
    }

    /// Returns the user-facing question string for a live waiting state, or nil
    /// if the live state is not a waiting state we should surface.
    func waitingQuestionText(for state: LiveSessionState) -> String? {
        guard state.status == "waiting" else { return nil }
        switch state.waitingFor {
        case "permission prompt":
            return "Permission prompt pending — see terminal"
        case .some(let other):
            return "Waiting on \(other) — see terminal"
        case .none:
            return "Waiting for input — see terminal"
        }
    }

    /// Applies the live-state overlay to a JSONL-derived session. Sessions whose
    /// owning Claude process is paused on a permission/user prompt are not
    /// reflected in the JSONL (the pending tool_use is buffered in memory), so
    /// this overlay is the only way to surface them.
    func applyingLiveStateOverlay(_ session: ClaudeSession, liveStates: [String: LiveSessionState]) -> ClaudeSession {
        guard let state = liveStates[session.id],
              let question = waitingQuestionText(for: state) else {
            return session
        }
        // Only override if the JSONL-derived status would mislead the user
        // (interrupted/inactive/idle). A running session whose live state is
        // momentarily "waiting" is already accurate enough to leave alone.
        switch session.status {
        case .waitingForQuestion:
            return session
        case .running, .waitingIdle, .interrupted, .inactive:
            var updated = session
            let since = max(state.updatedAt, session.lastModified)
            updated.status = .waitingForQuestion(since: since, question: question)
            return updated
        }
    }

    // MARK: - Project JSONL discovery

    /// Finds the most recent `.jsonl` file in each project subdirectory of `~/.claude/projects/`.
    func findProjectJSONLFiles(projectsDir: String) -> [String] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else {
            logger?.info("Cannot list contents of \(projectsDir)")
            return []
        }
        logger?.info("Project directories (\(projectDirs.count)): \(projectDirs)")

        var results: [String] = []
        for dir in projectDirs {
            let fullDir = (projectsDir as NSString).appendingPathComponent(dir)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullDir, isDirectory: &isDir), isDir.boolValue else { continue }

            guard let files = try? fm.contentsOfDirectory(atPath: fullDir) else { continue }
            let jsonlFiles = files.filter { $0.hasSuffix(".jsonl") }
            if jsonlFiles.isEmpty {
                logger?.debug("  \(dir): no .jsonl files")
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
                logger?.debug("  \(dir): selected \((path as NSString).lastPathComponent) (mod: \(bestDate!))")
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
            logger?.warning("Cannot read attributes for \(fileName)")
            return nil
        }

        // Read session metadata (cached).
        guard let meta = readFirstLineInfo(jsonlPath: jsonlPath) else {
            logger?.debug("Cannot extract session metadata from \(fileName), skipping")
            return nil
        }

        let cwd = meta.cwd
        let sessionId = meta.sessionId
        logger?.debug("Analyzing session \(sessionId): cwd=\(cwd)")

        // Parent's own status from its own JSONL tail. Subagents are detected
        // separately below and folded into the effective status via rollup.
        let tailLines = readTailLines(filePath: jsonlPath, lineCount: tailLineCount)
        logger?.debug("  Read \(tailLines.count) tail lines from \(fileName)")
        let ownStatus = determineStatus(tailLines: tailLines, lastModified: lastModified)
        logger?.debug("  Own status: \(ownStatus)")

        // Recursively detect subagents under <jsonlPath_without_ext>/subagents/.
        let subagentDirBase = (jsonlPath as NSString).deletingPathExtension
        let subagents = buildSubagents(parentJSONLPathWithoutExt: subagentDirBase)
        if !subagents.isEmpty {
            logger?.debug("  \(subagents.count) subagent(s) under \(fileName)")
        }

        // Effective status = highest-priority among self + all descendants.
        let status = rollUpStatus(ownStatus: ownStatus, subagents: subagents)
        let effectiveLastModified = max(lastModified, effectiveModDate(jsonlPath: jsonlPath) ?? lastModified)

        // Prefer git branch from JSONL metadata, fall back to .git/HEAD.
        let gitBranch = meta.gitBranch ?? GitHelper.readBranch(projectPath: cwd)

        // Read git status (working directory clean/dirty, ahead/behind counts).
        let gitStatus = GitHelper.readStatus(projectPath: cwd)

        // Read full task items and derive summary from them.
        let taskItems = readTaskItems(sessionId: sessionId, claudeDir: claudeDir)
        let taskSummary: TaskSummary? = taskItems.isEmpty ? nil : {
            let completed = taskItems.filter { $0.status == "completed" }.count
            let inProgress = taskItems.filter { $0.status == "in_progress" }.count
            let pending = taskItems.count - completed - inProgress
            return TaskSummary(total: taskItems.count, completed: completed, inProgress: inProgress, pending: pending)
        }()

        // Find PR URL.
        let prURL = findPullRequestURL(jsonlPath: jsonlPath)

        var session = ClaudeSession(
            id: sessionId,
            projectPath: cwd,
            gitBranch: gitBranch,
            gitStatus: gitStatus,
            slug: meta.slug,
            ownStatus: ownStatus,
            status: status,
            taskSummary: taskSummary,
            lastModified: effectiveLastModified
        )
        session.taskItems = taskItems
        session.pullRequestURL = prURL
        session.jsonlPath = jsonlPath
        session.subagents = subagents
        logger?.debug("  -> \(session.displayName) own=[\(ownStatus)] effective=[\(status)] subagents=\(subagents.count)")
        return session
    }

    // MARK: - Subagent detection

    /// Recursively enumerates `agent-*.jsonl` files under `<parentJSONLPath_without_ext>/subagents/`
    /// and builds `Subagent` values for each. Each subagent may itself have nested subagents
    /// under `<sub_without_ext>/subagents/`.
    func buildSubagents(parentJSONLPathWithoutExt: String) -> [Subagent] {
        let dir = parentJSONLPathWithoutExt + "/subagents"
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }

        var subs: [Subagent] = []
        for file in files where file.hasSuffix(".jsonl") {
            let path = (dir as NSString).appendingPathComponent(file)
            if let sub = analyzeSubagent(jsonlPath: path) {
                subs.append(sub)
            }
        }
        // Display in launch order (oldest first).
        return subs.sorted(by: { $0.lastModified < $1.lastModified })
    }

    /// Analyzes a single subagent JSONL. Pulls type/description from the `.meta.json`
    /// sidecar, slug from the JSONL's first user/assistant line, launch prompt from
    /// the first user message, status from the tail. Recurses into nested subagents.
    func analyzeSubagent(jsonlPath: String) -> Subagent? {
        let fm = FileManager.default
        let fileName = (jsonlPath as NSString).lastPathComponent

        // Parse agentId from `agent-<id>.jsonl`.
        guard fileName.hasPrefix("agent-"), fileName.hasSuffix(".jsonl") else { return nil }
        let agentId = String(fileName.dropFirst("agent-".count).dropLast(".jsonl".count))

        guard let attrs = try? fm.attributesOfItem(atPath: jsonlPath),
              let lastModified = attrs[.modificationDate] as? Date else {
            logger?.debug("Cannot read attributes for \(fileName)")
            return nil
        }

        // Cache by effective subtree mod date so descendant writes invalidate.
        let effectiveMod = effectiveModDate(jsonlPath: jsonlPath) ?? lastModified
        if let cached = subagentCache[jsonlPath], cached.modDate == effectiveMod {
            // Re-evaluate if running, to handle staleness transitions; otherwise reuse.
            if case .running = cached.subagent.status {
                logger?.debug("Re-evaluating running subagent: \(agentId)")
            } else {
                return cached.subagent
            }
        }

        // Slug from JSONL header line.
        let slug = readFirstLineInfo(jsonlPath: jsonlPath)?.slug

        // agentType + description from sidecar meta.json.
        let metaJSONPath = (jsonlPath as NSString).deletingPathExtension + ".meta.json"
        var subagentType: String?
        var taskDescription: String?
        if let data = fm.contents(atPath: metaJSONPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            subagentType = json["agentType"] as? String
            taskDescription = json["description"] as? String
        }

        // Launch prompt = first user message's content.
        let launchPrompt = readLaunchPrompt(jsonlPath: jsonlPath)

        // Status from tail.
        let tailLines = readTailLines(filePath: jsonlPath, lineCount: tailLineCount)
        let status = determineStatus(tailLines: tailLines, lastModified: lastModified)

        // Recurse into nested subagents.
        let nestedBase = (jsonlPath as NSString).deletingPathExtension
        let nested = buildSubagents(parentJSONLPathWithoutExt: nestedBase)

        let sub = Subagent(
            id: agentId,
            slug: slug,
            subagentType: subagentType,
            taskDescription: taskDescription,
            launchPrompt: launchPrompt,
            status: status,
            transcript: [],
            jsonlPath: jsonlPath,
            lastModified: lastModified,
            subagents: nested
        )
        subagentCache[jsonlPath] = (modDate: effectiveMod, subagent: sub)
        return sub
    }

    /// Reads the first `user`-typed line's `message.content` from a subagent JSONL and
    /// returns it as plain text. The first user line in a subagent JSONL is the launch
    /// prompt passed by the parent.
    func readLaunchPrompt(jsonlPath: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: jsonlPath) else { return nil }
        defer { handle.closeFile() }

        var accumulated = ""
        var linesScanned = 0
        let maxChunks = 10
        for _ in 0..<maxChunks {
            let data = handle.readData(ofLength: chunkSize)
            let atEOF = data.isEmpty
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                accumulated += str
            }
            let lines = accumulated.components(separatedBy: "\n")
            let completeLines = atEOF ? lines : Array(lines.dropLast())
            for line in completeLines {
                if linesScanned >= headScanLineCount { return nil }
                linesScanned += 1
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                guard let lineData = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }
                let type = json["type"] as? String
                let role = (json["message"] as? [String: Any])?["role"] as? String
                guard type == "user" || role == "user" else { continue }
                guard let message = json["message"] as? [String: Any] else { continue }
                if let str = message["content"] as? String {
                    return str
                }
                if let arr = message["content"] as? [[String: Any]] {
                    let parts = arr.compactMap { block -> String? in
                        guard (block["type"] as? String) == "text" else { return nil }
                        return block["text"] as? String
                    }
                    if !parts.isEmpty { return parts.joined(separator: "\n\n") }
                }
            }
            if atEOF { break }
            accumulated = lines.last ?? ""
        }
        return nil
    }

    /// Rolls up the parent's effective status as the highest-priority status across
    /// itself and all descendant subagents. Highest priority (lowest `sortPriority`)
    /// wins. The "since" timestamps from the parent's own waiting statuses are kept
    /// when the parent itself is the winner; otherwise the descendant's timestamp wins.
    func rollUpStatus(ownStatus: SessionStatus, subagents: [Subagent]) -> SessionStatus {
        let descendants = subagents.flatMap { $0.flattenedSelfAndDescendants }.map(\.status)
        let all = [ownStatus] + descendants
        return all.min(by: { $0.sortPriority < $1.sortPriority }) ?? ownStatus
    }

    /// Returns the max modification date across the main JSONL and any subagent JSONLs
    /// reachable through nested `subagents/` directories. Used as a cache key so that
    /// subagent writes invalidate the cached session.
    func effectiveModDate(jsonlPath: String) -> Date? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: jsonlPath),
              let mainMod = attrs[.modificationDate] as? Date else { return nil }
        let subagentDir = (jsonlPath as NSString).deletingPathExtension + "/subagents"
        if let subMax = maxJSONLModDate(in: subagentDir), subMax > mainMod {
            return subMax
        }
        return mainMod
    }

    /// Recursively finds the latest `.jsonl` modification date in `dir` and any nested
    /// `<file_without_ext>/subagents/` directories.
    private func maxJSONLModDate(in dir: String) -> Date? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        var best: Date?
        for file in files where file.hasSuffix(".jsonl") {
            let path = (dir as NSString).appendingPathComponent(file)
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let mod = attrs[.modificationDate] as? Date {
                if best == nil || mod > best! { best = mod }
            }
            let nestedDir = (path as NSString).deletingPathExtension + "/subagents"
            if let nested = maxJSONLModDate(in: nestedDir), best == nil || nested > best! {
                best = nested
            }
        }
        return best
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
            logger?.debug("Cannot open \(jsonlPath) for reading")
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
                    logger?.debug("Found session metadata on line \(linesScanned) (chunk \(chunkIndex)): id=\(info.sessionId), cwd=\(info.cwd), branch=\(info.gitBranch ?? "nil"), slug=\(info.slug ?? "nil")")
                    firstLineCache[jsonlPath] = info
                    return info
                }
            }

            if done || atEOF { break }

            // Keep only the incomplete last line for the next iteration.
            accumulated = lines.last ?? ""
        }

        logger?.debug("No session metadata found in first \(linesScanned) lines of \((jsonlPath as NSString).lastPathComponent)")
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

            logger?.debug("    tail line: type=\(type ?? "nil"), message.role=\(messageRole ?? "nil")")

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
                        logger?.debug("    -> interrupted (user interruption text)")
                        return .interrupted(lastActivity: lastModified)
                    }
                    if let contentArray = message["content"] as? [[String: Any]] {
                        // Check for rejected tool_result or interruption text
                        for block in contentArray {
                            if let blockType = block["type"] as? String {
                                if blockType == "text",
                                   let text = block["text"] as? String,
                                   text.contains("[Request interrupted by user") {
                                    logger?.debug("    -> interrupted (user interruption text in content block)")
                                    return .interrupted(lastActivity: lastModified)
                                }
                                if blockType == "tool_result",
                                   let content = block["content"] as? String,
                                   content.contains("user doesn't want to proceed") {
                                    logger?.debug("    -> interrupted (rejected tool use)")
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
                    logger?.debug("    -> interrupted (user message but file stale \(Int(staleness))s)")
                    return .interrupted(lastActivity: lastModified)
                }
                logger?.debug("    -> running (user message, file fresh)")
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
            logger?.debug("    assistant message has no content blocks -> waitingIdle")
            return .waitingIdle(since: lastModified)
        }

        let blockTypes = content.compactMap { $0["type"] as? String }
        let lastBlockName = (content.last?["name"] as? String) ?? "(none)"
        logger?.debug("    assistant content: \(content.count) blocks, types=\(blockTypes), lastTool=\(lastBlockName)")

        // Check if the last content block is a tool_use.
        if let lastBlock = content.last,
           let blockType = lastBlock["type"] as? String,
           blockType == "tool_use" {
            let toolName = lastBlock["name"] as? String ?? ""
            if toolName == "AskUserQuestion" || toolName == "TodoWrite" || toolName == "ExitPlanMode" {
                let question = extractQuestion(from: lastBlock)
                logger?.debug("    -> waitingForQuestion (tool=\(toolName), question=\(question ?? "nil"))")
                return .waitingForQuestion(since: lastModified, question: question)
            }
            // Agent/Task delegate work to a subagent — the parent JSONL won't update
            // until the subagent returns, so absence of a tool_result here means the
            // subagent is still running, not that the user must approve. The subagent's
            // own status is detected separately and folded in via rollup.
            if toolName == "Agent" || toolName == "Task" {
                logger?.debug("    -> running (delegating to \(toolName) subagent)")
                return .running
            }
            // If no tool_result follows this assistant tool_use AND the file is
            // stale (>3s), the tool is pending user approval — treat as needs input.
            if !toolResultFollows {
                let staleness = Date().timeIntervalSince(lastModified)
                if staleness > 3 {
                    logger?.debug("    -> waitingForQuestion (tool_use \(toolName) pending approval, file stale \(Int(staleness))s)")
                    return .waitingForQuestion(since: lastModified, question: "Approve \(toolName) tool use?")
                }
            }
            logger?.debug("    -> running (tool_use: \(toolName))")
            return .running
        }

        // Has content blocks but last one is text → finished output, waiting idle.
        let hasTextBlock = content.contains { ($0["type"] as? String) == "text" }
        if hasTextBlock {
            logger?.debug("    -> waitingIdle (text output, no pending tool)")
            return .waitingIdle(since: lastModified)
        }

        logger?.debug("    -> running (no text, no tool_use)")
        return .running
    }

    /// Extracts the prompt text shown to the user from a tool_use block —
    /// either an AskUserQuestion's question, or an ExitPlanMode's plan body.
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
        if let plan = input["plan"] as? String {
            let trimmed = plan.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
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
        logger?.info("readTaskSummary(\(sessionId)): after todosDir: total=\(total) completed=\(completed) inProgress=\(inProgress) pending=\(pending)")

        let sessionTasksDir = (tasksDir as NSString).appendingPathComponent(sessionId)
        readTasksFromDirectory(sessionTasksDir, sessionId: nil, total: &total, completed: &completed, inProgress: &inProgress, pending: &pending)
        logger?.info("readTaskSummary(\(sessionId)): after tasksDir: total=\(total) completed=\(completed) inProgress=\(inProgress) pending=\(pending)")

        // When tasks are completed, Claude Code deletes the JSON files and writes
        // a .highwatermark file containing the total task count. Account for
        // cleaned-up tasks by reading the highwatermark.
        let hwPath = (sessionTasksDir as NSString).appendingPathComponent(".highwatermark")
        if let hwStr = try? String(contentsOfFile: hwPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let hwTotal = Int(hwStr), hwTotal > total {
            let cleanedUp = hwTotal - total
            logger?.info("readTaskSummary(\(sessionId)): highwatermark=\(hwTotal), adding \(cleanedUp) cleaned-up tasks as completed")
            completed += cleanedUp
            total = hwTotal
        }

        guard total > 0 else { return nil }
        logger?.info("readTaskSummary(\(sessionId)): final total=\(total) completed=\(completed) inProgress=\(inProgress) pending=\(pending)")
        return TaskSummary(total: total, completed: completed, inProgress: inProgress, pending: pending)
    }

    private func readTasksFromDirectory(_ dir: String, sessionId: String?, total: inout Int, completed: inout Int, inProgress: inout Int, pending: inout Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else {
            logger?.info("readTasksFromDirectory: no directory at \(dir)")
            return
        }

        let dirName = (dir as NSString).lastPathComponent
        for file in files where file.hasSuffix(".json") {
            if let sid = sessionId, !file.hasPrefix(sid) { continue }
            logger?.info("readTasksFromDirectory(\(dirName)): processing \(file)")

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
            let jsonFiles = files.sorted().filter { $0.hasSuffix(".json") }
            logger?.info("readTaskItems(\(sessionId)): found \(jsonFiles.count) json files in tasksDir")
            for file in jsonFiles {
                let path = (sessionTasksDir as NSString).appendingPathComponent(file)
                if let item = parseTaskFile(path: path) {
                    logger?.info("readTaskItems(\(sessionId)):   task '\(item.subject)' status=\(item.status)")
                    items.append(item)
                }
            }
        } else {
            logger?.info("readTaskItems(\(sessionId)): no tasksDir at \(sessionTasksDir)")
        }

        // Read from todos/<sessionId>-*.json
        if let files = try? fm.contentsOfDirectory(atPath: todosDir) {
            let matching = files.sorted().filter { $0.hasSuffix(".json") && $0.hasPrefix(sessionId) }
            logger?.info("readTaskItems(\(sessionId)): found \(matching.count) matching json files in todosDir")
            for file in matching {
                let path = (todosDir as NSString).appendingPathComponent(file)
                if let data = fm.contents(atPath: path),
                   let json = try? JSONSerialization.jsonObject(with: data) {
                    if let tasks = json as? [[String: Any]] {
                        for task in tasks {
                            if let item = parseTaskJSON(task) {
                                logger?.info("readTaskItems(\(sessionId)):   todo '\(item.subject)' status=\(item.status)")
                                items.append(item)
                            }
                        }
                    } else if let task = json as? [String: Any] {
                        if let item = parseTaskJSON(task) {
                            logger?.info("readTaskItems(\(sessionId)):   todo '\(item.subject)' status=\(item.status)")
                            items.append(item)
                        }
                    }
                }
            }
        } else {
            logger?.info("readTaskItems(\(sessionId)): no todosDir at \(todosDir)")
        }

        logger?.info("readTaskItems(\(sessionId)): returning \(items.count) items total")
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
        // tasks/ files use "subject", todos/ files use "content"
        guard let subject = (json["subject"] as? String) ?? (json["content"] as? String) else { return nil }
        let id = (json["id"] as? String) ?? UUID().uuidString
        let description = json["description"] as? String
        let status = (json["status"] as? String) ?? "pending"
        let activeForm = json["activeForm"] as? String
        return TaskItem(id: id, subject: subject, description: description, status: status, activeForm: activeForm)
    }

    // MARK: - Transcript reading

    /// Reads the full conversation transcript from a JSONL file using streaming.
    /// The optional `onProgress` callback reports 0.0–1.0 based on bytes read.
    func readTranscript(jsonlPath: String, onProgress: ((Double) -> Void)? = nil) -> [TranscriptMessage] {
        guard let handle = FileHandle(forReadingAtPath: jsonlPath) else {
            logger?.warning("readTranscript: cannot open \(jsonlPath)")
            return []
        }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        handle.seek(toFileOffset: 0)
        logger?.info("readTranscript: reading \(fileSize) bytes from \((jsonlPath as NSString).lastPathComponent)")

        var messages: [TranscriptMessage] = []
        var linesRead = 0
        var linesSkipped = 0
        var bytesRead: UInt64 = 0
        var buffer = ""

        // Read in chunks and process line by line.
        let readChunkSize = 65536
        while true {
            let data = handle.readData(ofLength: readChunkSize)
            if data.isEmpty { break }
            guard let chunk = String(data: data, encoding: .utf8) else { continue }
            buffer += chunk
            bytesRead += UInt64(data.count)
            if fileSize > 0 {
                onProgress?(Double(bytesRead) / Double(fileSize))
            }

            // Process complete lines.
            while let newlineRange = buffer.range(of: "\n") {
                let line = String(buffer[buffer.startIndex..<newlineRange.lowerBound])
                buffer = String(buffer[newlineRange.upperBound...])

                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                linesRead += 1

                // Fast pre-filter: skip known non-message types without JSON parsing.
                if trimmed.contains("\"progress\"") && !trimmed.contains("\"role\"") {
                    linesSkipped += 1
                    continue
                }
                if trimmed.contains("\"file-history-snapshot\"") || trimmed.contains("\"queue-operation\"") {
                    linesSkipped += 1
                    continue
                }

                guard let lineData = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }

                let type = json["type"] as? String
                if type == "progress" || type == "system" || type == "file-history-snapshot"
                    || type == "queue-operation" {
                    linesSkipped += 1
                    continue
                }

                if let msg = transcriptMessage(from: json) {
                    messages.append(msg)
                }
            }
        }

        // Process any remaining content in buffer (last line without trailing newline).
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            linesRead += 1
            if let lineData = trimmed.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               let msg = transcriptMessage(from: json) {
                messages.append(msg)
            }
        }

        logger?.info("readTranscript: \(messages.count) messages from \(linesRead) lines (\(linesSkipped) skipped)")
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

    /// Builds a TranscriptMessage from one parsed JSONL line, or nil if the
    /// line has no displayable content.
    private func transcriptMessage(from json: [String: Any]) -> TranscriptMessage? {
        guard let message = json["message"] as? [String: Any],
              let role = message["role"] as? String else {
            return nil
        }

        let uuid = (json["uuid"] as? String) ?? UUID().uuidString
        let timestamp = parseTimestamp(json["timestamp"] as? String)

        var textParts: [String] = []
        var toolCalls: [ToolCallSummary] = []
        var askAnswers: [AskUserAnswer] = []

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
                    let input = block["input"] as? [String: Any]
                    let summary = toolCallSummary(name: name, input: input)
                    let questions = name == "AskUserQuestion"
                        ? askUserQuestions(from: input)
                        : []
                    toolCalls.append(ToolCallSummary(
                        name: name,
                        summary: summary,
                        askQuestions: questions
                    ))
                } else if blockType == "tool_result" {
                    if let contentStr = block["content"] as? String,
                       let answer = parseAskUserAnswer(contentStr) {
                        askAnswers.append(answer)
                    }
                }
            }
        }

        if textParts.isEmpty && toolCalls.isEmpty && askAnswers.isEmpty {
            return nil
        }

        return TranscriptMessage(
            id: uuid,
            role: role,
            text: textParts.joined(separator: "\n\n"),
            timestamp: timestamp,
            toolCalls: toolCalls,
            askAnswers: askAnswers
        )
    }

    func toolCallSummary(name: String, input: [String: Any]?) -> String? {
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
        case "ExitPlanMode":
            guard let plan = input["plan"] as? String else { return nil }
            let trimmed = plan.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default:
            return nil
        }
    }

    /// Extracts structured questions + options from an AskUserQuestion input.
    private func askUserQuestions(from input: [String: Any]?) -> [AskUserQuestionContent] {
        guard let questions = input?["questions"] as? [[String: Any]] else { return [] }
        return questions.compactMap { q in
            guard let text = q["question"] as? String else { return nil }
            let options: [AskUserQuestionContent.Option] = (q["options"] as? [[String: Any]] ?? []).compactMap { opt in
                guard let label = opt["label"] as? String else { return nil }
                return AskUserQuestionContent.Option(
                    label: label,
                    description: opt["description"] as? String
                )
            }
            return AskUserQuestionContent(
                question: text,
                header: q["header"] as? String,
                multiSelect: (q["multiSelect"] as? Bool) ?? false,
                options: options
            )
        }
    }

    /// Parses the synthetic `User has answered your questions: "Q"="A"...`
    /// content the harness emits for AskUserQuestion tool_results.
    private func parseAskUserAnswer(_ content: String) -> AskUserAnswer? {
        let marker = "User has answered your questions:"
        guard let markerRange = content.range(of: marker) else { return nil }
        let body = content[markerRange.upperBound...]

        // Find the first "Q"="A" pair. Both sides are double-quoted in the harness output.
        guard let qOpen = body.firstIndex(of: "\""),
              let qClose = body[body.index(after: qOpen)...].firstIndex(of: "\"") else {
            return nil
        }
        let question = String(body[body.index(after: qOpen)..<qClose])

        let afterQ = body[body.index(after: qClose)...]
        guard let eq = afterQ.firstIndex(of: "="),
              let aOpen = afterQ[afterQ.index(after: eq)...].firstIndex(of: "\""),
              let aClose = afterQ[afterQ.index(after: aOpen)...].firstIndex(of: "\"") else {
            return nil
        }
        let selection = String(afterQ[afterQ.index(after: aOpen)..<aClose])

        let rest = String(afterQ[afterQ.index(after: aClose)...])
        // Notes are short, single-line; stop at sentence end, newline, or result-id.
        let notes = extract(after: "user notes:", in: rest, stoppingAt: [". ", "\n", "[result-id"])
        // Preview is a multi-line code block; only stop at the result-id sentinel.
        let preview = extract(after: "selected preview:", in: rest, stoppingAt: ["[result-id"])
        return AskUserAnswer(
            question: question,
            selection: selection,
            notes: notes,
            preview: preview
        )
    }

    /// Returns trimmed text following `marker` up to the earliest of the given
    /// sentinels (or end of string). Returns nil if the marker is absent or the
    /// captured text is empty.
    private func extract(after marker: String, in text: String, stoppingAt sentinels: [String]) -> String? {
        guard let range = text.range(of: marker) else { return nil }
        let tail = text[range.upperBound...]
        var endIndex = tail.endIndex
        for sentinel in sentinels {
            if let r = tail.range(of: sentinel), r.lowerBound < endIndex {
                endIndex = r.lowerBound
            }
        }
        let captured = tail[..<endIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        return captured.isEmpty ? nil : captured
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
