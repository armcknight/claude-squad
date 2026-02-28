import SwiftUI

/// Main window content — sidebar list of sessions with a detail pane.
struct SessionListView: View {
    @ObservedObject var monitor: SessionMonitor
    @State private var selectedSession: ClaudeSession?

    var body: some View {
        NavigationSplitView {
            List(monitor.sessions, selection: $selectedSession) { session in
                SessionRowView(session: session)
                    .tag(session)
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 300)
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
}
