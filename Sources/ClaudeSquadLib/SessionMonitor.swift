import Foundation
import Combine

/// Periodically refreshes the list of Claude sessions and publishes updates.
final class SessionMonitor: ObservableObject {

    /// The sorted list of currently-detected Claude sessions.
    @Published private(set) var sessions: [ClaudeSession] = []

    /// Set to the most recent error string if a refresh cycle fails.
    @Published private(set) var lastError: String?

    private let tmux: TmuxManager
    private let refreshInterval: TimeInterval
    private var timer: Timer?

    /// Tracks when each session (by id) first transitioned to `.waitingForInput`
    /// so that the `since` date persists across refresh cycles.
    private var waitingSince: [String: Date] = [:]

    init(tmux: TmuxManager = .shared, refreshInterval: TimeInterval = 3) {
        self.tmux = tmux
        self.refreshInterval = refreshInterval
    }

    // MARK: - Lifecycle

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Refresh

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                let rawInfos = try self.tmux.probeSessions()
                let sessions = self.buildSessions(from: rawInfos)
                let sorted = sessions.sorted()
                DispatchQueue.main.async {
                    self.sessions = sorted
                    self.lastError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Session construction with timestamp management

    /// Converts raw probe results into `ClaudeSession` values, preserving the
    /// `waitingSince` date so that the elapsed-wait duration grows monotonically.
    private func buildSessions(from rawInfos: [TmuxManager.RawSessionInfo]) -> [ClaudeSession] {
        let now = Date()
        var updated: [ClaudeSession] = []

        let probeIDs = Set(rawInfos.map(\.name))

        // Remove timestamps for sessions that are no longer detected.
        waitingSince = waitingSince.filter { probeIDs.contains($0.key) }

        for info in rawInfos {
            let status: SessionStatus
            if info.isWaiting {
                // Keep the original "started waiting" date if already tracked.
                let since = waitingSince[info.name] ?? now
                waitingSince[info.name] = since
                status = .waitingForInput(since: since)
            } else {
                // Clear tracking when the session transitions back to running.
                waitingSince.removeValue(forKey: info.name)
                status = .running
            }
            updated.append(ClaudeSession(id: info.name, status: status, paneTTY: info.tty))
        }
        return updated
    }
}
