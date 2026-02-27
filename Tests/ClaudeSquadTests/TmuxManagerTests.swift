import XCTest
@testable import ClaudeSquad

final class TmuxManagerTests: XCTestCase {

    let tmux = TmuxManager()

    // MARK: - isWaitingForInput

    func test_runningWhenSpinnerPresent() {
        // Any braille spinner character in the last 20 lines → running.
        let content = makePaneContent(lastLines: ["⠋ Thinking..."])
        XCTAssertFalse(tmux.isWaitingForInput(paneContent: content))
    }

    func test_runningWhenSpinnerPresentMidContent() {
        let content = makePaneContent(lastLines: Array(repeating: "some output", count: 5) + ["⠼ Generating"])
        XCTAssertFalse(tmux.isWaitingForInput(paneContent: content))
    }

    func test_waitingWhenClaudeCodeInputBoxPresent() {
        // Claude Code TUI shows "│ >" when awaiting user input.
        let content = makePaneContent(lastLines: [
            "╭─────────────────────────────────────╮",
            "│ >                                   │",
            "╰─────────────────────────────────────╯"
        ])
        XCTAssertTrue(tmux.isWaitingForInput(paneContent: content))
    }

    func test_waitingWhenBarePromptAtEnd() {
        let content = makePaneContent(lastLines: ["Human turn, please type:",">" ])
        XCTAssertTrue(tmux.isWaitingForInput(paneContent: content))
    }

    func test_waitingWhenBarePromptWithSpace() {
        let content = makePaneContent(lastLines: ["  > "])
        XCTAssertTrue(tmux.isWaitingForInput(paneContent: content))
    }

    func test_runningWhenNoIndicators() {
        // No spinner, no prompt → conservative default → running.
        let content = makePaneContent(lastLines: ["Claude is done writing the file.", ""])
        XCTAssertFalse(tmux.isWaitingForInput(paneContent: content))
    }

    func test_spinnerTakesPrecedenceOverPrompt() {
        // If a spinner AND a prompt both appear (unlikely but defensive), spinner wins → running.
        let content = makePaneContent(lastLines: ["⠋ ", "│ >"])
        XCTAssertFalse(tmux.isWaitingForInput(paneContent: content))
    }

    func test_emptyPane() {
        XCTAssertFalse(tmux.isWaitingForInput(paneContent: ""))
    }

    // MARK: - Session sorting

    func test_waitingSessionSortsBeforeRunning() {
        let waiting = ClaudeSession(id: "a", status: .waitingForInput(since: Date()), paneTTY: nil)
        let running = ClaudeSession(id: "b", status: .running, paneTTY: nil)
        XCTAssertLessThan(waiting, running)
    }

    func test_longerWaitSortsFirst() {
        let older = ClaudeSession(id: "a", status: .waitingForInput(since: Date(timeIntervalSinceNow: -120)), paneTTY: nil)
        let newer = ClaudeSession(id: "b", status: .waitingForInput(since: Date(timeIntervalSinceNow: -10)), paneTTY: nil)
        XCTAssertLessThan(older, newer)
    }

    func test_twoRunningSortEqual() {
        let r1 = ClaudeSession(id: "a", status: .running, paneTTY: nil)
        let r2 = ClaudeSession(id: "b", status: .running, paneTTY: nil)
        // Neither is less-than the other.
        XCTAssertFalse(r1 < r2)
        XCTAssertFalse(r2 < r1)
    }

    func test_sortedArrayOrder() {
        let r = ClaudeSession(id: "running", status: .running, paneTTY: nil)
        let w1 = ClaudeSession(id: "wait1", status: .waitingForInput(since: Date(timeIntervalSinceNow: -60)), paneTTY: nil)
        let w2 = ClaudeSession(id: "wait2", status: .waitingForInput(since: Date(timeIntervalSinceNow: -5)), paneTTY: nil)
        let sorted = [r, w2, w1].sorted()
        XCTAssertEqual(sorted.map(\.id), ["wait1", "wait2", "running"])
    }

    // MARK: - ITermManager script construction

    func test_focusScriptContainsTTY() {
        let script = ITermManager.shared.focusScript(tty: "/dev/ttys003")
        XCTAssertTrue(script.contains("/dev/ttys003"))
        XCTAssertTrue(script.contains("iTerm2"))
    }

    func test_focusScriptEscapesQuotes() {
        // Paranoia: TTY paths won't have quotes, but we verify escaping is handled.
        let script = ITermManager.shared.focusScript(tty: "/dev/tty\"s003")
        XCTAssertTrue(script.contains("/dev/tty\\\"s003"))
    }

    // MARK: - SessionStatus helpers

    func test_isWaiting() {
        XCTAssertTrue(SessionStatus.waitingForInput(since: Date()).isWaiting)
        XCTAssertFalse(SessionStatus.running.isWaiting)
    }

    func test_waitingDuration() {
        let since = Date(timeIntervalSinceNow: -30)
        let duration = SessionStatus.waitingForInput(since: since).waitingDuration
        XCTAssertGreaterThanOrEqual(duration, 29)
        XCTAssertLessThan(duration, 35)
    }

    func test_runningDurationIsZero() {
        XCTAssertEqual(SessionStatus.running.waitingDuration, 0)
    }

    // MARK: - isClaudeCommand

    func test_isClaudeCommandBare() {
        XCTAssertTrue(tmux.isClaudeCommand("claude"))
    }

    func test_isClaudeCommandFullPath() {
        XCTAssertTrue(tmux.isClaudeCommand("/usr/local/bin/claude"))
    }

    func test_isClaudeCommandWithArgs() {
        XCTAssertTrue(tmux.isClaudeCommand("claude --continue"))
    }

    func test_isClaudeCommandDoesNotMatchUnrelated() {
        XCTAssertFalse(tmux.isClaudeCommand("bash"))
        XCTAssertFalse(tmux.isClaudeCommand("zsh"))
        XCTAssertFalse(tmux.isClaudeCommand("node"))
    }

    func test_isClaudeCommandCaseInsensitive() {
        XCTAssertTrue(tmux.isClaudeCommand("Claude"))
        XCTAssertTrue(tmux.isClaudeCommand("CLAUDE"))
    }

    // MARK: - Helpers

    private func makePaneContent(lastLines: [String]) -> String {
        // Simulate some earlier output followed by the provided lines.
        let header = (0..<5).map { "Earlier output line \($0)" }
        return (header + lastLines).joined(separator: "\n")
    }
}
