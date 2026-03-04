import SwiftUI

/// Detail pane showing full information about a selected session.
struct SessionDetailView: View {
    let session: ClaudeSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: session.status.iconName)
                        .font(.largeTitle)
                        .foregroundStyle(session.status.color)

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

    private var statusText: String {
        let title = session.status.sectionTitle
        let elapsed = session.status.elapsed
        if elapsed > 0 {
            return "\(title) (\(elapsed.formattedDuration))"
        }
        return title
    }
}
