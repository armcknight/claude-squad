import AppKit
import Combine
import UserNotifications

/// Manages the macOS menu-bar status item and rebuilds the NSMenu whenever
/// the session list changes.
final class MenuBarController {

    private var statusItem: NSStatusItem!
    private let monitor: SessionMonitor
    private var cancellables = Set<AnyCancellable>()
    weak var logger: Logger?

    /// Tracks which sessions we've already sent notifications for (to avoid duplicates).
    private var notifiedStates: [String: Int] = [:]

    /// Callback to show the main application window.
    var onShowWindow: (() -> Void)?

    init(monitor: SessionMonitor) {
        self.monitor = monitor
        setupStatusItem()
        setupNotifications()
        subscribeToMonitor()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "person.crop.circle.badge.checkmark", accessibilityDescription: "Claude Squad")
            button.imagePosition = .imageLeading
        }
        rebuildMenu(sessions: [])
    }

    private func setupNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error = error {
                self?.logger?.error("Notification authorization failed: \(error.localizedDescription)")
            } else {
                self?.logger?.debug("Notification authorization granted: \(granted)")
            }
        }
        monitor.onNeedsAttention = { [weak self] session in
            self?.postNotification(for: session)
        }
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

    // MARK: - Icon updates

    private func updateIcon(sessions: [ClaudeSession]) {
        let symbolName: String
        if sessions.contains(where: { $0.status.isWaiting }) {
            symbolName = "person.crop.circle.badge.exclamationmark.fill"
        } else if sessions.contains(where: { if case .running = $0.status { return true }; return false }) {
            symbolName = "person.crop.circle.badge.clock.fill"
        } else {
            symbolName = "person.crop.circle.badge.checkmark"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Claude Squad")
    }

    // MARK: - Notifications

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
        logger?.info("Posting notification for \(session.displayName): \(content.title)")
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Menu construction

    private func rebuildMenu(sessions: [ClaudeSession]) {
        logger?.debug("Rebuilding menu with \(sessions.count) session(s)")
        let menu = NSMenu()

        if sessions.isEmpty {
            let empty = NSMenuItem(title: "No Claude sessions detected", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for session in sessions {
                logger?.debug("  Menu item: \(session.displayName) [\(session.status)]")
                menu.addItem(menuItem(for: session))
            }
        }

        menu.addItem(.separator())

        let showWindow = NSMenuItem(title: "Show Window", action: #selector(handleShowWindow), keyEquivalent: "w")
        showWindow.target = self
        menu.addItem(showWindow)

        menu.addItem(.separator())

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

        // Build submenu with details.
        let submenu = NSMenu()

        let pathItem = NSMenuItem(title: session.projectPath, action: nil, keyEquivalent: "")
        pathItem.isEnabled = false
        submenu.addItem(pathItem)

        if let branch = session.gitBranch {
            let branchItem = NSMenuItem(title: "Branch: \(branch)", action: nil, keyEquivalent: "")
            branchItem.isEnabled = false
            submenu.addItem(branchItem)
        }

        if let tasks = session.taskSummary {
            let taskItem = NSMenuItem(
                title: "Tasks: \(tasks.completed)/\(tasks.total) done, \(tasks.inProgress) active",
                action: nil, keyEquivalent: ""
            )
            taskItem.isEnabled = false
            submenu.addItem(taskItem)
        }

        submenu.addItem(.separator())

        let openTerminal = NSMenuItem(title: "Open in Terminal", action: #selector(handleOpenTerminal(_:)), keyEquivalent: "")
        openTerminal.target = self
        openTerminal.representedObject = session.projectPath
        submenu.addItem(openTerminal)

        item.submenu = submenu
        return item
    }

    private func menuTitle(for session: ClaudeSession) -> String {
        let branchSuffix = session.gitBranch.map { " (\($0))" } ?? ""
        let name = "\(session.displayName)\(branchSuffix)"

        switch session.status {
        case .running:
            return "⚡ \(name) — running"
        case .waitingForQuestion(let since, _):
            return "❓ \(name) — question (\(Date().timeIntervalSince(since).formattedDuration))"
        case .waitingIdle(let since):
            return "⏳ \(name) — idle (\(Date().timeIntervalSince(since).formattedDuration))"
        case .interrupted(let lastActivity):
            return "⛔ \(name) — interrupted (\(Date().timeIntervalSince(lastActivity).formattedDuration) ago)"
        case .inactive(let lastActivity):
            return "⏸ \(name) — inactive (\(Date().timeIntervalSince(lastActivity).formattedDuration) ago)"
        }
    }

    // MARK: - Actions

    @objc private func handleSessionClick(_ sender: NSMenuItem) {
        guard let sessionID = sender.representedObject as? String,
              let session = monitor.sessions.first(where: { $0.id == sessionID }) else { return }
        logger?.debug("Opening terminal for session \(session.displayName) at \(session.projectPath)")
        TerminalLauncher.open(at: session.projectPath, logger: logger)
    }

    @objc private func handleOpenTerminal(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        logger?.debug("Opening terminal at \(path)")
        TerminalLauncher.open(at: path, logger: logger)
    }

    @objc private func handleRefresh() {
        monitor.refresh()
    }

    @objc private func handleShowWindow() {
        onShowWindow?()
    }
}
