import SwiftUI

/// Main window content — sidebar list of sessions grouped by status, with a detail pane.
struct SessionListView: View {
    @ObservedObject var monitor: SessionMonitor
    @State private var selection: SidebarSelection?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
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
                        .accessibilityIdentifier("section-\(status.sectionTitle)")
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
            detailPane
        }
        .onChange(of: monitor.requestedSelection) { _, newValue in
            guard let newValue else { return }
            selection = newValue
            monitor.requestedSelection = nil
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selection, let target = monitor.sessions.find(selection) {
            switch target {
            case .session(let session):
                SessionDetailView(session: session, monitor: monitor, transcriptLoader: monitor.transcriptLoader)
            case .subagent(let parent, let subagent):
                SubagentDetailView(parent: parent, subagent: subagent, transcriptLoader: monitor.transcriptLoader)
            }
        } else {
            ContentUnavailableView(
                "Select a Session",
                systemImage: "sidebar.leading",
                description: Text("Choose a session from the sidebar to view details.")
            )
        }
    }

    // MARK: - Tree view rendering

    private func pathTreeView(node: PathTreeNode, priority: Int) -> AnyView {
        if node.children.isEmpty, let session = node.sessions.first, node.sessions.count == 1 {
            // Leaf: single session with no children — show full row plus subagents
            return AnyView(
                Group {
                    SessionRowView(session: session, displayNameOverride: node.displayLabel)
                        .tag(SidebarSelection.session(sessionId: session.id))
                        .accessibilityIdentifier("session-row-\(session.id)")
                    subagentRows(for: session.subagents, indentLevel: 1)
                }
            )
        } else if node.sessions.isEmpty && node.children.count == 1 && !node.children[0].children.isEmpty {
            // Pass-through: single child *directory* with no sessions — skip this
            // intermediate node. Never skip when the child is a leaf session, or the
            // folder wrapping a lone session would be invisible.
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
                        Group {
                            SessionRowView(session: session, displayNameOverride: session.projectName)
                                .tag(SidebarSelection.session(sessionId: session.id))
                                .accessibilityIdentifier("session-row-\(session.id)")
                            subagentRows(for: session.subagents, indentLevel: 1)
                        }
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

    /// Renders subagent rows for a subtree by first flattening into
    /// `(subagent, depth)` pairs, then emitting a single `ForEach`. Done this
    /// way to avoid SwiftUI's self-referential opaque-return-type restriction
    /// on recursive `@ViewBuilder` functions.
    @ViewBuilder
    private func subagentRows(for subagents: [Subagent], indentLevel: Int) -> some View {
        let flattened = flattenSubagents(subagents, startingDepth: indentLevel)
        ForEach(flattened, id: \.subagent.id) { entry in
            SubagentRowView(subagent: entry.subagent)
                .tag(SidebarSelection.subagent(agentId: entry.subagent.id))
                .accessibilityIdentifier("subagent-row-\(entry.subagent.id)")
                .padding(.leading, CGFloat(12 * entry.depth))
        }
    }

    private struct FlattenedSubagent {
        let subagent: Subagent
        let depth: Int
    }

    private func flattenSubagents(_ subagents: [Subagent], startingDepth: Int) -> [FlattenedSubagent] {
        var result: [FlattenedSubagent] = []
        for sub in subagents {
            result.append(FlattenedSubagent(subagent: sub, depth: startingDepth))
            if !sub.subagents.isEmpty {
                result.append(contentsOf: flattenSubagents(sub.subagents, startingDepth: startingDepth + 1))
            }
        }
        return result
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

}
