import Foundation

/// Wraps tmux CLI calls to discover Claude sessions and inspect their state.
final class TmuxManager {

    static let shared = TmuxManager()

    // MARK: - Raw result type

    /// Intermediate result returned by `probeSessions` before timestamps are applied.
    struct RawSessionInfo {
        let name: String
        let isWaiting: Bool
        let tty: String?
    }

    // MARK: - Public API

    /// Returns raw info for every tmux session that contains a running `claude` process.
    /// Callers (e.g. `SessionMonitor`) are responsible for constructing `ClaudeSession`
    /// values and managing the `waitingForInput(since:)` timestamps.
    func probeSessions() throws -> [RawSessionInfo] {
        let allSessions = try listAllSessions()
        var result: [RawSessionInfo] = []
        for name in allSessions {
            do {
                if let info = try probeSession(name: name) {
                    result.append(info)
                }
            } catch {
                // A single session failure should not prevent others from being shown.
                // Errors are non-critical (e.g. a session was destroyed mid-poll).
                continue
            }
        }
        return result
    }

    // MARK: - Internal helpers

    /// All tmux session names (not filtered for Claude).
    func listAllSessions() throws -> [String] {
        let output = try runTmux(["list-sessions", "-F", "#S"])
        return output.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    /// Returns a `RawSessionInfo` for `name`, or `nil` if no `claude` process is found.
    func probeSession(name: String) throws -> RawSessionInfo? {
        guard try paneRunsClaude(session: name) else { return nil }
        let ttyRaw = try paneTTY(session: name)
        let tty = ttyRaw.isEmpty ? nil : ttyRaw
        let paneContent = try capturePane(session: name)
        let waiting = isWaitingForInput(paneContent: paneContent)
        return RawSessionInfo(name: name, isWaiting: waiting, tty: tty)
    }

    /// Returns the TTY device of the first pane in the session.
    func paneTTY(session: String) throws -> String {
        let raw = try runTmux(["display-message", "-t", session, "-p", "#{pane_tty}"])
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns `true` if a `claude` process is running inside any pane of `session`.
    func paneRunsClaude(session: String) throws -> Bool {
        // Get the shell PID for each pane in this tmux session.
        let pidsRaw = try runTmux(["list-panes", "-t", session, "-F", "#{pane_pid}"])
        let pids = Set(pidsRaw.components(separatedBy: "\n").filter { !$0.isEmpty })
        guard !pids.isEmpty else { return false }

        // `ps ax -o pid=,ppid=,comm=` lists all processes (macOS-compatible flags).
        // We look for any process whose PID or PPID matches the pane's shell PID
        // and whose command name is "claude".
        let psOutput = (try? runShell("/bin/ps", args: ["ax", "-o", "pid=,ppid=,comm="])) ?? ""
        for line in psOutput.components(separatedBy: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces)
                            .components(separatedBy: .whitespaces)
                            .filter { !$0.isEmpty }
            guard parts.count >= 3 else { continue }
            let pid = parts[0]
            let ppid = parts[1]
            let comm = parts[2...].joined(separator: " ")
            if (pids.contains(pid) || pids.contains(ppid)) && isClaudeCommand(comm) {
                return true
            }
        }
        return false
    }

    /// Captures the visible content of the first pane in `session`.
    func capturePane(session: String) throws -> String {
        // -J joins wrapped lines; -p prints to stdout.
        return try runTmux(["capture-pane", "-t", session, "-p", "-J"])
    }

    // MARK: - State detection

    /// Heuristically determines whether the pane is waiting for user input.
    ///
    /// Detection strategy (in order of specificity):
    /// 1. If a braille-spinner character is present in the last 20 lines → **running**.
    /// 2. If Claude Code's input-box pattern `│ >` appears in the last 10 lines → **waiting**.
    /// 3. If the last non-empty line ends with `> ` (bare REPL/shell prompt) → **waiting**.
    /// 4. Default → **running** (conservative: don't nag unless we're sure).
    func isWaitingForInput(paneContent: String) -> Bool {
        let lines = paneContent.components(separatedBy: "\n")

        // 1. Spinner → definitely still running.
        let spinnerChars: Set<Character> = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        let recentContent = lines.suffix(20).joined()
        if recentContent.contains(where: { spinnerChars.contains($0) }) {
            return false
        }

        let lastLines = lines.suffix(10)

        // 2. Claude Code TUI input box pattern.
        if lastLines.contains(where: { $0.contains("│ >") }) {
            return true
        }

        // 3. Bare prompt pattern at end of last meaningful line.
        if let lastMeaningful = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let stripped = lastMeaningful.trimmingCharacters(in: .whitespaces)
            if stripped.hasSuffix("> ") || stripped == ">" {
                return true
            }
        }

        return false
    }

    // MARK: - Process helpers

    /// Returns `true` if `command` (as reported by `ps comm=`) represents the Claude CLI.
    func isClaudeCommand(_ command: String) -> Bool {
        // The `comm=` column may be a full path or just the binary name.
        let basename = command.components(separatedBy: "/").last ?? command
        let lower = basename.trimmingCharacters(in: .whitespaces).lowercased()
        return lower == "claude" || lower.hasPrefix("claude ")
    }

    // MARK: - Shell execution

    func runTmux(_ args: [String]) throws -> String {
        return try runShell("/usr/bin/env", args: ["tmux"] + args)
    }

    func runShell(_ executable: String, args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
