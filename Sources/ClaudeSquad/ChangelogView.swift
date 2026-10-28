import Pippin
import SwiftUI

struct ChangelogView: View {
    let entries: [ChangelogEntry]
    let isWhatsNew: Bool

    init(entries: [ChangelogEntry], isWhatsNew: Bool = false) {
        self.entries = entries
        self.isWhatsNew = isWhatsNew
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
                    ForEach(entries, id: \.version) { entry in
                        ChangelogEntryView(entry: entry)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("v\(entry.version)")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                if let date = entry.date {
                    Text(date)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
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
        return (try? AttributedString(markdown: result.trimmingCharacters(in: .whitespacesAndNewlines))) ?? AttributedString(result)
    }
}
