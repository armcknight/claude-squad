import XCTest
@testable import ClaudeSquad

final class SidebarNavigationTests: XCTestCase {

    // MARK: - Helpers

    private let home = NSHomeDirectory()

    private func makeSession(
        id: String,
        path: String,
        status: SessionStatus = .running,
        subagents: [Subagent] = []
    ) -> ClaudeSession {
        var session = ClaudeSession(
            id: id,
            projectPath: path,
            gitBranch: nil,
            gitStatus: nil,
            slug: nil,
            ownStatus: status,
            status: status,
            taskSummary: nil,
            lastModified: Date()
        )
        session.subagents = subagents
        return session
    }

    private func makeSubagent(id: String, children: [Subagent] = []) -> Subagent {
        var subagent = Subagent(id: id, status: .running, jsonlPath: "/tmp/\(id).jsonl", lastModified: Date())
        subagent.subagents = children
        return subagent
    }

    // MARK: - visibleSidebarSelections

    func test_visibleSelections_orderedBySectionThenPath() {
        let running = makeSession(id: "running", path: "\(home)/Code/a")
        let needsInput = makeSession(
            id: "needsInput",
            path: "\(home)/Code/b",
            status: .waitingForQuestion(since: Date(), question: nil)
        )
        let items = visibleSidebarSelections(sessions: [running, needsInput], expandedSections: [:], expandedDirs: [:])
        XCTAssertEqual(items, [.session(sessionId: "needsInput"), .session(sessionId: "running")])
    }

    func test_visibleSelections_includeNestedSubagentsAfterParent() {
        let session = makeSession(
            id: "s1",
            path: "\(home)/Code/a",
            subagents: [makeSubagent(id: "sub1", children: [makeSubagent(id: "sub1a")]), makeSubagent(id: "sub2")]
        )
        let other = makeSession(id: "s2", path: "\(home)/Code/b")
        let items = visibleSidebarSelections(sessions: [session, other], expandedSections: [:], expandedDirs: [:])
        XCTAssertEqual(items, [
            .session(sessionId: "s1"),
            .subagent(agentId: "sub1"),
            .subagent(agentId: "sub1a"),
            .subagent(agentId: "sub2"),
            .session(sessionId: "s2"),
        ])
    }

    func test_visibleSelections_skipCollapsedSection() {
        let running = makeSession(id: "running", path: "\(home)/Code/a")
        let needsInput = makeSession(
            id: "needsInput",
            path: "\(home)/Code/b",
            status: .waitingForQuestion(since: Date(), question: nil)
        )
        let collapsed = [SessionStatus.running.sortPriority: false]
        let items = visibleSidebarSelections(sessions: [running, needsInput], expandedSections: collapsed, expandedDirs: [:])
        XCTAssertEqual(items, [.session(sessionId: "needsInput")])
    }

    func test_visibleSelections_skipCollapsedFolder() {
        let s1 = makeSession(id: "s1", path: "\(home)/Code/a")
        let s2 = makeSession(id: "s2", path: "\(home)/Work/b")
        let priority = SessionStatus.running.sortPriority
        // Tree is `~/` → { `Code/` → a, `Work/` → b }.
        let collapsed = [sidebarDirectoryKey(priority: priority, fullPath: "~/Code"): false]
        let items = visibleSidebarSelections(sessions: [s1, s2], expandedSections: [:], expandedDirs: collapsed)
        XCTAssertEqual(items, [.session(sessionId: "s2")])
    }

    // MARK: - adjacentSidebarSelection

    private let items: [SidebarSelection] = [
        .session(sessionId: "a"),
        .subagent(agentId: "b"),
        .session(sessionId: "c"),
    ]

    func test_adjacent_nextAndPrevious() {
        XCTAssertEqual(adjacentSidebarSelection(from: .subagent(agentId: "b"), in: items, direction: .next), .session(sessionId: "c"))
        XCTAssertEqual(adjacentSidebarSelection(from: .subagent(agentId: "b"), in: items, direction: .previous), .session(sessionId: "a"))
    }

    func test_adjacent_clampsAtEnds() {
        XCTAssertEqual(adjacentSidebarSelection(from: .session(sessionId: "c"), in: items, direction: .next), .session(sessionId: "c"))
        XCTAssertEqual(adjacentSidebarSelection(from: .session(sessionId: "a"), in: items, direction: .previous), .session(sessionId: "a"))
    }

    func test_adjacent_noSelectionStartsAtEnds() {
        XCTAssertEqual(adjacentSidebarSelection(from: nil, in: items, direction: .next), .session(sessionId: "a"))
        XCTAssertEqual(adjacentSidebarSelection(from: nil, in: items, direction: .previous), .session(sessionId: "c"))
    }

    func test_adjacent_hiddenSelectionStartsAtEnds() {
        let hidden = SidebarSelection.session(sessionId: "gone")
        XCTAssertEqual(adjacentSidebarSelection(from: hidden, in: items, direction: .next), .session(sessionId: "a"))
    }

    func test_adjacent_firstAndLast() {
        XCTAssertEqual(adjacentSidebarSelection(from: .subagent(agentId: "b"), in: items, direction: .first), .session(sessionId: "a"))
        XCTAssertEqual(adjacentSidebarSelection(from: .subagent(agentId: "b"), in: items, direction: .last), .session(sessionId: "c"))
    }

    func test_adjacent_emptyListReturnsNil() {
        XCTAssertNil(adjacentSidebarSelection(from: nil, in: [], direction: .next))
    }
}
