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

    // MARK: - Subagent detection

    /// Helper: build a minimal session JSONL with the given trailing assistant
    /// content block, plus subagent JSONLs as described, and run the detector
    /// against it. Returns the resulting `ClaudeSession`.
    private func makeSessionTree(
        parentLastBlock: String,
        subagents: [(agentId: String, agentType: String, description: String, slug: String, lastBlock: String, nested: [(agentId: String, agentType: String, description: String, slug: String, lastBlock: String)])] = []
    ) throws -> (session: ClaudeSession, root: String) {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("detector_test_\(UUID().uuidString)")
        let mainPath = root + ".jsonl"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

        let parentLines = [
            "{\"type\":\"user\",\"cwd\":\"/tmp/test-proj\",\"sessionId\":\"sess1\",\"message\":{\"role\":\"user\",\"content\":\"go\"}}",
            "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[\(parentLastBlock)]}}"
        ]
        try parentLines.joined(separator: "\n").write(toFile: mainPath, atomically: true, encoding: .utf8)

        if !subagents.isEmpty {
            let subDir = (root as NSString).appendingPathComponent("subagents")
            try FileManager.default.createDirectory(atPath: subDir, withIntermediateDirectories: true)
            for sub in subagents {
                let subPath = (subDir as NSString).appendingPathComponent("agent-\(sub.agentId).jsonl")
                let metaPath = (subDir as NSString).appendingPathComponent("agent-\(sub.agentId).meta.json")
                let subLines = [
                    "{\"type\":\"user\",\"isSidechain\":true,\"cwd\":\"/tmp/test-proj\",\"sessionId\":\"sess1\",\"agentId\":\"\(sub.agentId)\",\"slug\":\"\(sub.slug)\",\"message\":{\"role\":\"user\",\"content\":\"launch prompt for \(sub.agentId)\"}}",
                    "{\"type\":\"assistant\",\"isSidechain\":true,\"agentId\":\"\(sub.agentId)\",\"message\":{\"role\":\"assistant\",\"content\":[\(sub.lastBlock)]}}"
                ]
                try subLines.joined(separator: "\n").write(toFile: subPath, atomically: true, encoding: .utf8)
                let metaJSON = "{\"agentType\":\"\(sub.agentType)\",\"description\":\"\(sub.description)\"}"
                try metaJSON.write(toFile: metaPath, atomically: true, encoding: .utf8)

                if !sub.nested.isEmpty {
                    let nestedDir = (subDir as NSString).appendingPathComponent("agent-\(sub.agentId)/subagents")
                    try FileManager.default.createDirectory(atPath: nestedDir, withIntermediateDirectories: true)
                    for n in sub.nested {
                        let nPath = (nestedDir as NSString).appendingPathComponent("agent-\(n.agentId).jsonl")
                        let nMeta = (nestedDir as NSString).appendingPathComponent("agent-\(n.agentId).meta.json")
                        let nLines = [
                            "{\"type\":\"user\",\"isSidechain\":true,\"cwd\":\"/tmp/test-proj\",\"sessionId\":\"sess1\",\"agentId\":\"\(n.agentId)\",\"slug\":\"\(n.slug)\",\"message\":{\"role\":\"user\",\"content\":\"launch prompt for \(n.agentId)\"}}",
                            "{\"type\":\"assistant\",\"isSidechain\":true,\"agentId\":\"\(n.agentId)\",\"message\":{\"role\":\"assistant\",\"content\":[\(n.lastBlock)]}}"
                        ]
                        try nLines.joined(separator: "\n").write(toFile: nPath, atomically: true, encoding: .utf8)
                        let nMetaJSON = "{\"agentType\":\"\(n.agentType)\",\"description\":\"\(n.description)\"}"
                        try nMetaJSON.write(toFile: nMeta, atomically: true, encoding: .utf8)
                    }
                }
            }
        }

        // Touch parent JSONL so it appears fresh enough for "running" status when
        // its last block is a still-pending tool_use.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: mainPath)

        guard let session = detector.analyzeSession(jsonlPath: mainPath, claudeDir: "/tmp/no-claude-dir") else {
            throw NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "analyzeSession returned nil"])
        }
        return (session, root)
    }

    func test_subagents_areDetectedWithMetadata() throws {
        let (session, root) = try makeSessionTree(
            parentLastBlock: "{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Agent\"}",
            subagents: [
                (agentId: "subA", agentType: "Explore", description: "look around",
                 slug: "twilight-coral-fern",
                 lastBlock: "{\"type\":\"tool_use\",\"name\":\"Bash\",\"id\":\"x\"}",
                 nested: [])
            ]
        )
        defer { try? FileManager.default.removeItem(atPath: root)
                try? FileManager.default.removeItem(atPath: root + ".jsonl") }

        XCTAssertEqual(session.subagents.count, 1)
        let sub = session.subagents[0]
        XCTAssertEqual(sub.id, "subA")
        XCTAssertEqual(sub.subagentType, "Explore")
        XCTAssertEqual(sub.taskDescription, "look around")
        XCTAssertEqual(sub.slug, "twilight-coral-fern")
        XCTAssertEqual(sub.launchPrompt, "launch prompt for subA")
        XCTAssertEqual(sub.displayLabel, "Explore · twilight-coral-fern")
    }

    func test_subagents_areDetectedRecursively() throws {
        let (session, root) = try makeSessionTree(
            parentLastBlock: "{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Agent\"}",
            subagents: [
                (agentId: "outerSub", agentType: "Explore", description: "outer",
                 slug: "outer-slug",
                 lastBlock: "{\"type\":\"tool_use\",\"name\":\"Agent\",\"id\":\"x\"}",
                 nested: [
                    (agentId: "innerSub", agentType: "general-purpose", description: "inner",
                     slug: "inner-slug",
                     lastBlock: "{\"type\":\"tool_use\",\"name\":\"Bash\",\"id\":\"y\"}")
                 ])
            ]
        )
        defer { try? FileManager.default.removeItem(atPath: root)
                try? FileManager.default.removeItem(atPath: root + ".jsonl") }

        XCTAssertEqual(session.subagents.count, 1)
        let outer = session.subagents[0]
        XCTAssertEqual(outer.id, "outerSub")
        XCTAssertEqual(outer.subagents.count, 1)
        XCTAssertEqual(outer.subagents[0].id, "innerSub")
        XCTAssertEqual(outer.subagents[0].subagentType, "general-purpose")
    }

    func test_rollUpStatus_picksHighestPriorityDescendant() throws {
        // Parent: Agent tool_use, fresh → ownStatus = running.
        // Subagent: AskUserQuestion → waitingForQuestion.
        let askBlock = "{\"type\":\"tool_use\",\"name\":\"AskUserQuestion\",\"id\":\"q\",\"input\":{\"questions\":[{\"question\":\"pick?\"}]}}"
        let (session, root) = try makeSessionTree(
            parentLastBlock: "{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Agent\"}",
            subagents: [
                (agentId: "sub1", agentType: "general-purpose", description: "ask",
                 slug: "slug1", lastBlock: askBlock, nested: [])
            ]
        )
        defer { try? FileManager.default.removeItem(atPath: root)
                try? FileManager.default.removeItem(atPath: root + ".jsonl") }

        // Parent's own status is running (Agent tool_use, fresh).
        if case .running = session.ownStatus { } else {
            XCTFail("parent ownStatus should be running, got \(session.ownStatus)")
        }
        // Effective status rolls up to waitingForQuestion from the subagent.
        if case .waitingForQuestion = session.status { } else {
            XCTFail("rolled-up status should be waitingForQuestion, got \(session.status)")
        }
    }

    func test_rollUpStatus_picksFromDeeplyNestedDescendant() throws {
        let askBlock = "{\"type\":\"tool_use\",\"name\":\"AskUserQuestion\",\"id\":\"q\",\"input\":{\"questions\":[{\"question\":\"pick?\"}]}}"
        let (session, root) = try makeSessionTree(
            parentLastBlock: "{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Agent\"}",
            subagents: [
                (agentId: "outerSub", agentType: "Explore", description: "outer",
                 slug: "outer-slug",
                 lastBlock: "{\"type\":\"tool_use\",\"name\":\"Agent\",\"id\":\"x\"}",
                 nested: [
                    (agentId: "innerSub", agentType: "general-purpose", description: "inner",
                     slug: "inner-slug", lastBlock: askBlock)
                 ])
            ]
        )
        defer { try? FileManager.default.removeItem(atPath: root)
                try? FileManager.default.removeItem(atPath: root + ".jsonl") }

        if case .waitingForQuestion = session.status { } else {
            XCTFail("rolled-up status should be waitingForQuestion from nested sub, got \(session.status)")
        }
    }

    func test_readLaunchPrompt_returnsFirstUserContent() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("launch_\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let content = [
            "{\"type\":\"user\",\"isSidechain\":true,\"cwd\":\"/x\",\"sessionId\":\"s\",\"agentId\":\"a\",\"message\":{\"role\":\"user\",\"content\":\"Please do the thing.\"}}",
            "{\"type\":\"assistant\",\"agentId\":\"a\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"OK\"}]}}"
        ].joined(separator: "\n")
        try content.write(toFile: path, atomically: true, encoding: .utf8)

        XCTAssertEqual(detector.readLaunchPrompt(jsonlPath: path), "Please do the thing.")
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

}
