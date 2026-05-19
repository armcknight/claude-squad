import XCTest
@testable import ClaudeSquad

final class ClaudeSessionDetectorTests: XCTestCase {

    let detector = ClaudeSessionDetector()

    // MARK: - JSONL tail reading

    func test_readTailLinesFromSmallFile() throws {
        let tempDir = NSTemporaryDirectory()
        let path = (tempDir as NSString).appendingPathComponent("test_tail_\(UUID().uuidString).jsonl")
        let lines = (1...5).map { "{\"line\": \($0)}" }
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = detector.readTailLines(filePath: path, lineCount: 3)
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result.last!.contains("\"line\": 5"))
    }

    func test_readTailLinesFromLargeFile() throws {
        let tempDir = NSTemporaryDirectory()
        let path = (tempDir as NSString).appendingPathComponent("test_tail_large_\(UUID().uuidString).jsonl")
        let lines = (1...500).map { "{\"line\": \($0), \"padding\": \"\(String(repeating: "x", count: 100))\"}" }
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = detector.readTailLines(filePath: path, lineCount: 20)
        XCTAssertEqual(result.count, 20)
        XCTAssertTrue(result.last!.contains("\"line\": 500"))
        XCTAssertTrue(result.first!.contains("\"line\": 481"))
    }

    func test_readTailLinesFromEmptyFile() throws {
        let tempDir = NSTemporaryDirectory()
        let path = (tempDir as NSString).appendingPathComponent("test_tail_empty_\(UUID().uuidString).jsonl")
        try "".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = detector.readTailLines(filePath: path, lineCount: 10)
        XCTAssertTrue(result.isEmpty)
    }

    func test_readTailLinesNonexistentFile() {
        let result = detector.readTailLines(filePath: "/nonexistent/path.jsonl", lineCount: 10)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Status determination (real JSONL format: type at top level, content inside message)

    func test_assistantTextMeansWaitingIdle() {
        let lastModified = Date()
        let lines = [
            "{\"type\": \"assistant\", \"message\": {\"role\": \"assistant\", \"content\": [{\"type\": \"text\", \"text\": \"Done!\"}]}}"
        ]
        let status = detector.determineStatus(tailLines: lines, lastModified: lastModified)
        if case .waitingIdle = status {
            // pass
        } else {
            XCTFail("Expected waitingIdle, got \(status)")
        }
    }

    func test_askUserQuestionMeansWaitingForQuestion() {
        let lastModified = Date()
        let lines = [
            """
            {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "name": "AskUserQuestion", "input": {"questions": [{"question": "Which approach?"}]}}]}}
            """
        ]
        let status = detector.determineStatus(tailLines: lines, lastModified: lastModified)
        if case .waitingForQuestion(_, let question) = status {
            XCTAssertEqual(question, "Which approach?")
        } else {
            XCTFail("Expected waitingForQuestion, got \(status)")
        }
    }

    func test_userMessageMeansRunning() {
        let lastModified = Date()
        let lines = [
            "{\"type\": \"assistant\", \"message\": {\"role\": \"assistant\", \"content\": [{\"type\": \"text\", \"text\": \"Ok\"}]}}",
            "{\"type\": \"user\", \"message\": {\"role\": \"user\", \"content\": \"do it\"}}"
        ]
        let status = detector.determineStatus(tailLines: lines, lastModified: lastModified)
        if case .running = status {
            // pass
        } else {
            XCTFail("Expected running, got \(status)")
        }
    }

    func test_otherToolUseMeansRunning() {
        let lastModified = Date()
        let lines = [
            "{\"type\": \"assistant\", \"message\": {\"role\": \"assistant\", \"content\": [{\"type\": \"tool_use\", \"name\": \"Bash\", \"input\": {}}]}}"
        ]
        let status = detector.determineStatus(tailLines: lines, lastModified: lastModified)
        if case .running = status {
            // pass
        } else {
            XCTFail("Expected running, got \(status)")
        }
    }

    func test_emptyLinesMeansInactive() {
        let lastModified = Date()
        let status = detector.determineStatus(tailLines: [], lastModified: lastModified)
        if case .inactive = status {
            // pass
        } else {
            XCTFail("Expected inactive, got \(status)")
        }
    }

    func test_fileHistorySnapshotIsSkipped() {
        let lastModified = Date()
        let lines = [
            "{\"type\": \"file-history-snapshot\", \"messageId\": \"abc\"}",
            "{\"type\": \"assistant\", \"message\": {\"role\": \"assistant\", \"content\": [{\"type\": \"text\", \"text\": \"Done!\"}]}}"
        ]
        let status = detector.determineStatus(tailLines: lines, lastModified: lastModified)
        if case .waitingIdle = status {
            // pass — skipped the snapshot, found the assistant text
        } else {
            XCTFail("Expected waitingIdle, got \(status)")
        }
    }

    func test_userMessageWithToolResultMeansRunning() {
        let lastModified = Date()
        let lines = [
            "{\"type\": \"assistant\", \"message\": {\"role\": \"assistant\", \"content\": [{\"type\": \"tool_use\", \"name\": \"Bash\"}]}}",
            "{\"type\": \"user\", \"message\": {\"role\": \"user\", \"content\": [{\"type\": \"tool_result\", \"content\": \"output\"}]}}"
        ]
        let status = detector.determineStatus(tailLines: lines, lastModified: lastModified)
        if case .running = status {
            // pass — tool_result in a user message means Claude is processing
        } else {
            XCTFail("Expected running, got \(status)")
        }
    }

    // MARK: - Session metadata parsing

    func test_parseSessionMetadataWithAllFields() {
        let line = "{\"type\": \"user\", \"cwd\": \"/Users/test/project\", \"sessionId\": \"abc-123\", \"gitBranch\": \"main\", \"slug\": \"cool-slug\"}"
        let info = detector.parseSessionMetadata(line)
        XCTAssertEqual(info?.cwd, "/Users/test/project")
        XCTAssertEqual(info?.sessionId, "abc-123")
        XCTAssertEqual(info?.gitBranch, "main")
        XCTAssertEqual(info?.slug, "cool-slug")
    }

    func test_parseSessionMetadataWithSessionIdUnderscore() {
        let line = "{\"type\": \"assistant\", \"cwd\": \"/Users/test/project\", \"session_id\": \"def-456\"}"
        let info = detector.parseSessionMetadata(line)
        XCTAssertEqual(info?.cwd, "/Users/test/project")
        XCTAssertEqual(info?.sessionId, "def-456")
    }

    func test_parseSessionMetadataSkipsFileHistorySnapshot() {
        let line = "{\"type\": \"file-history-snapshot\", \"messageId\": \"abc\"}"
        let info = detector.parseSessionMetadata(line)
        XCTAssertNil(info)
    }

    func test_parseSessionMetadataSkipsProgress() {
        let line = "{\"type\": \"progress\", \"data\": {}}"
        let info = detector.parseSessionMetadata(line)
        XCTAssertNil(info)
    }

    func test_parseSessionMetadataSkipsSystem() {
        let line = "{\"type\": \"system\", \"data\": {}}"
        let info = detector.parseSessionMetadata(line)
        XCTAssertNil(info)
    }

    func test_parseSessionMetadataWithoutCwdReturnsNil() {
        let line = "{\"type\": \"user\", \"sessionId\": \"abc-123\"}"
        let info = detector.parseSessionMetadata(line)
        XCTAssertNil(info)
    }

    func test_parseSessionMetadataWithoutSessionIdReturnsNil() {
        let line = "{\"type\": \"user\", \"cwd\": \"/Users/test/project\"}"
        let info = detector.parseSessionMetadata(line)
        XCTAssertNil(info)
    }

    // MARK: - readFirstLineInfo with real JSONL structure

    func test_readFirstLineInfoSkipsSnapshotLine() throws {
        let tempDir = NSTemporaryDirectory()
        let path = (tempDir as NSString).appendingPathComponent("test_meta_\(UUID().uuidString).jsonl")
        let lines = [
            "{\"type\": \"file-history-snapshot\", \"messageId\": \"abc\"}",
            "{\"type\": \"user\", \"cwd\": \"/Users/test/project\", \"sessionId\": \"abc-123\", \"gitBranch\": \"main\", \"slug\": \"my-slug\", \"message\": {\"role\": \"user\", \"content\": \"hello\"}}"
        ]
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let info = detector.readFirstLineInfo(jsonlPath: path)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.cwd, "/Users/test/project")
        XCTAssertEqual(info?.sessionId, "abc-123")
        XCTAssertEqual(info?.gitBranch, "main")
        XCTAssertEqual(info?.slug, "my-slug")
    }

    // MARK: - Question extraction

    func test_extractQuestionFromQuestionsArray() {
        let block: [String: Any] = [
            "type": "tool_use",
            "name": "AskUserQuestion",
            "input": [
                "questions": [
                    ["question": "Which library?", "options": []]
                ]
            ]
        ]
        let question = detector.extractQuestion(from: block)
        XCTAssertEqual(question, "Which library?")
    }

    func test_extractQuestionFromSimpleInput() {
        let block: [String: Any] = [
            "type": "tool_use",
            "name": "AskUserQuestion",
            "input": ["question": "Continue?"]
        ]
        let question = detector.extractQuestion(from: block)
        XCTAssertEqual(question, "Continue?")
    }

    // MARK: - Task summary reading

    func test_readTaskSummaryFromTodosDir() throws {
        let tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("claude_test_\(UUID().uuidString)")
        let todosDir = (tempDir as NSString).appendingPathComponent("todos")
        try FileManager.default.createDirectory(atPath: todosDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tasks: [[String: Any]] = [
            ["subject": "Task 1", "status": "completed"],
            ["subject": "Task 2", "status": "in_progress"],
            ["subject": "Task 3", "status": "pending"]
        ]
        let data = try JSONSerialization.data(withJSONObject: tasks)
        let filePath = (todosDir as NSString).appendingPathComponent("test-session-agent-todos.json")
        try data.write(to: URL(fileURLWithPath: filePath))

        let summary = detector.readTaskSummary(sessionId: "test-session", claudeDir: tempDir)
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.total, 3)
        XCTAssertEqual(summary?.completed, 1)
        XCTAssertEqual(summary?.inProgress, 1)
        XCTAssertEqual(summary?.pending, 1)
    }

    func test_readTaskSummaryReturnsNilWhenNoTasks() {
        let summary = detector.readTaskSummary(sessionId: "nonexistent", claudeDir: "/nonexistent")
        XCTAssertNil(summary)
    }

    // MARK: - Git branch reading

    func test_readGitBranchFromHEAD() throws {
        let tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("git_test_\(UUID().uuidString)")
        let gitDir = (tempDir as NSString).appendingPathComponent(".git")
        try FileManager.default.createDirectory(atPath: gitDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        try "ref: refs/heads/feature/cool-thing\n".write(
            toFile: (gitDir as NSString).appendingPathComponent("HEAD"),
            atomically: true, encoding: .utf8
        )

        let branch = GitHelper.readBranch(projectPath: tempDir)
        XCTAssertEqual(branch, "feature/cool-thing")
    }

    func test_readGitBranchDetachedHEAD() throws {
        let tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("git_test_\(UUID().uuidString)")
        let gitDir = (tempDir as NSString).appendingPathComponent(".git")
        try FileManager.default.createDirectory(atPath: gitDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        try "abc123def456\n".write(
            toFile: (gitDir as NSString).appendingPathComponent("HEAD"),
            atomically: true, encoding: .utf8
        )

        let branch = GitHelper.readBranch(projectPath: tempDir)
        XCTAssertNil(branch)
    }

    func test_readGitBranchNoGitDir() {
        let branch = GitHelper.readBranch(projectPath: "/nonexistent/path")
        XCTAssertNil(branch)
    }

    // MARK: - Subagent delegation

    func test_isWaitingOnSubagent_trueForAgentToolUseWithoutResult() {
        let lines = [
            "{\"type\": \"assistant\", \"message\": {\"role\": \"assistant\", \"content\": [{\"type\": \"tool_use\", \"name\": \"Agent\", \"id\": \"toolu_x\"}]}}"
        ]
        XCTAssertTrue(detector.isWaitingOnSubagent(tailLines: lines))
    }

    func test_isWaitingOnSubagent_trueForTaskToolUseWithoutResult() {
        let lines = [
            "{\"type\": \"assistant\", \"message\": {\"role\": \"assistant\", \"content\": [{\"type\": \"tool_use\", \"name\": \"Task\", \"id\": \"toolu_y\"}]}}"
        ]
        XCTAssertTrue(detector.isWaitingOnSubagent(tailLines: lines))
    }

    func test_isWaitingOnSubagent_falseWhenToolResultFollows() {
        let lines = [
            "{\"type\": \"assistant\", \"message\": {\"role\": \"assistant\", \"content\": [{\"type\": \"tool_use\", \"name\": \"Agent\", \"id\": \"toolu_x\"}]}}",
            "{\"type\": \"user\", \"message\": {\"role\": \"user\", \"content\": [{\"type\": \"tool_result\", \"tool_use_id\": \"toolu_x\", \"content\": \"done\"}]}}"
        ]
        XCTAssertFalse(detector.isWaitingOnSubagent(tailLines: lines))
    }

    func test_isWaitingOnSubagent_falseForNonAgentTool() {
        let lines = [
            "{\"type\": \"assistant\", \"message\": {\"role\": \"assistant\", \"content\": [{\"type\": \"tool_use\", \"name\": \"Bash\", \"id\": \"toolu_z\"}]}}"
        ]
        XCTAssertFalse(detector.isWaitingOnSubagent(tailLines: lines))
    }

    func test_isWaitingOnSubagent_falseForTextOnly() {
        let lines = [
            "{\"type\": \"assistant\", \"message\": {\"role\": \"assistant\", \"content\": [{\"type\": \"text\", \"text\": \"hi\"}]}}"
        ]
        XCTAssertFalse(detector.isWaitingOnSubagent(tailLines: lines))
    }

    func test_freshestSubagentJSONL_picksMostRecent() throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("subagent_test_\(UUID().uuidString)")
        let mainPath = root + ".jsonl"
        let subDir = (root as NSString).appendingPathComponent("subagents")
        try FileManager.default.createDirectory(atPath: subDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root)
                try? FileManager.default.removeItem(atPath: mainPath) }

        try "{}\n".write(toFile: mainPath, atomically: true, encoding: .utf8)
        let older = (subDir as NSString).appendingPathComponent("agent-older.jsonl")
        let newer = (subDir as NSString).appendingPathComponent("agent-newer.jsonl")
        try "{}\n".write(toFile: older, atomically: true, encoding: .utf8)
        try "{}\n".write(toFile: newer, atomically: true, encoding: .utf8)
        // Force the older file's modification date into the past.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: older)

        let result = detector.freshestSubagentJSONL(parentJSONLPath: mainPath)
        XCTAssertEqual(result?.path, newer)
    }

    func test_freshestSubagentJSONL_nilWhenNoSubagentDir() {
        let result = detector.freshestSubagentJSONL(parentJSONLPath: "/nonexistent/foo.jsonl")
        XCTAssertNil(result)
    }

    func test_effectiveModDate_usesSubagentWhenNewer() throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("effmod_test_\(UUID().uuidString)")
        let mainPath = root + ".jsonl"
        let subDir = (root as NSString).appendingPathComponent("subagents")
        try FileManager.default.createDirectory(atPath: subDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root)
                try? FileManager.default.removeItem(atPath: mainPath) }

        try "{}\n".write(toFile: mainPath, atomically: true, encoding: .utf8)
        // Backdate the main file by an hour.
        let mainDate = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: mainDate], ofItemAtPath: mainPath)
        let sub = (subDir as NSString).appendingPathComponent("agent-fresh.jsonl")
        try "{}\n".write(toFile: sub, atomically: true, encoding: .utf8)
        let subDate = Date()
        try FileManager.default.setAttributes([.modificationDate: subDate], ofItemAtPath: sub)

        let result = detector.effectiveModDate(jsonlPath: mainPath)
        XCTAssertNotNil(result)
        // Should be approximately the subagent's mtime, not the main's.
        if let result {
            XCTAssertLessThan(abs(result.timeIntervalSince(subDate)), 2)
            XCTAssertGreaterThan(result.timeIntervalSince(mainDate), 1800)
        }
    }

    func test_resolveStatusSource_descendsIntoActiveSubagent() throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("resolve_test_\(UUID().uuidString)")
        let mainPath = root + ".jsonl"
        let subDir = (root as NSString).appendingPathComponent("subagents")
        try FileManager.default.createDirectory(atPath: subDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root)
                try? FileManager.default.removeItem(atPath: mainPath) }

        // Main: last assistant block is an Agent tool_use with no following tool_result.
        let mainContent = "{\"type\": \"assistant\", \"message\": {\"role\": \"assistant\", \"content\": [{\"type\": \"tool_use\", \"name\": \"Agent\", \"id\": \"toolu_main\"}]}}\n"
        try mainContent.write(toFile: mainPath, atomically: true, encoding: .utf8)
        // Subagent: actively writing — last line is a Bash tool_use.
        let subPath = (subDir as NSString).appendingPathComponent("agent-active.jsonl")
        let subContent = "{\"type\": \"assistant\", \"message\": {\"role\": \"assistant\", \"content\": [{\"type\": \"tool_use\", \"name\": \"Bash\", \"id\": \"toolu_bash\"}]}}\n"
        try subContent.write(toFile: subPath, atomically: true, encoding: .utf8)

        let resolved = detector.resolveStatusSource(jsonlPath: mainPath, fallbackModDate: Date())
        XCTAssertEqual(resolved.path, subPath)
    }

    func test_resolveStatusSource_staysOnMainWhenNotWaitingOnSubagent() throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("resolve_test2_\(UUID().uuidString)")
        let mainPath = root + ".jsonl"
        defer { try? FileManager.default.removeItem(atPath: mainPath) }

        // Main: last assistant block is plain text.
        let mainContent = "{\"type\": \"assistant\", \"message\": {\"role\": \"assistant\", \"content\": [{\"type\": \"text\", \"text\": \"hi\"}]}}\n"
        try mainContent.write(toFile: mainPath, atomically: true, encoding: .utf8)

        let resolved = detector.resolveStatusSource(jsonlPath: mainPath, fallbackModDate: Date())
        XCTAssertEqual(resolved.path, mainPath)
    }
}
