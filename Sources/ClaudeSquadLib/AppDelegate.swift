import AppKit

@objc final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBarController: MenuBarController?
    private let monitor = SessionMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide the app from the Dock and App Switcher (equivalent to LSUIElement = true).
        NSApp.setActivationPolicy(.accessory)

        menuBarController = MenuBarController(monitor: monitor)
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }
}
