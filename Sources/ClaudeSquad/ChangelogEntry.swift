import Foundation

struct ChangelogEntry: Identifiable {
    let id: String
    let version: String
    let date: String
    let content: String

    /// Parses a CHANGELOG.md string into an array of entries.
    /// Expects headers in the format: `## [VERSION] - DATE`
    static func parse(from markdown: String) -> [ChangelogEntry] {
        let lines = markdown.components(separatedBy: "\n")
        var entries: [ChangelogEntry] = []
        var currentVersion: String?
        var currentDate: String?
        var currentLines: [String] = []

        for line in lines {
            if line.hasPrefix("## [") {
                // Flush previous entry
                if let version = currentVersion, let date = currentDate {
                    let content = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    entries.append(ChangelogEntry(id: version, version: version, date: date, content: content))
                }

                // Parse new header
                let stripped = line.dropFirst(4) // drop "## ["
                if let closeBracket = stripped.firstIndex(of: "]") {
                    currentVersion = String(stripped[stripped.startIndex..<closeBracket])
                    let afterBracket = stripped[stripped.index(after: closeBracket)...]
                    currentDate = afterBracket
                        .trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "- ", with: "")
                        .trimmingCharacters(in: .whitespaces)
                } else {
                    currentVersion = nil
                    currentDate = nil
                }
                currentLines = []
            } else if currentVersion != nil {
                currentLines.append(line)
            }
        }

        // Flush last entry
        if let version = currentVersion, let date = currentDate {
            let content = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(ChangelogEntry(id: version, version: version, date: date, content: content))
        }

        return entries
    }

    /// Returns entries between two versions (exclusive of lastVersion, inclusive of currentVersion).
    static func entriesBetween(lastVersion: String, currentVersion: String, from entries: [ChangelogEntry]) -> [ChangelogEntry] {
        guard let currentIndex = entries.firstIndex(where: { $0.version == currentVersion }) else {
            return []
        }
        let lastIndex = entries.firstIndex(where: { $0.version == lastVersion })
        let endIndex = lastIndex ?? entries.endIndex
        return Array(entries[currentIndex..<endIndex])
    }
}
