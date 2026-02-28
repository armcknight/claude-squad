import SwiftUI

/// A single row in the session sidebar list.
struct SessionRowView: View {
    let session: ClaudeSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIconName)
                .foregroundStyle(statusColor)
                .font(.title3)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(session.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    if let branch = session.gitBranch {
                        Text(branch)
                            .font(.caption)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary)
                            .clipShape(Capsule())
                            .lineLimit(1)
                    }

                    Spacer()

                    if let tasks = session.taskSummary {
                        Text("\(tasks.completed)/\(tasks.total)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(statusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
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

    private var statusDescription: String {
        switch session.status {
        case .running:
            return "Running"
        case .waitingForQuestion(let since, _):
            return "Question (\(Date().timeIntervalSince(since).formattedDuration))"
        case .waitingIdle(let since):
            return "Idle (\(Date().timeIntervalSince(since).formattedDuration))"
        case .inactive(let lastActivity):
            return "Inactive (\(Date().timeIntervalSince(lastActivity).formattedDuration) ago)"
        }
    }
}
