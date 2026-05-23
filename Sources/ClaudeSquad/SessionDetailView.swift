import SwiftUI

/// Detail pane showing full information about a selected session.
struct SessionDetailView: View {
    let session: ClaudeSession
    let monitor: SessionMonitor
    @ObservedObject var transcriptLoader: TranscriptLoader

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
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Copy path")
                        Button {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.projectPath)
                        } label: {
                            Image(systemName: "folder")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Reveal in Finder")
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
                            .buttonStyle(.bordered)
                        .controlSize(.small)
                            .help("Copy branch")
                            if let prURL = session.pullRequestURL, let url = URL(string: prURL) {
                                Button {
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    let prNumber = url.lastPathComponent
                                    Text("PR #\(prNumber)")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                        .controlSize(.small)
                                .help("Open Pull Request")
                            }
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
        .accessibilityIdentifier("session-detail")
        .onAppear {
            if let jsonlPath = session.jsonlPath {
                transcriptLoader.loadIfNeeded(transcriptKey: session.transcriptKey, jsonlPath: jsonlPath)
            }
        }
        .onChange(of: session.id) { _, _ in
            if let jsonlPath = session.jsonlPath {
                transcriptLoader.loadIfNeeded(transcriptKey: session.transcriptKey, jsonlPath: jsonlPath)
            }
        }
        // The detail can stay open while Claude writes more entries; re-check
        // the JSONL whenever SessionMonitor reports a newer mtime. The loader
        // is internally idempotent for unchanged files.
        .onChange(of: session.lastModified) { _, _ in
            if let jsonlPath = session.jsonlPath {
                transcriptLoader.loadIfNeeded(transcriptKey: session.transcriptKey, jsonlPath: jsonlPath)
            }
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

    /// Use cached transcript from the loader (available immediately) over the
    /// session's copy (only updated on the next refresh cycle).
    private var transcript: [TranscriptMessage] {
        transcriptLoader.cachedTranscripts[session.transcriptKey] ?? session.transcript
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transcript")
                    .font(.headline)
                if !transcript.isEmpty {
                    Text("(\(transcript.count) messages)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if transcript.isEmpty {
                let progress: Double = {
                    if case .loading(let p) = transcriptLoader.loadStates[session.transcriptKey] { return p }
                    return 0.0
                }()
                VStack(spacing: 4) {
                    ProgressView(value: progress)
                    Text("Loading… \(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let pending = pendingPermissionText {
                        pendingPermissionPlaceholder(pending)
                    }
                    ForEach(transcript.reversed()) { message in
                        transcriptBubble(message)
                    }
                }
            }
        }
    }

    /// The text describing the pending permission prompt, if the session is
    /// currently waiting on one whose tool_use has not yet been persisted to
    /// the JSONL. Returns nil for any other waiting state (e.g., an
    /// AskUserQuestion, which the transcript already renders).
    private var pendingPermissionText: String? {
        guard case .waitingForQuestion(_, let question) = session.status,
              let question,
              question.hasPrefix("Permission prompt pending") ||
              question.hasPrefix("Waiting on") ||
              question.hasPrefix("Waiting for input") else {
            return nil
        }
        return question
    }

    private func pendingPermissionPlaceholder(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Claude")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.purple)
                Text("Pending")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                    if !call.askQuestions.isEmpty {
                        askQuestionView(call.askQuestions)
                    } else if call.name == "ExitPlanMode" {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "list.bullet.clipboard")
                                    .font(.caption2)
                                Text("Plan")
                                    .font(.caption.weight(.medium))
                            }
                            .foregroundStyle(.secondary)
                            if let summary = call.summary {
                                Text(summary)
                                    .textSelection(.enabled)
                                    .font(.callout)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    } else {
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

            // AskUserQuestion answers (on user messages)
            if !message.askAnswers.isEmpty {
                ForEach(Array(message.askAnswers.enumerated()), id: \.offset) { _, answer in
                    askAnswerView(answer)
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

private extension SessionDetailView {
    /// Renders the full question + options block when the assistant invokes
    /// AskUserQuestion. One sub-block per question (the tool supports multiple).
    @ViewBuilder
    func askQuestionView(_ questions: [AskUserQuestionContent]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "questionmark.circle")
                    .font(.caption2)
                Text("AskUserQuestion")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.secondary)

            ForEach(Array(questions.enumerated()), id: \.offset) { _, q in
                VStack(alignment: .leading, spacing: 4) {
                    Text(q.question)
                        .font(.callout)
                        .textSelection(.enabled)
                    if q.multiSelect {
                        Text("(multi-select)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(Array(q.options.enumerated()), id: \.offset) { _, opt in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: q.multiSelect ? "square" : "circle")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(opt.label)
                                    .font(.caption.weight(.medium))
                                if let description = opt.description, !description.isEmpty {
                                    Text(description)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    /// Renders the user's selection in response to an AskUserQuestion.
    @ViewBuilder
    func askAnswerView(_ answer: AskUserAnswer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle")
                    .font(.caption2)
                Text("Answered")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.secondary)
            Text(answer.selection)
                .font(.callout)
                .textSelection(.enabled)
            if let notes = answer.notes {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let preview = answer.preview {
                Text(preview)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
