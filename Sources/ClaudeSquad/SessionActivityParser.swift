import Foundation

/// Reads a session or subagent JSONL file from start to end and extracts the
/// data needed for statistics: entry timestamps, project path, and token usage.
final class SessionActivityParser {

    enum ParseError: Error, LocalizedError {
        case cannotOpen(path: String)

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let path):
                return "Cannot open JSONL file at \(path)"
            }
        }
    }

    private let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private let readChunkSize = 65536

    /// Parses the file at `path`. Returns nil if the file contains no
    /// timestamped entries. Throws if the file cannot be opened.
    func parse(jsonlPath path: String, isSubagent: Bool) throws -> SessionActivityRecord? {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw ParseError.cannotOpen(path: path)
        }
        defer { handle.closeFile() }

        var timestamps: [Date] = []
        var sessionId: String?
        var projectPath: String?
        var usage = TokenUsage.zero
        var countedMessageIds = Set<String>()

        var buffer = Data()
        while true {
            let chunk = handle.readData(ofLength: readChunkSize)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            var lineStart = buffer.startIndex
            while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
                processLine(
                    buffer[lineStart..<newline],
                    timestamps: &timestamps,
                    sessionId: &sessionId,
                    projectPath: &projectPath,
                    usage: &usage,
                    countedMessageIds: &countedMessageIds
                )
                lineStart = buffer.index(after: newline)
            }
            buffer = Data(buffer[lineStart...])
        }
        if !buffer.isEmpty {
            processLine(
                buffer[...],
                timestamps: &timestamps,
                sessionId: &sessionId,
                projectPath: &projectPath,
                usage: &usage,
                countedMessageIds: &countedMessageIds
            )
        }

        let fallbackId = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return SessionActivityRecord(
            sessionId: sessionId ?? fallbackId,
            projectPath: projectPath,
            isSubagent: isSubagent,
            timestamps: timestamps,
            tokenUsage: usage
        )
    }
}

private extension SessionActivityParser {
    func processLine(
        _ line: Data,
        timestamps: inout [Date],
        sessionId: inout String?,
        projectPath: inout String?,
        usage: inout TokenUsage,
        countedMessageIds: inout Set<String>
    ) {
        guard !line.isEmpty else { return }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: line)
        } catch {
            // Partially written trailing lines are expected while Claude is
            // writing; skip any line that is not valid JSON.
            return
        }
        guard let json = object as? [String: Any] else { return }

        if let timestampString = json["timestamp"] as? String, let date = parseTimestamp(timestampString) {
            timestamps.append(date)
        }
        if sessionId == nil, let id = json["sessionId"] as? String {
            sessionId = id
        }
        if projectPath == nil, let cwd = json["cwd"] as? String {
            projectPath = cwd
        }

        guard json["type"] as? String == "assistant",
              let message = json["message"] as? [String: Any],
              let usageJSON = message["usage"] as? [String: Any] else { return }

        // Claude writes one JSONL line per content block of a streamed
        // message, and each line repeats the same usage. Count each message once.
        if let messageId = message["id"] as? String {
            guard countedMessageIds.insert(messageId).inserted else { return }
        }
        let input: Int = usageJSON["input_tokens"] as? Int ?? 0
        let output: Int = usageJSON["output_tokens"] as? Int ?? 0
        let cacheCreation: Int = usageJSON["cache_creation_input_tokens"] as? Int ?? 0
        let cacheRead: Int = usageJSON["cache_read_input_tokens"] as? Int ?? 0
        usage += TokenUsage(input: input, output: output, cacheCreation: cacheCreation, cacheRead: cacheRead)
    }

    func parseTimestamp(_ string: String) -> Date? {
        fractionalFormatter.date(from: string) ?? plainFormatter.date(from: string)
    }
}
