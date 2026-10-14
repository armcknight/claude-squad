import Foundation

/// Direction for keyboard navigation through the sidebar.
enum SidebarNavigationDirection {
    case previous
    case next
    case first
    case last
}

/// Computes the ordered list of selectable sidebar items (sessions and their
/// subagents) that are currently visible, matching the render order of
/// `SessionListView`. Section and folder headers are not selectable, and the
/// contents of collapsed sections/folders are omitted.
///
/// - Parameters:
///   - sessions: All monitored sessions.
///   - expandedSections: Expand state keyed by status sort priority. Missing keys are expanded.
///   - expandedDirs: Expand state keyed by `"<priority>:<fullPath>"`. Missing keys are expanded.
func visibleSidebarSelections(
    sessions: [ClaudeSession],
    expandedSections: [Int: Bool],
    expandedDirs: [String: Bool]
) -> [SidebarSelection] {
    let grouped = Dictionary(grouping: sessions, by: { $0.status.sortPriority })
    var result: [SidebarSelection] = []
    for priority in grouped.keys.sorted() {
        guard let group = grouped[priority], !group.isEmpty else { continue }
        guard expandedSections[priority] ?? true else { continue }
        for node in buildPathTree(sessions: group) {
            appendSelections(for: node, priority: priority, expandedDirs: expandedDirs, into: &result)
        }
    }
    return result
}

/// Returns the item to select when moving in `direction` from `current`.
///
/// When nothing is selected (or the current selection is no longer visible),
/// `.next`/`.first` select the first item and `.previous`/`.last` select the
/// last. Moving past either end keeps the selection at that end.
func adjacentSidebarSelection(
    from current: SidebarSelection?,
    in items: [SidebarSelection],
    direction: SidebarNavigationDirection
) -> SidebarSelection? {
    guard let firstItem = items.first, let lastItem = items.last else { return nil }
    switch direction {
    case .first:
        return firstItem
    case .last:
        return lastItem
    case .next:
        guard let current, let index = items.firstIndex(of: current) else { return firstItem }
        return items[min(index + 1, items.count - 1)]
    case .previous:
        guard let current, let index = items.firstIndex(of: current) else { return lastItem }
        return items[max(index - 1, 0)]
    }
}

// MARK: - Private helpers

/// Mirrors `SessionListView.pathTreeView(node:priority:)`.
private func appendSelections(
    for node: PathTreeNode,
    priority: Int,
    expandedDirs: [String: Bool],
    into result: inout [SidebarSelection]
) {
    if node.children.isEmpty, let session = node.sessions.first, node.sessions.count == 1 {
        appendSelections(for: session, into: &result)
    } else if node.sessions.isEmpty && node.children.count == 1 && !node.children[0].children.isEmpty {
        appendSelections(for: node.children[0], priority: priority, expandedDirs: expandedDirs, into: &result)
    } else {
        guard expandedDirs[sidebarDirectoryKey(priority: priority, fullPath: node.fullPath)] ?? true else { return }
        for session in node.sessions {
            appendSelections(for: session, into: &result)
        }
        for child in node.children {
            appendSelections(for: child, priority: priority, expandedDirs: expandedDirs, into: &result)
        }
    }
}

private func appendSelections(for session: ClaudeSession, into result: inout [SidebarSelection]) {
    result.append(.session(sessionId: session.id))
    appendSelections(for: session.subagents, into: &result)
}

private func appendSelections(for subagents: [Subagent], into result: inout [SidebarSelection]) {
    for subagent in subagents {
        result.append(.subagent(agentId: subagent.id))
        appendSelections(for: subagent.subagents, into: &result)
    }
}

/// Key used to store a sidebar folder's expand/collapse state.
func sidebarDirectoryKey(priority: Int, fullPath: String) -> String {
    "\(priority):\(fullPath)"
}
