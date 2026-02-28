import SwiftUI

/// Detail pane showing full information about a selected session.
struct SessionDetailView: View {
    let session: ClaudeSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: statusIconName)
                        .font(.largeTitle)
                        .foregroundStyle(statusColor)

                    VStack(alignment: .leading) {
                        Text(session.displayName)
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text(statusText)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Project info
                LabeledContent("Project") {
                    Text(session.projectPath)
                        .textSelection(.enabled)
                }

                if let branch = session.gitBranch {
                    LabeledContent("Branch") {
                        Text(branch)
                            .textSelection(.enabled)
                    }
                }

                if let pid = session.processPID {
                    LabeledContent("PID") {
                        Text(String(pid))
                            .monospacedDigit()
                    }
                }

                // Question text
                if case .waitingForQuestion(_, let question) = session.status, let question {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Question")
                            .font(.headline)
                        Text(question)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

                // Task progress
                if let tasks = session.taskSummary {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tasks")
                            .font(.headline)
                        ProgressView(value: Double(tasks.completed), total: Double(tasks.total))
                        HStack {
                            Text("\(tasks.completed)/\(tasks.total) completed")
                            if tasks.inProgress > 0 {
                                Text("(\(tasks.inProgress) in progress)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                    }
                }

                Divider()

                // Actions
                HStack(spacing: 12) {
                    Button {
                        TerminalLauncher.open(at: session.projectPath)
                    } label: {
                        Label("Open in Terminal", systemImage: "terminal")
                    }

                    Button {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.projectPath)
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                }

                Spacer()
            }
            .padding()
        }
    }

    // MARK: - Status display

    private var statusIconName: String {
        switch session.status {
        case .running: return "bolt.circle.fill"
        case .waitingForQuestion: return "questionmark.circle.fill"
        case .waitingIdle: return "pause.circle.fill"
        case .inactive: return "moon.circle.fill"
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .running: return .blue
        case .waitingForQuestion: return .orange
        case .waitingIdle: return .yellow
        case .inactive: return .gray
        }
    }

    private var statusText: String {
        switch session.status {
        case .running:
            return "Running"
        case .waitingForQuestion(let since, _):
            return "Waiting for input (\(Date().timeIntervalSince(since).formattedDuration))"
        case .waitingIdle(let since):
            return "Idle (\(Date().timeIntervalSince(since).formattedDuration))"
        case .inactive(let lastActivity):
            return "Inactive (\(Date().timeIntervalSince(lastActivity).formattedDuration) ago)"
        }
    }
}
