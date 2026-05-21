import SwiftUI

/// A compact row representing a single subagent under its parent session in
/// the sidebar. No project path or branch (those mirror the parent — see CLA-7).
struct SubagentRowView: View {
    let subagent: Subagent

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: subagent.status.iconName)
                .foregroundStyle(subagent.status.color)
                .font(.caption)

            VStack(alignment: .leading, spacing: 1) {
                Text(subagent.displayLabel)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let description = subagent.taskDescription, !description.isEmpty {
                    Text(description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer()

            if subagent.status.elapsed > 0 {
                Text(subagent.status.elapsed.formattedDuration)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 1)
    }
}
