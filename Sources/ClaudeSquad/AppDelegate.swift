import AppKit
import SwiftUI

@objc final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBarController: MenuBarController?
    private let monitor = SessionMonitor()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.info("Application launching")

        // Show the app in the Dock and App Switcher.
        NSApp.setActivationPolicy(.regular)

        menuBarController = MenuBarController(monitor: monitor)
        menuBarController?.onShowWindow = { [weak self] in
            self?.showWindow()
        }

        setupWindow()
        monitor.start()

        Logger.info("Application started, monitoring active")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Logger.info("Application terminating")
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Claude Squad"
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
