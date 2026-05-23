import Foundation
import Combine

/// Periodically refreshes the list of Claude sessions and publishes updates.
final class SessionMonitor: ObservableObject {

    /// The sorted list of currently-detected Claude sessions.
    @Published private(set) var sessions: [ClaudeSession] = []

    /// Set to the most recent error string if a refresh cycle fails.
    @Published private(set) var lastError: String?

    /// Shared transcript loader — observed by detail views for progress.
    let transcriptLoader: TranscriptLoader

    private let detector: ClaudeSessionDetector
    private var refreshInterval: TimeInterval
    private var timer: Timer?
    weak var logger: Logger?
    weak var analytics: AnalyticsProvider?

    /// Serial queue for refresh work to prevent concurrent access to mutable state.
    private let refreshQueue = DispatchQueue(label: "com.claudesquad.refresh", qos: .utility)

    /// Tracks when each session (by id) first transitioned to a waiting state
    /// so that the `since` date persists across refresh cycles.
    private var waitingSince: [String: Date] = [:]

    /// Tracks the last-known status type per session for transition detection.
    private var previousStatusType: [String: Int] = [:]

    /// Callback fired when a session transitions to a state needing attention.
    var onNeedsAttention: ((_ session: ClaudeSession) -> Void)?

    init(detector: ClaudeSessionDetector, refreshInterval: TimeInterval) {
        self.detector = detector
        self.refreshInterval = refreshInterval
        self.transcriptLoader = TranscriptLoader(detector: detector)
    }

    #if DEBUG
    /// Creates a monitor that reads from bundled fixture data instead of ~/.claude.
    /// Files whose names contain "running" session IDs are touched each cycle
    /// so the detector sees them as fresh (status = running instead of interrupted).
    static func mock(logger: Logger) -> SessionMonitor {
        let detector = ClaudeSessionDetector()
        detector.logger = logger
        guard let mockBase = Bundle.main.path(forResource: "MockData", ofType: nil, inDirectory: "Fixtures") else {
            logger.warning("MockData not found in bundle")
            let monitor = SessionMonitor(detector: detector, refreshInterval: 3)
            monitor.logger = logger
            return monitor
        }
        detector.basePath = mockBase

        let runningSessionIds = ["dddd4444", "eeee5555"]
        // Subagent agentIds (substring of `agent-<agentId>.jsonl`) whose JSONLs
        // should be touched each cycle so they render as running instead of
        // sliding into "interrupted" via staleness.
        let runningSubagentIds = ["aaa111aaa111aaa11", "ccc333ccc333ccc33"]
        let projectsDir = (mockBase as NSString).appendingPathComponent("projects")
        if let dirs = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) {
            for dir in dirs {
                let fullDir = (projectsDir as NSString).appendingPathComponent(dir)
                if let files = try? FileManager.default.contentsOfDirectory(atPath: fullDir) {
                    for file in files where file.hasSuffix(".jsonl") {
                        if runningSessionIds.contains(where: { file.hasPrefix($0) }) {
                            let path = (fullDir as NSString).appendingPathComponent(file)
                            detector.runningFixturePaths.append(path)
                        }
                    }
                }
            }
            // Walk subagent directories recursively, touching any `agent-<id>.jsonl`
            // whose id matches a running subagent.
            collectRunningSubagentPaths(in: projectsDir, ids: runningSubagentIds, into: &detector.runningFixturePaths)
        }
        let monitor = SessionMonitor(detector: detector, refreshInterval: 3)
        monitor.logger = logger
        DispatchQueue.main.async {
            monitor.transcriptLoader.logger = logger
        }
        return monitor
    }
    #endif

    #if DEBUG
    /// Recursively walks `dir`, collecting paths of any `agent-<id>.jsonl` whose
    /// filename matches one of `ids`. Used by mock mode so running subagents stay
    /// fresh and don't slide into "interrupted" via staleness.
    private static func collectRunningSubagentPaths(in dir: String, ids: [String], into paths: inout [String]) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for entry in entries {
            let path = (dir as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                collectRunningSubagentPaths(in: path, ids: ids, into: &paths)
            } else if entry.hasPrefix("agent-"), entry.hasSuffix(".jsonl"),
                      ids.contains(where: { entry.contains($0) }) {
                paths.append(path)
            }
        }
    }
    #endif

    // MARK: - Lifecycle

    func start() {
        logger?.info("SessionMonitor starting with \(refreshInterval)s interval")
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        logger?.info("SessionMonitor stopping")
        timer?.invalidate()
        timer = nil
    }

    func updateRefreshInterval(_ interval: TimeInterval) {
        logger?.info("SessionMonitor updating interval to \(interval)s")
        analytics?.track(event: AnalyticsEvent.pollIntervalChanged.rawValue, properties: ["interval": interval])
        stop()
        refreshInterval = interval
        start()
    }

    // MARK: - Refresh

    func refresh() {
        logger?.info("SessionMonitor.refresh() called, dispatching to background")
        refreshQueue.async { [weak self] in
            guard let self else { return }
            self.logger?.info("SessionMonitor.refresh(): background block executing")
            do {
                let detected = try self.detector.detectSessions()
                logger?.info("Detector returned \(detected.count) session(s)")
                let stabilized = self.stabilizeTimestamps(detected)
                let sorted = stabilized.sorted()
                DispatchQueue.main.async {
                    let oldCount = self.sessions.count
                    self.checkTransitions(newSessions: sorted)
                    // Re-apply cached transcripts to the new session objects.
                    var withTranscripts = sorted
                    self.transcriptLoader.applyCachedTranscripts(to: &withTranscripts)
                    self.sessions = withTranscripts
                    self.lastError = nil
                    if withTranscripts.count != oldCount {
                        self.logger?.info("Session count changed: \(oldCount) -> \(withTranscripts.count)")
                    }
                }
            } catch {
                logger?.error("Session detection failed: \(error)")
                logger?.error("Session detection error details: \(String(describing: error))")
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
            case .waitingIdle(let detectedSince):
                let since = waitingSince[session.id] ?? detectedSince
                waitingSince[session.id] = since
                session.status = .waitingIdle(since: since)
            case .waitingForQuestion(let detectedSince, let question):
                let since = waitingSince[session.id] ?? detectedSince
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
                logger?.info("Session \(session.displayName) transitioned to waiting (priority \(currentType))")
                onNeedsAttention?(session)
            }

            previousStatusType[session.id] = currentType
        }

        // Clean up entries for sessions no longer detected.
        let currentIDs = Set(newSessions.map(\.id))
        previousStatusType = previousStatusType.filter { currentIDs.contains($0.key) }
    }
}
