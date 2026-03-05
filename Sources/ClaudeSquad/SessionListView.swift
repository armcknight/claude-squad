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
            if let session = selectedSession {
                SessionDetailView(session: session, monitor: monitor)
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

    /// Builds a tree of sessions grouped by common ancestor directories.
    private func buildPathTree(sessions: [ClaudeSession]) -> [PathTreeNode] {
        // Group sessions by parent directory.
        let grouped = Dictionary(grouping: sessions) { session in
            (session.projectPath as NSString).deletingLastPathComponent
        }

        // For each parent directory, create a node.
        var nodes: [PathTreeNode] = []
        for (parentPath, sessionsInDir) in grouped.sorted(by: { $0.key < $1.key }) {
            if sessionsInDir.count == 1 {
                // Single session — show as a leaf with its full abbreviated path.
                let session = sessionsInDir[0]
                nodes.append(PathTreeNode(
                    fullPath: session.projectPath,
                    displayLabel: session.displayName,
                    sessions: [session],
                    children: []
                ))
            } else {
                // Multiple sessions share this parent — create a group node.
                let node = PathTreeNode(
                    fullPath: parentPath,
                    displayLabel: abbreviatePath(parentPath),
                    sessions: sessionsInDir.sorted(),
                    children: []
                )
                nodes.append(node)
            }
        }

        // Merge nodes that share a common ancestor prefix.
        return mergeCommonPrefixes(nodes)
    }

    /// Merges leaf nodes that share a common parent into directory groups.
    /// For example, if we have individual leaves under the same grandparent,
    /// they get grouped together.
    private func mergeCommonPrefixes(_ nodes: [PathTreeNode]) -> [PathTreeNode] {
        guard nodes.count > 1 else { return nodes }

        // Group nodes by their parent directory.
        let grouped = Dictionary(grouping: nodes) { node in
            (node.fullPath as NSString).deletingLastPathComponent
        }

        var result: [PathTreeNode] = []
        for (parentPath, nodesInParent) in grouped.sorted(by: { $0.key < $1.key }) {
            if nodesInParent.count == 1 {
                result.append(nodesInParent[0])
            } else {
                // Multiple nodes share a parent — group them.
                let allSingleLeaves = nodesInParent.allSatisfy { $0.children.isEmpty && $0.sessions.count == 1 }
                if allSingleLeaves {
                    // All are single-session leaves — combine into one directory node.
                    let allSessions = nodesInParent.flatMap(\.sessions).sorted()
                    result.append(PathTreeNode(
                        fullPath: parentPath,
                        displayLabel: abbreviatePath(parentPath),
                        sessions: allSessions,
                        children: []
                    ))
                } else {
                    // Mix of groups and leaves — make a parent with children.
                    result.append(PathTreeNode(
                        fullPath: parentPath,
                        displayLabel: abbreviatePath(parentPath),
                        sessions: [],
                        children: nodesInParent
                    ))
                }
            }
        }

        return result
    }
}
