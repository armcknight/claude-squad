import SwiftUI

/// Card for one badge. Earned badges are shown in color; others are dimmed
/// with a progress bar toward the threshold.
struct BadgeTile: View {
    let badge: Badge

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: badge.iconName)
                .font(.title2)
                .foregroundStyle(badge.isEarned ? Color.orange : Color.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(badge.title)
                    .font(.subheadline.weight(.semibold))
                Text(badge.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !badge.isEarned {
                    ProgressView(value: badge.progress)
                        .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .opacity(badge.isEarned ? 1 : 0.6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("badge-\(badge.id)")
    }
}
