import AppKit
import ArkanaKeys
import SwiftUI
import UserNotifications

@objc final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Composition root — strong ownership of all services

    private let logger = Logger()
    private let errorReporter: ErrorReporter
    private let analyticsProvider: AnalyticsProvider

    private let loginItemManager = LoginItemManager()
    private let globalHotkey = GlobalHotkey()
    private let detector: ClaudeSessionDetector
    private let monitor: SessionMonitor
    private var window: NSWindow?
    private var settingsWindow: NSWindow?

    override init() {
        let keys = ArkanaKeys.Global()

        // Error reporting
        let sentryDSN = keys.sentryDSN
        if !sentryDSN.isEmpty {
            errorReporter = SentryErrorReporter(dsn: sentryDSN)
        } else {
            errorReporter = NoOpErrorReporter()
        }

        // Analytics
        let amplitudeKey = keys.amplitudeAPIKey
        if !amplitudeKey.isEmpty {
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

        requestNotificationAuthorization()

        // Show the app in the Dock and App Switcher.
        NSApp.setActivationPolicy(.regular)

        setupMainMenu()
        setupWindow()
        setupNotificationHandler()
        setupGlobalHotkey()
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
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Claude Squad", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Claude Squad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu (for Close Window)
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func showSettings() {
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let settingsView = SettingsView(loginItemManager: loginItemManager, globalHotkey: globalHotkey, logger: logger)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Settings"
        window.contentViewController = NSHostingController(rootView: settingsView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.settingsWindow = window
    }

    // MARK: - Global Hotkey

    private func setupGlobalHotkey() {
        globalHotkey.logger = logger
        globalHotkey.register { [weak self] in
            DispatchQueue.main.async {
                self?.showWindow()
            }
        }
    }

    // MARK: - Notifications

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error {
                self?.logger.error("Notification authorization failed: \(error.localizedDescription)")
            } else {
                self?.logger.info("Notification authorization granted: \(granted)")
            }
        }
    }

    private func setupNotificationHandler() {
        monitor.onNeedsAttention = { [weak self] session in
            self?.postNotification(for: session)
        }
    }

    private func postNotification(for session: ClaudeSession) {
        let content = UNMutableNotificationContent()
        content.sound = .default

        switch session.status {
        case .waitingForQuestion(_, let question):
            content.title = "\(session.displayName) needs input"
            content.body = question ?? "Claude is asking a question"
        case .waitingIdle:
            content.title = "\(session.displayName) is idle"
            content.body = "Claude has finished and is waiting for your next instruction"
        default:
            return
        }

        let request = UNNotificationRequest(
            identifier: "claude-squad-\(session.id)-\(session.status.sortPriority)",
            content: content,
            trigger: nil
        )
        logger.info("Posting notification for \(session.displayName): \(content.title)")
        UNUserNotificationCenter.current().add(request)
    }
}
