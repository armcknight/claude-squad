import AppKit
import Combine

/// Manages the macOS menu-bar status item and rebuilds the NSMenu whenever
/// the session list changes.
final class MenuBarController {

    private var statusItem: NSStatusItem!
    private let monitor: SessionMonitor
    private var cancellables = Set<AnyCancellable>()

    init(monitor: SessionMonitor) {
        self.monitor = monitor
        setupStatusItem()
        subscribeToMonitor()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Claude Squad")
            button.imagePosition = .imageLeading
            button.title = " Claude"
        }
        // Build an initial (empty) menu right away.
        rebuildMenu(sessions: [])
    }

    private func subscribeToMonitor() {
        monitor.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.rebuildMenu(sessions: sessions)
                self?.updateIcon(sessions: sessions)
            }
            .store(in: &cancellables)

        monitor.$lastError
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildMenu(sessions: self?.monitor.sessions ?? [])
            }
            .store(in: &cancellables)
    }

    // MARK: - Menu construction

    private func rebuildMenu(sessions: [ClaudeSession]) {
        let menu = NSMenu()

        if sessions.isEmpty {
            let empty = NSMenuItem(title: "No Claude sessions detected", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for session in sessions {
                menu.addItem(menuItem(for: session))
            }
        }

        menu.addItem(.separator())

        // Error indicator.
        if let err = monitor.lastError {
            let errItem = NSMenuItem(title: "⚠️ \(err)", action: nil, keyEquivalent: "")
            errItem.isEnabled = false
            menu.addItem(errItem)
            menu.addItem(.separator())
        }

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(handleRefresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let quit = NSMenuItem(title: "Quit Claude Squad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func menuItem(for session: ClaudeSession) -> NSMenuItem {
        let title = menuTitle(for: session)
        let item = NSMenuItem(title: title, action: #selector(handleSessionClick(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = session.id
        return item
    }

    private func menuTitle(for session: ClaudeSession) -> String {
        switch session.status {
        case .running:
            return "⚡ \(session.displayName)  —  running"
        case .waitingForInput(let since):
            let duration = Date().timeIntervalSince(since)
            return "⏳ \(session.displayName)  —  waiting \(formatDuration(duration))"
        }
    }

    // MARK: - Icon update

    private func updateIcon(sessions: [ClaudeSession]) {
        guard let button = statusItem.button else { return }
        let anyWaiting = sessions.contains { $0.status.isWaiting }
        if anyWaiting {
            button.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: "Claude Squad – attention needed")
        } else {
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Claude Squad")
        }
    }

    // MARK: - Actions

    @objc private func handleSessionClick(_ sender: NSMenuItem) {
        guard let sessionID = sender.representedObject as? String,
              let session = monitor.sessions.first(where: { $0.id == sessionID }) else { return }

        if let tty = session.paneTTY {
            ITermManager.shared.focusWindow(for: tty)
        }
    }

    @objc private func handleRefresh() {
        monitor.refresh()
    }

    // MARK: - Helpers

    private func formatDuration(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if minutes < 60 { return "\(minutes)m \(remainingSeconds)s" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return "\(hours)h \(remainingMinutes)m"
    }
}
