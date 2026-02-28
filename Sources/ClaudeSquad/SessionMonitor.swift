import Foundation
import Combine

/// Periodically refreshes the list of Claude sessions and publishes updates.
final class SessionMonitor: ObservableObject {

    /// The sorted list of currently-detected Claude sessions.
    @Published private(set) var sessions: [ClaudeSession] = []

    /// Set to the most recent error string if a refresh cycle fails.
    @Published private(set) var lastError: String?

    private let detector: ClaudeSessionDetector
    private let refreshInterval: TimeInterval
    private var timer: Timer?

    /// Tracks when each session (by id) first transitioned to a waiting state
    /// so that the `since` date persists across refresh cycles.
    private var waitingSince: [String: Date] = [:]

    /// Tracks the last-known status type per session for transition detection.
    private var previousStatusType: [String: Int] = [:]

    /// Callback fired when a session transitions to a state needing attention.
    var onNeedsAttention: ((_ session: ClaudeSession) -> Void)?

    init(detector: ClaudeSessionDetector = .shared, refreshInterval: TimeInterval = 3) {
        self.detector = detector
        self.refreshInterval = refreshInterval
    }

    // MARK: - Lifecycle

    func start() {
        Logger.info("SessionMonitor starting with \(refreshInterval)s interval")
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        Logger.info("SessionMonitor stopping")
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Refresh

    func refresh() {
        Logger.info("SessionMonitor.refresh() called, dispatching to background")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else {
                Logger.warning("SessionMonitor.refresh(): self was deallocated")
                return
            }
            Logger.info("SessionMonitor.refresh(): background block executing")
            do {
                let detected = try self.detector.detectSessions()
                Logger.info("Detector returned \(detected.count) session(s)")
                let stabilized = self.stabilizeTimestamps(detected)
                let sorted = stabilized.sorted()
                DispatchQueue.main.async {
                    let oldCount = self.sessions.count
                    self.checkTransitions(newSessions: sorted)
                    self.sessions = sorted
                    self.lastError = nil
                    if sorted.count != oldCount {
                        Logger.info("Session count changed: \(oldCount) -> \(sorted.count)")
                    }
                }
            } catch {
                Logger.error("Session detection failed: \(error)")
                Logger.error("Session detection error details: \(String(describing: error))")
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Timestamp stabilization

    /// Preserves the original "started waiting" timestamps across poll cycles
    /// so that wait durations grow monotonically rather than resetting each cycle.
    private func stabilizeTimestamps(_ sessions: [ClaudeSession]) -> [ClaudeSession] {
        let now = Date()
        var result: [ClaudeSession] = []
        let currentIDs = Set(sessions.map(\.id))

        // Remove stale entries.
        waitingSince = waitingSince.filter { currentIDs.contains($0.key) }

        for var session in sessions {
            switch session.status {
            case .waitingIdle:
                let since = waitingSince[session.id] ?? now
                waitingSince[session.id] = since
                session.status = .waitingIdle(since: since)
            case .waitingForQuestion(_, let question):
                let since = waitingSince[session.id] ?? now
                waitingSince[session.id] = since
                session.status = .waitingForQuestion(since: since, question: question)
            default:
                waitingSince.removeValue(forKey: session.id)
            }
            result.append(session)
        }
        return result
    }

    // MARK: - Transition detection

    /// Fires `onNeedsAttention` when a session newly transitions to a waiting state.
    private func checkTransitions(newSessions: [ClaudeSession]) {
        for session in newSessions {
            let currentType = session.status.sortPriority
            let previousType = previousStatusType[session.id]

            // Notify if transitioned TO a waiting state from something else.
            if session.status.isWaiting && previousType != currentType {
                Logger.info("Session \(session.displayName) transitioned to waiting (priority \(currentType))")
                onNeedsAttention?(session)
            }

            previousStatusType[session.id] = currentType
        }

        // Clean up entries for sessions no longer detected.
        let currentIDs = Set(newSessions.map(\.id))
        previousStatusType = previousStatusType.filter { currentIDs.contains($0.key) }
    }
}
