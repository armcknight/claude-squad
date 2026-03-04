import SwiftUI

extension SessionStatus {
    var color: Color {
        switch self {
        case .running: return .blue
        case .waitingForQuestion: return .orange
        case .waitingIdle: return .yellow
        case .interrupted: return .red
        case .inactive: return .gray
        }
    }
}

/// A single row in the session sidebar list.
/// Path on line 1, branch on line 2. Elapsed time and task count right-aligned.
struct SessionRowView: View {
    let session: ClaudeSession

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let branch = session.gitBranch {
                    Text(branch)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if session.status.elapsed > 0 {
                    Text(session.status.elapsed.formattedDuration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if let tasks = session.taskSummary {
                    Text("\(tasks.completed)/\(tasks.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 2)
    }
}
