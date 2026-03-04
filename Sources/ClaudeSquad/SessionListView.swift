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
                        let isExpanded = expandedSections[priority] ?? true

                        HStack(spacing: 6) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 12)
                            Image(systemName: status.iconName)
                                .foregroundStyle(status.color)
                            Text(status.sectionTitle)
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation {
                                expandedSections[priority] = !isExpanded
                            }
                        }
                        .selectionDisabled()
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 10))
                        .listRowBackground(Color(nsColor: .textBackgroundColor))

                        if isExpanded {
                            ForEach(sessions) { session in
                                SessionRowView(session: session)
                                    .tag(session)
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
                SessionDetailView(session: session)
            } else {
                ContentUnavailableView(
                    "Select a Session",
                    systemImage: "sidebar.leading",
                    description: Text("Choose a session from the sidebar to view details.")
                )
            }
        }
    }

    // MARK: - Section state

    @State private var expandedSections: [Int: Bool] = [:]

    /// Sessions grouped by sortPriority.
    private var groupedSessions: [Int: [ClaudeSession]] {
        Dictionary(grouping: monitor.sessions, by: { $0.status.sortPriority })
    }

    /// Section display order (by sort priority).
    private var sectionOrder: [Int] {
        groupedSessions.keys.sorted()
    }
}
