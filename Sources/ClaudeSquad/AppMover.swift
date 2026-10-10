import AppKit

enum AppMover {
    private static let suppressionKey = "SuppressMoveToApplications"

    /// Launch argument that skips the /Applications location check entirely.
    /// Used by developers running from DerivedData, and passed explicitly by the UI tests.
    static let skipLocationCheckArgument = "--skip-app-location-check"

    /// Returns true if the app is already in /Applications.
    static var isInApplicationsFolder: Bool {
        isInApplicationsFolder(bundlePath: Bundle.main.bundlePath)
    }

    static func isInApplicationsFolder(bundlePath: String) -> Bool {
        bundlePath.hasPrefix("/Applications/")
    }

    /// Returns true if the launch arguments request skipping the location check.
    static func shouldSkipLocationCheck(arguments: [String]) -> Bool {
        arguments.contains(skipLocationCheckArgument)
    }

    /// Prompts the user to move the app to /Applications if it isn't already there.
    /// Respects a "Don't Ask Again" preference.
    static func offerToMoveIfNeeded(logger: Logger?, analytics: AnalyticsProvider?, errorReporter: ErrorReporter?) {
        // A modal blocks the main thread, which stops XCTest from ever connecting
        // to the host app — the test runner just hangs. Tests always run from
        // DerivedData, so the isInApplicationsFolder guard below never saves us.
        guard !isRunningUnderTest else { return }
        guard !shouldSkipLocationCheck(arguments: CommandLine.arguments) else {
            logger?.info("Skipping Applications folder check (\(skipLocationCheckArgument))")
            return
        }
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

private extension AppMover {
    /// True when hosted by XCTest (unit tests) or launched by the UI tests, which
    /// pass `--mock`.
    static var isRunningUnderTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.arguments.contains("--mock")
    }
}
