import Foundation

/// Interacts with iTerm2 via AppleScript to locate and focus the window
/// whose terminal device matches the TTY of a tmux pane.
final class ITermManager {

    static let shared = ITermManager()

    // MARK: - Public API

    /// Brings the iTerm2 window/tab that owns `tty` to the front.
    /// - Parameter tty: TTY device path, e.g. "/dev/ttys003"
    /// - Returns: `true` if a matching window was found and activated.
    @discardableResult
    func focusWindow(for tty: String) -> Bool {
        let script = focusScript(tty: tty)
        return runAppleScript(script)
    }

    // MARK: - Script construction (internal for testability)

    func focusScript(tty: String) -> String {
        // Escape the tty string for insertion into AppleScript.
        let safeTTY = tty.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "iTerm2"
            set targetTTY to "\(safeTTY)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is equal to targetTTY then
                            tell application "System Events"
                                set frontmost of process "iTerm2" to true
                            end tell
                            select w
                            tell t to select
                            tell s to select
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
            return false
        end tell
        """
    }

    // MARK: - AppleScript runner

    @discardableResult
    private func runAppleScript(_ script: String) -> Bool {
        var error: NSDictionary?
        if let scriptObj = NSAppleScript(source: script) {
            let result = scriptObj.executeAndReturnError(&error)
            if error != nil { return false }
            // The script returns "true" on success.
            return result.stringValue == "true"
        }
        return false
    }
}
