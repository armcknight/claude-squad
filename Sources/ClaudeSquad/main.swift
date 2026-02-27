import AppKit
import ClaudeSquadLib

// NSApplicationMain macro is unavailable in SPM executable targets,
// so we bootstrap manually in main.swift.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
