import AppKit
import Combine
import UserNotifications

/// Manages the macOS menu-bar status item and rebuilds the NSMenu whenever
/// the session list changes.
final class MenuBarController {

    private var statusItem: NSStatusItem!
    private let monitor: SessionMonitor
    private var cancellables = Set<AnyCancellable>()

    /// Tracks which sessions we've already sent notifications for (to avoid duplicates).
    private var notifiedStates: [String: Int] = [:]

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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
        UNUserNotificationCenter.current().add(request)
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
            return "❓ \(name) — question (\(formatDuration(Date().timeIntervalSince(since))))"
        case .waitingIdle(let since):
            return "⏳ \(name) — idle (\(formatDuration(Date().timeIntervalSince(since))))"
        case .inactive(let lastActivity):
            return "⏸ \(name) — inactive (\(formatDuration(Date().timeIntervalSince(lastActivity))) ago)"
        }
    }

    // MARK: - Actions

    @objc private func handleSessionClick(_ sender: NSMenuItem) {
        guard let sessionID = sender.representedObject as? String,
              let session = monitor.sessions.first(where: { $0.id == sessionID }) else { return }
        TerminalLauncher.open(at: session.projectPath)
    }

    @objc private func handleOpenTerminal(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        TerminalLauncher.open(at: path)
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
