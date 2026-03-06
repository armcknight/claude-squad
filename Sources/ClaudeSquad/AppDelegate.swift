import AppKit
import SwiftUI

@objc final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Composition root — strong ownership of all services

    private let logger = Logger()
    private let errorReporter: ErrorReporter
    private let analyticsProvider: AnalyticsProvider

    private let detector: ClaudeSessionDetector
    private let monitor: SessionMonitor
    private var menuBarController: MenuBarController?
    private var window: NSWindow?

    override init() {
        // Error reporting
        if let sentryDSN = Bundle.main.infoDictionary?["SENTRY_DSN"] as? String, !sentryDSN.isEmpty {
            errorReporter = SentryErrorReporter(dsn: sentryDSN)
        } else {
            errorReporter = NoOpErrorReporter()
        }

        // Analytics
        if let amplitudeKey = Bundle.main.infoDictionary?["AMPLITUDE_API_KEY"] as? String, !amplitudeKey.isEmpty {
            analyticsProvider = AmplitudeAnalyticsProvider(apiKey: amplitudeKey)
        } else {
            analyticsProvider = NoOpAnalyticsProvider()
        }

        // Session detection
        #if DEBUG
        if CommandLine.arguments.contains("--mock") {
            let mockMonitor = SessionMonitor.mock(logger: logger)
            self.detector = ClaudeSessionDetector() // unused in mock, but needed for stored property
            self.monitor = mockMonitor
            super.init()
            return
        }
        #endif

        let detector = ClaudeSessionDetector()
        detector.logger = logger
        self.detector = detector

        let monitor = SessionMonitor(detector: detector, refreshInterval: 3)
        monitor.logger = logger
        monitor.analytics = analyticsProvider
        self.monitor = monitor

        super.init()

        // TranscriptLoader is @MainActor — set logger after init on main thread.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            monitor.transcriptLoader.logger = self.logger
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("Application launching")

        errorReporter.configure()
        analyticsProvider.configure()

        // Show the app in the Dock and App Switcher.
        NSApp.setActivationPolicy(.regular)

        let menuBar = MenuBarController(monitor: monitor)
        menuBar.logger = logger
        menuBar.onShowWindow = { [weak self] in
            self?.showWindow()
        }
        self.menuBarController = menuBar

        setupWindow()
        monitor.start()

        analyticsProvider.track(event: AnalyticsEvent.appLaunched.rawValue, properties: nil)
        logger.info("Application started, monitoring active")

        // Offer to move to /Applications after the window is visible.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            AppMover.offerToMoveIfNeeded(
                logger: self.logger,
                analytics: self.analyticsProvider,
                errorReporter: self.errorReporter
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("Application terminating")
        analyticsProvider.track(event: AnalyticsEvent.appTerminated.rawValue, properties: nil)
        monitor.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showWindow()
        }
        return true
    }

    // MARK: - Window

    private func setupWindow() {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = min(960, screenFrame.width * 0.6)
        let height: CGFloat = min(640, screenFrame.height * 0.7)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Claude Squad"
        window.contentMinSize = NSSize(width: 500, height: 300)
        window.contentViewController = NSHostingController(
            rootView: SessionListView(monitor: monitor)
        )
        window.setFrameAutosaveName("MainWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    private func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
