import Foundation

/// A node in the directory path tree used to render the sidebar.
///
/// Each node is either a directory grouping (with children and/or direct sessions)
/// or a leaf (a single session with no subdirectories).
struct PathTreeNode: Identifiable {
    let id = UUID()
    /// Absolute path used as a stable key for expand/collapse state.
    let fullPath: String
    /// Label shown in the UI for this node.
    let displayLabel: String
    /// Sessions that live directly at this directory level.
    var sessions: [ClaudeSession]
    /// Child directory nodes.
    var children: [PathTreeNode]
}

/// Builds a directory tree from a flat list of sessions using their project paths.
///
/// Sessions at `/a/b/x` and `/a/b/c/y` produce:
/// ```
/// /a/b/
///   x  (leaf)
///   c/
///     y  (leaf)
/// ```
///
/// Every session always appears inside at least one expandable folder, even
/// when it is the sole occupant of its directory.
func buildPathTree(sessions: [ClaudeSession]) -> [PathTreeNode] {
    let root = TrieNode()

    for session in sessions {
        var components = (session.projectPath as NSString).pathComponents
        let homeComponents = (NSHomeDirectory() as NSString).pathComponents
        if components.starts(with: homeComponents) {
            components = ["~"] + Array(components.dropFirst(homeComponents.count))
        }
        if components.first == "/" { components.removeFirst() }

        var current = root
        for (i, component) in components.enumerated() {
            if current.children[component] == nil {
                current.children[component] = TrieNode()
            }
            guard let child = current.children[component] else { continue }
            if i == components.count - 1 {
                child.sessions.append(session)
            } else {
                current = child
            }
        }
    }

    return convertTrieChildren(root, parentPath: "")
}

// MARK: - Private helpers

private class TrieNode {
    var children: [String: TrieNode] = [:]
    var sessions: [ClaudeSession] = []
}

private func convertTrieChildren(_ node: TrieNode, parentPath: String) -> [PathTreeNode] {
    var result: [PathTreeNode] = []

    for (component, child) in node.children.sorted(by: { $0.key < $1.key }) {
        let fullPath = parentPath.isEmpty ? component : parentPath + "/" + component

        // Collapse single-child chains with no sessions into a combined label.
        var current = child
        var label = component
        var currentPath = fullPath
        while current.sessions.isEmpty && current.children.count == 1 {
            guard let (nextComponent, nextChild) = current.children.first else { break }
            label += "/" + nextComponent
            currentPath += "/" + nextComponent
            current = nextChild
        }

        if current.sessions.count == 1 && current.children.isEmpty {
            // Pure leaf: one session, no subdirectories. Always wrap it in a
            // folder node so the sidebar always shows an expandable parent.
            let labelParts = label.components(separatedBy: "/")
            if labelParts.count > 1 {
                let folderDisplayLabel = labelParts.dropLast().joined(separator: "/")
                let leafDisplayLabel = labelParts.last ?? current.sessions[0].projectName
                let pathParts = currentPath.components(separatedBy: "/")
                let folderFullPath = pathParts.dropLast().joined(separator: "/")
                let leafNode = PathTreeNode(
                    fullPath: currentPath,
                    displayLabel: leafDisplayLabel,
                    sessions: current.sessions,
                    children: []
                )
                result.append(PathTreeNode(
                    fullPath: folderFullPath,
                    displayLabel: folderDisplayLabel,
                    sessions: [],
                    children: [leafNode]
                ))
            } else {
                // Degenerate: session sits at trie root with no parent component.
                result.append(PathTreeNode(
                    fullPath: currentPath,
                    displayLabel: label,
                    sessions: current.sessions,
                    children: []
                ))
            }
        } else {
            // Directory node: has multiple sessions and/or subdirectories.
            let childNodes = convertTrieChildren(current, parentPath: currentPath)
            result.append(PathTreeNode(
                fullPath: currentPath,
                displayLabel: label,
                sessions: current.sessions.sorted(),
                children: childNodes
            ))
        }
    }

    return result
}
