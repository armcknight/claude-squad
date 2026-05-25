import XCTest
@testable import ClaudeSquad

final class PathTreeTests: XCTestCase {

    // MARK: - Helpers

    private func makeSession(id: String, path: String) -> ClaudeSession {
        ClaudeSession(
            id: id,
            projectPath: path,
            gitBranch: nil,
            gitStatus: nil,
            slug: nil,
            ownStatus: .running,
            status: .running,
            taskSummary: nil,
            lastModified: Date()
        )
    }

    // Returns the tree flattened as (displayLabel, hasChildren) pairs via DFS.
    private func flatten(_ nodes: [PathTreeNode]) -> [(label: String, isFolder: Bool)] {
        var result: [(String, Bool)] = []
        for node in nodes {
            let isFolder = !node.children.isEmpty || node.sessions.isEmpty
            result.append((node.displayLabel, isFolder))
            result.append(contentsOf: flatten(node.children))
        }
        return result
    }

    // MARK: - Tests

    /// A single session should be wrapped in an expandable folder, not shown flat.
    func test_singleSession_isWrappedInFolder() {
        let home = NSHomeDirectory()
        let s = makeSession(id: "s1", path: "\(home)/Code/myproject")
        let tree = buildPathTree(sessions: [s])

        // Root must contain exactly one folder node.
        XCTAssertEqual(tree.count, 1)
        let folder = tree[0]
        XCTAssertFalse(folder.children.isEmpty, "Single session should be inside a folder, not flat at root")
        XCTAssertTrue(folder.sessions.isEmpty)

        // The folder's child should be the leaf session.
        XCTAssertEqual(folder.children.count, 1)
        let leaf = folder.children[0]
        XCTAssertEqual(leaf.sessions.count, 1)
        XCTAssertEqual(leaf.sessions[0].id, "s1")
        XCTAssertEqual(leaf.displayLabel, "myproject")
    }

    /// Sessions in the same directory should share one folder, not each get their own.
    func test_siblingsSessions_shareParentFolder() {
        let home = NSHomeDirectory()
        let s1 = makeSession(id: "s1", path: "\(home)/Code/project1")
        let s2 = makeSession(id: "s2", path: "\(home)/Code/project2")
        let tree = buildPathTree(sessions: [s1, s2])

        // Should produce one top-level folder containing both leaves.
        XCTAssertEqual(tree.count, 1)
        let folder = tree[0]
        XCTAssertFalse(folder.children.isEmpty)

        let leafIds = folder.children.compactMap { $0.sessions.first?.id }.sorted()
        XCTAssertEqual(leafIds, ["s1", "s2"])
    }

    /// Sessions in completely different directories should each be in their own folder.
    func test_unrelatedSessions_eachInOwnFolder() {
        let home = NSHomeDirectory()
        let s1 = makeSession(id: "s1", path: "\(home)/Code/project1")
        let s2 = makeSession(id: "s2", path: "\(home)/Work/project2")
        let tree = buildPathTree(sessions: [s1, s2])

        // No raw session leaf (no children, 1 session) should appear at the top level —
        // every session must be nested inside at least one folder node.
        for rootNode in tree {
            XCTAssertFalse(
                rootNode.sessions.count == 1 && rootNode.children.isEmpty,
                "Session '\(rootNode.displayLabel)' appears flat at root — should be inside a folder"
            )
        }

        // Both session IDs should appear somewhere in the tree.
        func allIds(_ nodes: [PathTreeNode]) -> [String] {
            nodes.flatMap { node in [node.sessions.map(\.id), allIds(node.children)].flatMap { $0 } }
        }
        XCTAssertEqual(allIds(tree).sorted(), ["s1", "s2"])
    }

    /// Deep unique path: session wrapped in its immediate parent folder only.
    func test_deepUniquePath_foldedToParent() {
        let home = NSHomeDirectory()
        let s = makeSession(id: "s1", path: "\(home)/Code/org/team/project")
        let tree = buildPathTree(sessions: [s])

        // Tree must start with a folder, not a flat session row.
        XCTAssertEqual(tree.count, 1)
        let top = tree[0]
        XCTAssertFalse(top.children.isEmpty, "Session under deep unique path must be in a folder")

        // Walk to the leaf and verify it is the session.
        var current = top
        while !current.children.isEmpty {
            XCTAssertEqual(current.children.count, 1)
            current = current.children[0]
        }
        XCTAssertEqual(current.sessions.count, 1)
        XCTAssertEqual(current.sessions[0].id, "s1")
        XCTAssertEqual(current.displayLabel, "project")
    }
}
