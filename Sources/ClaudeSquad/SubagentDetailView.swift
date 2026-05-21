import SwiftUI

/// Detail pane for a selected subagent. Per CLA-7, no project path or branch
/// (those mirror the parent). Header shows subagent type, slug, and the full
/// launch prompt in place of the parent's path/branch.
struct SubagentDetailView: View {
    let parent: ClaudeSession
    let subagent: Subagent
    @ObservedObject var transcriptLoader: TranscriptLoader

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: subagent.status.iconName)
                        .font(.largeTitle)
                        .foregroundStyle(subagent.status.color)

                    VStack(alignment: .leading) {
                        Text(subagent.displayLabel)
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text(statusText)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Parent context — small breadcrumb to the parent session so the
                // user knows which session this subagent belongs to.
                LabeledContent("Parent") {
                    Text(parent.displayName)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                // Launch prompt occupies the space where a session would show
                // its project path / branch.
                if let prompt = subagent.launchPrompt, !prompt.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Launch Prompt")
                            .font(.headline)
                        Text(prompt)
                            .textSelection(.enabled)
                            .font(.callout)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

                // Question text
                if case .waitingForQuestion(_, let question) = subagent.status, let question {
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

                // Transcript
                Divider()
                transcriptSection

                Spacer()
            }
            .padding()
        }
        .accessibilityIdentifier("subagent-detail")
        .onAppear { triggerLoad() }
        .onChange(of: subagent.id) { _, _ in triggerLoad() }
    }

    // MARK: - Transcript

    private var transcript: [TranscriptMessage] {
        transcriptLoader.cachedTranscripts[subagent.transcriptKey] ?? subagent.transcript
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
                    if case .loading(let p) = transcriptLoader.loadStates[subagent.transcriptKey] { return p }
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
                    ForEach(transcript.reversed()) { message in
                        transcriptBubble(message)
                    }
                }
            }
        }
    }

    private func transcriptBubble(_ message: TranscriptMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(message.role == "user" ? "Parent" : "Subagent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(message.role == "user" ? .blue : .purple)

                if let ts = message.timestamp {
                    Text(ts, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if !message.text.isEmpty {
                Text(message.text)
                    .textSelection(.enabled)
                    .font(.callout)
            }

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

    // MARK: - Helpers

    private func triggerLoad() {
        transcriptLoader.loadIfNeeded(transcriptKey: subagent.transcriptKey, jsonlPath: subagent.jsonlPath)
    }

    private var statusText: String {
        let title = subagent.status.sectionTitle
        let elapsed = subagent.status.elapsed
        if elapsed > 0 {
            return "\(title) (\(elapsed.formattedDuration))"
        }
        return title
    }
}
