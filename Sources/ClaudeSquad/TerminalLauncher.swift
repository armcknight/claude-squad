import Foundation
import AppKit

/// Opens a terminal window at a given directory. Detects iTerm2 or falls back to Terminal.app.
enum TerminalLauncher {

    /// Opens the preferred terminal application at the given directory path.
    static func open(at directoryPath: String, logger: Logger?) {
        if isITermInstalled() {
            logger?.debug("Launching iTerm2 at \(directoryPath)")
            openITerm(at: directoryPath)
        } else {
            logger?.debug("Launching Terminal.app at \(directoryPath)")
            openTerminalApp(at: directoryPath)
        }
    }

    // MARK: - Detection

    static func isITermInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil
    }

    // MARK: - iTerm2

    private static func openITerm(at path: String) {
        let safePath = path.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "iTerm2"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow
                write text "cd \\"\(safePath)\\""
            end tell
        end tell
        """
        runAppleScript(script)
    }

    // MARK: - Terminal.app

    private static func openTerminalApp(at path: String) {
        let safePath = path.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "cd \\"\(safePath)\\""
        end tell
        """
        runAppleScript(script)
    }

    // MARK: - AppleScript runner

    @discardableResult
    private static func runAppleScript(_ script: String) -> Bool {
        var error: NSDictionary?
        if let scriptObj = NSAppleScript(source: script) {
            scriptObj.executeAndReturnError(&error)
            if error != nil {
                return false
            }
            return true
        }
        return false
    }
}
