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

    func test_extractQuestionFallsBackToPlanForExitPlanMode() {
        let block: [String: Any] = [
            "type": "tool_use",
            "name": "ExitPlanMode",
            "input": ["plan": "# Refactor\n\n1. Step one\n2. Step two\n"]
        ]
        let question = detector.extractQuestion(from: block)
        XCTAssertEqual(question, "# Refactor\n\n1. Step one\n2. Step two")
    }

    // MARK: - Tool call summary

    func test_toolCallSummaryExtractsExitPlanModeContent() {
        let plan = "# Plan\n\n1. Do thing A\n2. Do thing B\n"
        let summary = detector.toolCallSummary(name: "ExitPlanMode", input: ["plan": plan])
        XCTAssertEqual(summary, "# Plan\n\n1. Do thing A\n2. Do thing B")
    }

    func test_toolCallSummaryReturnsNilForExitPlanModeWithoutPlan() {
        XCTAssertNil(detector.toolCallSummary(name: "ExitPlanMode", input: [:]))
        XCTAssertNil(detector.toolCallSummary(name: "ExitPlanMode", input: ["plan": "   \n  "]))
        XCTAssertNil(detector.toolCallSummary(name: "ExitPlanMode", input: nil))
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
        subagents: [(agentId: String, agentType: String, description: String, slug: String, lastBlock: String, nested: [(agentId: String, agentType: String, description: String, slug: String, lastBlock: String)])] = [],
        subagentAge: TimeInterval = 0
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
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-subagentAge)], ofItemAtPath: subPath)
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

    func test_rollUpStatus_ignoresFinishedIdleSubagent() throws {
        // Parent: Bash tool_use, fresh → ownStatus = running.
        // Subagent: ended its turn with text → waitingIdle (finished).
        let (session, root) = try makeSessionTree(
            parentLastBlock: "{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Bash\"}",
            subagents: [
                (agentId: "done", agentType: "Explore", description: "finished",
                 slug: "done-slug", lastBlock: "{\"type\":\"text\",\"text\":\"All done.\"}", nested: [])
            ]
        )
        defer { try? FileManager.default.removeItem(atPath: root)
                try? FileManager.default.removeItem(atPath: root + ".jsonl") }

        if case .waitingIdle = session.subagents.first?.status { } else {
            XCTFail("subagent status should be waitingIdle, got \(String(describing: session.subagents.first?.status))")
        }
        if case .running = session.status { } else {
            XCTFail("rolled-up status should stay running, got \(session.status)")
        }
    }

    func test_rollUpStatus_ignoresStaleSubagent() throws {
        // Subagent stopped mid-tool-use long before the parent's latest write,
        // so it looks like it is waiting for approval, but the parent moved on.
        let (session, root) = try makeSessionTree(
            parentLastBlock: "{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Bash\"}",
            subagents: [
                (agentId: "stale", agentType: "general-purpose", description: "killed",
                 slug: "stale-slug", lastBlock: "{\"type\":\"tool_use\",\"name\":\"Bash\",\"id\":\"x\"}", nested: [])
            ],
            subagentAge: 600
        )
        defer { try? FileManager.default.removeItem(atPath: root)
                try? FileManager.default.removeItem(atPath: root + ".jsonl") }

        if case .waitingForQuestion = session.subagents.first?.status { } else {
            XCTFail("stale subagent status should be waitingForQuestion, got \(String(describing: session.subagents.first?.status))")
        }
        if case .running = session.status { } else {
            XCTFail("rolled-up status should stay running, got \(session.status)")
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

    // MARK: - Transcript: AskUserQuestion

    func test_readTranscript_capturesAskUserQuestionStructure() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("transcript_ask_\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let assistantLine = """
        {"type":"assistant","uuid":"a-1","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_1","name":"AskUserQuestion","input":{"questions":[{"question":"Which approach?","header":"Branching","multiSelect":false,"options":[{"label":"A","description":"first"},{"label":"B","description":"second"}]},{"question":"Confirm?","options":[{"label":"Yes"}]}]}}]}}
        """
        try assistantLine.write(toFile: path, atomically: true, encoding: .utf8)

        let transcript = detector.readTranscript(jsonlPath: path)
        XCTAssertEqual(transcript.count, 1)
        let call = try XCTUnwrap(transcript.first?.toolCalls.first)
        XCTAssertEqual(call.name, "AskUserQuestion")
        XCTAssertEqual(call.askQuestions.count, 2)

        let first = call.askQuestions[0]
        XCTAssertEqual(first.question, "Which approach?")
        XCTAssertEqual(first.header, "Branching")
        XCTAssertFalse(first.multiSelect)
        XCTAssertEqual(first.options.map(\.label), ["A", "B"])
        XCTAssertEqual(first.options.map(\.description), ["first", "second"])

        let second = call.askQuestions[1]
        XCTAssertEqual(second.question, "Confirm?")
        XCTAssertEqual(second.options.map(\.label), ["Yes"])
    }

    func test_readTranscript_parsesUserAnswerFromToolResult() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("transcript_answer_\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let userLine = #"""
        {"type":"user","uuid":"u-1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_1","content":"User has answered your questions: \"Which approach?\"=\"oneof provider fields\" user notes: prefer this one. You can now continue with the user's answers in mind.\n[result-id: r1]"}]}}
        """#
        try userLine.write(toFile: path, atomically: true, encoding: .utf8)

        let transcript = detector.readTranscript(jsonlPath: path)
        XCTAssertEqual(transcript.count, 1)
        let answer = try XCTUnwrap(transcript.first?.askAnswers.first)
        XCTAssertEqual(answer.question, "Which approach?")
        XCTAssertEqual(answer.selection, "oneof provider fields")
        XCTAssertEqual(answer.notes, "prefer this one")
        XCTAssertNil(answer.preview)
    }

    func test_readTranscript_parsesAnswerWithSelectedPreview() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("transcript_preview_\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let userLine = #"""
        {"type":"user","uuid":"u-2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_2","content":"User has answered your questions: \"Proto design?\"=\"oneof provider fields\" selected preview:\nmessage SyncChargeRequest { oneof provider { Stripe stripe = 10; }}\n[result-id: r2]"}]}}
        """#
        try userLine.write(toFile: path, atomically: true, encoding: .utf8)

        let transcript = detector.readTranscript(jsonlPath: path)
        let answer = try XCTUnwrap(transcript.first?.askAnswers.first)
        XCTAssertEqual(answer.selection, "oneof provider fields")
        XCTAssertEqual(answer.preview, "message SyncChargeRequest { oneof provider { Stripe stripe = 10; }}")
        XCTAssertNil(answer.notes)
    }

    // MARK: - Live session state

    func test_readLiveSessionStates_returnsEmptyForMissingDir() {
        let bogus = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("missing_\(UUID().uuidString)")
        let states = detector.readLiveSessionStates(claudeDir: bogus)
        XCTAssertTrue(states.isEmpty)
    }

    func test_readLiveSessionStates_parsesWaitingSession() throws {
        let claudeDir = try makeTempClaudeDir()
        defer { try? FileManager.default.removeItem(atPath: claudeDir) }

        try writeSessionFile(
            pid: 12345,
            sessionId: "session-a",
            status: "waiting",
            waitingFor: "permission prompt",
            updatedAtMs: 1_779_311_721_077,
            in: claudeDir
        )

        let states = detector.readLiveSessionStates(claudeDir: claudeDir)
        let state = try XCTUnwrap(states["session-a"])
        XCTAssertEqual(state.status, "waiting")
        XCTAssertEqual(state.waitingFor, "permission prompt")
    }

    func test_readLiveSessionStates_picksMostRecentDuplicate() throws {
        // If two PIDs claim the same sessionId (e.g., a stale leftover from a
        // crashed process), keep the most recently updated state.
        let claudeDir = try makeTempClaudeDir()
        defer { try? FileManager.default.removeItem(atPath: claudeDir) }

        try writeSessionFile(pid: 1, sessionId: "dup", status: "idle",
                             waitingFor: nil, updatedAtMs: 1_000_000,
                             in: claudeDir)
        try writeSessionFile(pid: 2, sessionId: "dup", status: "waiting",
                             waitingFor: "permission prompt",
                             updatedAtMs: 2_000_000, in: claudeDir)

        let states = detector.readLiveSessionStates(claudeDir: claudeDir)
        XCTAssertEqual(states["dup"]?.status, "waiting")
    }

    func test_waitingQuestionText_mapsKnownWaitingFor() {
        let permission = ClaudeSessionDetector.LiveSessionState(
            sessionId: "s", status: "waiting",
            waitingFor: "permission prompt", updatedAt: Date()
        )
        XCTAssertEqual(detector.waitingQuestionText(for: permission),
                       "Permission prompt pending — see terminal")

        let other = ClaudeSessionDetector.LiveSessionState(
            sessionId: "s", status: "waiting",
            waitingFor: "user input", updatedAt: Date()
        )
        XCTAssertEqual(detector.waitingQuestionText(for: other),
                       "Waiting on user input — see terminal")

        let none = ClaudeSessionDetector.LiveSessionState(
            sessionId: "s", status: "waiting",
            waitingFor: nil, updatedAt: Date()
        )
        XCTAssertEqual(detector.waitingQuestionText(for: none),
                       "Waiting for input — see terminal")
    }

    func test_waitingQuestionText_isNilForBusySession() {
        let busy = ClaudeSessionDetector.LiveSessionState(
            sessionId: "s", status: "busy", waitingFor: nil, updatedAt: Date()
        )
        XCTAssertNil(detector.waitingQuestionText(for: busy))
    }

    func test_overlay_overridesInterruptedWithWaitingForQuestion() {
        let now = Date()
        let session = makeSession(id: "s1", status: .interrupted(lastActivity: now), lastModified: now)
        let liveStates = ["s1": ClaudeSessionDetector.LiveSessionState(
            sessionId: "s1", status: "waiting",
            waitingFor: "permission prompt", updatedAt: now
        )]
        let updated = detector.applyingLiveStateOverlay(session, liveStates: liveStates)
        guard case .waitingForQuestion(_, let question) = updated.status else {
            return XCTFail("expected waitingForQuestion, got \(updated.status)")
        }
        XCTAssertEqual(question, "Permission prompt pending — see terminal")
    }

    func test_overlay_leavesUnaffectedSessionsAlone() {
        let now = Date()
        let session = makeSession(id: "s1", status: .running, lastModified: now)
        let updated = detector.applyingLiveStateOverlay(session, liveStates: [:])
        XCTAssertEqual(updated.status.sectionTitle, session.status.sectionTitle)
    }

    func test_overlay_preservesExistingAskUserQuestion() {
        // If JSONL already shows a real AskUserQuestion, don't replace its
        // (more informative) question text with the generic placeholder.
        let now = Date()
        let session = makeSession(
            id: "s1",
            status: .waitingForQuestion(since: now, question: "Which approach?"),
            lastModified: now
        )
        let liveStates = ["s1": ClaudeSessionDetector.LiveSessionState(
            sessionId: "s1", status: "waiting",
            waitingFor: "permission prompt", updatedAt: now
        )]
        let updated = detector.applyingLiveStateOverlay(session, liveStates: liveStates)
        guard case .waitingForQuestion(_, let q) = updated.status else {
            return XCTFail("expected waitingForQuestion")
        }
        XCTAssertEqual(q, "Which approach?")
    }

    // MARK: - Test helpers

    private func makeTempClaudeDir() throws -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("claude_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: (dir as NSString).appendingPathComponent("sessions"),
            withIntermediateDirectories: true
        )
        return dir
    }

    private func writeSessionFile(
        pid: Int, sessionId: String, status: String,
        waitingFor: String?, updatedAtMs: Int, in claudeDir: String
    ) throws {
        var json: [String: Any] = [
            "pid": pid,
            "sessionId": sessionId,
            "status": status,
            "updatedAt": updatedAtMs
        ]
        if let waitingFor { json["waitingFor"] = waitingFor }
        let data = try JSONSerialization.data(withJSONObject: json)
        let path = (claudeDir as NSString)
            .appendingPathComponent("sessions/\(pid).json")
        try data.write(to: URL(fileURLWithPath: path))
    }

    private func makeSession(id: String, status: SessionStatus, lastModified: Date) -> ClaudeSession {
        ClaudeSession(
            id: id,
            projectPath: "/tmp/proj",
            gitBranch: nil,
            gitStatus: nil,
            slug: nil,
            ownStatus: status,
            status: status,
            taskSummary: nil,
            lastModified: lastModified
        )
    }

    func test_readTranscript_keepsLegacySummaryForAskUserQuestion() throws {
        // Sanity: even with structured questions, the one-line summary should still
        // surface the first question (used by other code paths like status detection).
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("transcript_summary_\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let assistantLine = """
        {"type":"assistant","uuid":"a-2","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_3","name":"AskUserQuestion","input":{"questions":[{"question":"Top-level question?"}]}}]}}
        """
        try assistantLine.write(toFile: path, atomically: true, encoding: .utf8)

        let transcript = detector.readTranscript(jsonlPath: path)
        XCTAssertEqual(transcript.first?.toolCalls.first?.summary, "Top-level question?")
    }
}
