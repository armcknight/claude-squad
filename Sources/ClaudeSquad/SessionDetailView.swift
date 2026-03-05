import SwiftUI

/// Detail pane showing full information about a selected session.
struct SessionDetailView: View {
    let session: ClaudeSession
    let monitor: SessionMonitor

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
                    HStack(spacing: 4) {
                        Text(session.projectPath)
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(session.projectPath, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Copy path")
                    }
                }

                if let branch = session.gitBranch {
                    LabeledContent("Branch") {
                        HStack(spacing: 4) {
                            Text(branch)
                                .textSelection(.enabled)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(branch, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .help("Copy branch")
                        }
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

                    if let prURL = session.pullRequestURL, let url = URL(string: prURL) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("Open PR", systemImage: "arrow.up.right.square")
                        }
                    }
                }

                // Task list
                if !session.taskItems.isEmpty {
                    Divider()
                    taskListSection
                } else if let tasks = session.taskSummary {
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

                // Transcript
                Divider()
                transcriptSection

                Spacer()
            }
            .padding()
        }
        .onAppear {
            monitor.loadTranscript(for: session.id)
        }
    }

    // MARK: - Task list

    private var taskListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let summary = session.taskSummary {
                HStack {
                    Text("Tasks")
                        .font(.headline)
                    Spacer()
                    Text("\(summary.completed)/\(summary.total) completed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: Double(summary.completed), total: Double(summary.total))
            } else {
                Text("Tasks")
                    .font(.headline)
            }

            ForEach(session.taskItems) { task in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: taskIcon(for: task.status))
                        .foregroundStyle(taskColor(for: task.status))
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.subject)
                            .fontWeight(.medium)

                        if let description = task.description, !description.isEmpty {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func taskIcon(for status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "arrow.circlepath"
        default: return "circle"
        }
    }

    private func taskColor(for status: String) -> Color {
        switch status {
        case "completed": return .green
        case "in_progress": return .blue
        default: return .secondary
        }
    }

    // MARK: - Transcript

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transcript")
                    .font(.headline)
                if !session.transcript.isEmpty {
                    Text("(\(session.transcript.count) messages)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if session.transcript.isEmpty {
                if case .parsing = monitor.transcriptLoadState[session.id] {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Parsing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // Show progress bar for loading state or initial state (before first update arrives)
                    let progress: Double = {
                        if case .loading(let p) = monitor.transcriptLoadState[session.id] { return p }
                        return 0.0
                    }()
                    VStack(spacing: 4) {
                        ProgressView(value: progress)
                        Text("Loading… \(Int(progress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(session.transcript.reversed()) { message in
                        transcriptBubble(message)
                    }
                }
            }
        }
    }

    private func transcriptBubble(_ message: TranscriptMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Role label + timestamp
            HStack {
                Text(message.role == "user" ? "You" : "Claude")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(message.role == "user" ? .blue : .purple)

                if let ts = message.timestamp {
                    Text(ts, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // Message text
            if !message.text.isEmpty {
                Text(message.text)
                    .textSelection(.enabled)
                    .font(.callout)
            }

            // Tool calls
            if !message.toolCalls.isEmpty {
                ForEach(Array(message.toolCalls.enumerated()), id: \.offset) { _, call in
                    HStack(spacing: 4) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.caption2)
                        Text(call.name)
                            .font(.caption.weight(.medium))
                        if let summary = call.summary {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == "user" ? Color.blue.opacity(0.05) : Color.purple.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
