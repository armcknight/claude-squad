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
/// Path on line 1, branch + git status on line 2. Elapsed time and task count right-aligned.
struct SessionRowView: View {
    let session: ClaudeSession
    var displayNameOverride: String?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayNameOverride ?? session.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 4) {
                    if let branch = session.gitBranch {
                        Text(branch)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    
                    if let gitStatus = session.gitStatus, gitStatus.hasChanges {
                        HStack(spacing: 3) {
                            // Dirty working directory indicator
                            if gitStatus.isDirty {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 6))
                                    .foregroundStyle(.orange)
                                    .help("Uncommitted changes")
                            }
                            
                            // Unpushed commits
                            if gitStatus.commitsAhead > 0 {
                                HStack(spacing: 2) {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.blue)
                                    Text("\(gitStatus.commitsAhead)")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                                .help("\(gitStatus.commitsAhead) unpushed commit\(gitStatus.commitsAhead == 1 ? "" : "s")")
                            }
                            
                            // Commits to pull
                            if gitStatus.commitsBehind > 0 {
                                HStack(spacing: 2) {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.green)
                                    Text("\(gitStatus.commitsBehind)")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                                .help("\(gitStatus.commitsBehind) commit\(gitStatus.commitsBehind == 1 ? "" : "s") available to pull")
                            }
                        }
                        .accessibilityLabel("Git status: \(gitStatus.summary)")
                    }
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
