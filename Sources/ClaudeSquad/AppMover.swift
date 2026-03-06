import AppKit

enum AppMover {
    private static let suppressionKey = "SuppressMoveToApplications"

    /// Returns true if the app is already in /Applications.
    static var isInApplicationsFolder: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    /// Prompts the user to move the app to /Applications if it isn't already there.
    /// Respects a "Don't Ask Again" preference.
    static func offerToMoveIfNeeded(logger: Logger?, analytics: AnalyticsProvider?, errorReporter: ErrorReporter?) {
        guard !isInApplicationsFolder else { return }
        guard !UserDefaults.standard.bool(forKey: suppressionKey) else {
            analytics?.track(event: AnalyticsEvent.moveToAppsSuppressed.rawValue, properties: nil)
            return
        }

        analytics?.track(event: AnalyticsEvent.moveToAppsPrompted.rawValue, properties: nil)

        let alert = NSAlert()
        alert.messageText = "Move to Applications?"
        alert.informativeText = "Claude Squad works best from the Applications folder. Move it there now?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Don't Ask Again")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            analytics?.track(event: AnalyticsEvent.moveToAppsAccepted.rawValue, properties: nil)
            moveToApplicationsFolder(logger: logger, errorReporter: errorReporter)
        case .alertThirdButtonReturn:
            analytics?.track(event: AnalyticsEvent.moveToAppsSuppressed.rawValue, properties: nil)
            UserDefaults.standard.set(true, forKey: suppressionKey)
        default:
            analytics?.track(event: AnalyticsEvent.moveToAppsDismissed.rawValue, properties: nil)
        }
    }

    @discardableResult
    private static func moveToApplicationsFolder(logger: Logger?, errorReporter: ErrorReporter?) -> Bool {
        let source = Bundle.main.bundleURL
        let appName = source.deletingPathExtension().lastPathComponent
        guard !appName.isEmpty else { return false }
        let destination = URL(fileURLWithPath: "/Applications/\(appName).app")

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
            } else {
                try FileManager.default.moveItem(at: source, to: destination)
            }

            // Relaunch from new location.
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1; open \"$1\"", "--", destination.path]
            try relaunch.run()

            NSApp.terminate(nil)
            return true
        } catch {
            logger?.error("Failed to move app to Applications: \(error.localizedDescription)")
            errorReporter?.capture(error: error)

            let errorAlert = NSAlert()
            errorAlert.messageText = "Could Not Move App"
            errorAlert.informativeText = "Claude Squad couldn't move itself to the Applications folder. You can move it manually.\n\nError: \(error.localizedDescription)"
            errorAlert.alertStyle = .warning
            errorAlert.runModal()
            return false
        }
    }
}
