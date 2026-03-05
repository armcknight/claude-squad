import SwiftUI

/// Main window content — sidebar list of sessions grouped by status, with a detail pane.
struct SessionListView: View {
    @ObservedObject var monitor: SessionMonitor
    @State private var selectedSession: ClaudeSession?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSession) {
                ForEach(sectionOrder, id: \.self) { priority in
                    if let sessions = groupedSessions[priority], !sessions.isEmpty {
                        let status = sessions.first!.status
                        let isSectionExpanded = expandedSections[priority] ?? true

                        // Status section header
                        HStack(spacing: 6) {
                            Image(systemName: isSectionExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 12)
                            Image(systemName: status.iconName)
                                .foregroundStyle(status.color)
                            Text("\(status.sectionTitle) (\(sessions.count))")
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation {
                                expandedSections[priority] = !isSectionExpanded
                            }
                        }
                        .selectionDisabled()
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 10))
                        .listRowBackground(Color(nsColor: .textBackgroundColor))

                        if isSectionExpanded {
                            let tree = buildPathTree(sessions: sessions)
                            ForEach(tree, id: \.id) { node in
                                pathTreeView(node: node, priority: priority)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.visible)
            .navigationSplitViewColumnWidth(min: 280, ideal: 340)
            .toolbar {
                ToolbarItem {
                    Button {
                        monitor.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh sessions")
                }
            }
            .overlay {
                if monitor.sessions.isEmpty {
                    ContentUnavailableView(
                        "No Sessions",
                        systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("No active Claude sessions detected.\nStart a Claude session in your terminal to see it here.")
                    )
                }
            }
        } detail: {
            if let selected = selectedSession,
               let session = monitor.sessions.first(where: { $0.id == selected.id }) {
                SessionDetailView(session: session, monitor: monitor, transcriptLoader: monitor.transcriptLoader)
            } else {
                ContentUnavailableView(
                    "Select a Session",
                    systemImage: "sidebar.leading",
                    description: Text("Choose a session from the sidebar to view details.")
                )
            }
        }
    }

    // MARK: - Tree view rendering

    private func pathTreeView(node: PathTreeNode, priority: Int) -> AnyView {
        if node.children.isEmpty, let session = node.sessions.first, node.sessions.count == 1 {
            // Leaf: single session with no children — show full row
            return AnyView(
                SessionRowView(session: session, displayNameOverride: node.displayLabel)
                    .tag(session)
            )
        } else if node.sessions.isEmpty && node.children.count == 1 {
            // Pass-through: single child, no sessions — skip rendering this node
            return pathTreeView(node: node.children[0], priority: priority)
        } else {
            // Directory group header
            let key = "\(priority):\(node.fullPath)"
            let isExpanded = expandedDirs[key] ?? true

            return AnyView(Group {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                    Image(systemName: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(node.displayLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation {
                        expandedDirs[key] = !isExpanded
                    }
                }
                .selectionDisabled()

                if isExpanded {
                    // Sessions directly at this directory level
                    ForEach(node.sessions) { session in
                        SessionRowView(session: session, displayNameOverride: session.projectName)
                            .tag(session)
                            .padding(.leading, 8)
                    }
                    // Child directories
                    ForEach(node.children, id: \.id) { child in
                        pathTreeView(node: child, priority: priority)
                            .padding(.leading, 8)
                    }
                }
            })
        }
    }

    // MARK: - State

    @State private var expandedSections: [Int: Bool] = [:]
    @State private var expandedDirs: [String: Bool] = [:]

    /// Sessions grouped by sortPriority.
    private var groupedSessions: [Int: [ClaudeSession]] {
        Dictionary(grouping: monitor.sessions, by: { $0.status.sortPriority })
    }

    /// Section display order (by sort priority).
    private var sectionOrder: [Int] {
        groupedSessions.keys.sorted()
    }

    // MARK: - Path tree building

    /// A node in the directory tree. Either a directory grouping or a leaf session.
    struct PathTreeNode: Identifiable {
        let id = UUID()
        let fullPath: String
        let displayLabel: String
        var sessions: [ClaudeSession]
        var children: [PathTreeNode]
    }

    /// Mutable trie node used during tree construction.
    private class TrieNode {
        var children: [String: TrieNode] = [:]
        var sessions: [ClaudeSession] = []
    }

    /// Builds a directory tree from session paths using a trie.
    /// Sessions at /a/b/x and /a/b/c/y will produce:
    ///   /a/b/
    ///     x (leaf)
    ///     c/
    ///       y (leaf)
    private func buildPathTree(sessions: [ClaudeSession]) -> [PathTreeNode] {
        let root = TrieNode()

        for session in sessions {
            var components = (session.projectPath as NSString).pathComponents
            // Replace home directory prefix with ~
            let homeComponents = (NSHomeDirectory() as NSString).pathComponents
            if components.starts(with: homeComponents) {
                components = ["~"] + Array(components.dropFirst(homeComponents.count))
            }
            // Remove leading "/"
            if components.first == "/" { components.removeFirst() }

            // Walk the trie, creating nodes as needed. The last component
            // is the session's project directory — attach the session there.
            var current = root
            for (i, component) in components.enumerated() {
                if i == components.count - 1 {
                    // Leaf: attach session
                    if current.children[component] == nil {
                        current.children[component] = TrieNode()
                    }
                    current.children[component]!.sessions.append(session)
                } else {
                    if current.children[component] == nil {
                        current.children[component] = TrieNode()
                    }
                    current = current.children[component]!
                }
            }
        }

        // Convert trie to display nodes, collapsing single-child chains.
        return convertTrieChildren(root, parentPath: "")
    }

    /// Converts trie children into PathTreeNode array, collapsing chains of
    /// single-child directories with no sessions into one combined label.
    private func convertTrieChildren(_ node: TrieNode, parentPath: String) -> [PathTreeNode] {
        var result: [PathTreeNode] = []

        for (component, child) in node.children.sorted(by: { $0.key < $1.key }) {
            let fullPath = parentPath.isEmpty ? component : parentPath + "/" + component

            // Collapse single-child chains: if this node has exactly one child
            // and no sessions, merge it with the child's label.
            var current = child
            var label = component
            var currentPath = fullPath
            while current.sessions.isEmpty && current.children.count == 1 {
                let (nextComponent, nextChild) = current.children.first!
                label += "/" + nextComponent
                currentPath += "/" + nextComponent
                current = nextChild
            }

            if current.sessions.count == 1 && current.children.isEmpty {
                // Pure leaf: single session, no subdirectories.
                result.append(PathTreeNode(
                    fullPath: currentPath,
                    displayLabel: label,
                    sessions: current.sessions,
                    children: []
                ))
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
}
