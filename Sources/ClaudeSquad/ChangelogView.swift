import SwiftUI

struct ChangelogView: View {
    let entries: [ChangelogEntry]
    let isWhatsNew: Bool
    weak var logger: Logger?

    init(entries: [ChangelogEntry], isWhatsNew: Bool = false, logger: Logger?) {
        self.entries = entries
        self.isWhatsNew = isWhatsNew
        self.logger = logger
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if isWhatsNew {
                    Text("What's New")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .padding(.bottom, 4)
                }

                if entries.isEmpty {
                    Text("No changelog entries found.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { entry in
                        ChangelogEntryView(entry: entry, logger: logger)
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

private struct ChangelogEntryView: View {
    let entry: ChangelogEntry
    weak var logger: Logger?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("v\(entry.version)")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Text(entry.date)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(formatContent(entry.content))
                .font(.body)
                .textSelection(.enabled)
        }
    }

    private func formatContent(_ content: String) -> AttributedString {
        // Simple markdown-like formatting: convert "### Header" and "- item" lines
        var result = ""
        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("### ") {
                let header = String(line.dropFirst(4))
                result += "\n\(header)\n"
            } else if line.hasPrefix("- ") {
                result += "  \u{2022} \(String(line.dropFirst(2)))\n"
            } else if !line.isEmpty {
                result += "\(line)\n"
            }
        }
        do {
            return try AttributedString(markdown: result.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            // Fall back to plain text; the changelog is still readable without markdown styling.
            logger?.warning("ChangelogView: cannot parse markdown for \(entry.version): \(error.localizedDescription)")
            return AttributedString(result)
        }
    }
}
