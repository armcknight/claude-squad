import Foundation
import Combine

/// Periodically refreshes the list of Claude sessions and publishes updates.
final class SessionMonitor: ObservableObject {

    /// The sorted list of currently-detected Claude sessions.
    @Published private(set) var sessions: [ClaudeSession] = []

    /// Set to the most recent error string if a refresh cycle fails.
    @Published private(set) var lastError: String?

    /// Transcript loading state per session ID. Nil = not loading / already loaded.
    enum TranscriptLoadState {
        case loading(progress: Double) // 0.0–1.0 of file bytes read
        case parsing
    }
    @Published private(set) var transcriptLoadState: [String: TranscriptLoadState] = [:]

    private let detector: ClaudeSessionDetector
    private let refreshInterval: TimeInterval
    private var timer: Timer?

    /// Serial queue for refresh work to prevent concurrent access to mutable state.
    private let refreshQueue = DispatchQueue(label: "com.claudesquad.refresh", qos: .utility)

    /// Tracks when each session (by id) first transitioned to a waiting state
    /// so that the `since` date persists across refresh cycles.
    private var waitingSince: [String: Date] = [:]

    /// Cached transcripts by session ID, preserved across refresh cycles.
    private var cachedTranscripts: [String: [TranscriptMessage]] = [:]

    /// Last modification date of the JSONL file when we loaded its transcript.
    private var transcriptModDates: [String: Date] = [:]

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
        refreshQueue.async { [weak self] in
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
                    // Re-apply cached transcripts to the new session objects.
                    var withTranscripts = sorted
                    for i in withTranscripts.indices {
                        if let cached = self.cachedTranscripts[withTranscripts[i].id] {
                            withTranscripts[i].transcript = cached
                        }
                    }
                    self.sessions = withTranscripts
                    self.lastError = nil
                    if withTranscripts.count != oldCount {
                        Logger.info("Session count changed: \(oldCount) -> \(withTranscripts.count)")
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

    // MARK: - Transcript loading (on demand)

    /// Loads the most recent transcript for a session. Called when the detail view appears.
    func loadTranscript(for sessionId: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }),
              let jsonlPath = sessions[index].jsonlPath else {
            Logger.debug("loadTranscript: no jsonlPath for session \(sessionId)")
            return
        }

        // Check if file has changed since we last loaded this transcript.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: jsonlPath),
           let modDate = attrs[.modificationDate] as? Date,
           let lastMod = transcriptModDates[sessionId],
           modDate == lastMod,
           cachedTranscripts[sessionId] != nil {
            Logger.debug("loadTranscript: skipping unchanged file for \(sessionId)")
            return
        }

        Logger.info("loadTranscript: loading for session \(sessionId) from \(jsonlPath)")
        Logger.info("loadTranscript: setting state to .loading(0.0) for \(sessionId)")
        transcriptLoadState[sessionId] = .loading(progress: 0.0)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // Throttle progress to ~5 updates/sec. Use main.sync so SwiftUI actually
            // processes each update before we continue reading, but only when we
            // actually emit an update (most callbacks are skipped by the throttle).
            var lastProgressTime: CFAbsoluteTime = 0
            var callbackCount = 0
            let transcript = self.detector.readTranscript(jsonlPath: jsonlPath) { progress in
                callbackCount += 1
                let now = CFAbsoluteTimeGetCurrent()
                let elapsed = now - lastProgressTime
                if lastProgressTime == 0 || elapsed >= 0.2 || progress >= 1.0 {
                    Logger.info("loadTranscript: emitting progress \(Int(progress * 100))% (callback #\(callbackCount), elapsed \(String(format: "%.3f", elapsed))s)")
                    lastProgressTime = now
                    DispatchQueue.main.sync {
                        self.transcriptLoadState[sessionId] = .loading(progress: progress)
                    }
                }
            }
            Logger.info("loadTranscript: read \(transcript.count) messages for \(sessionId)")
            let modDate = (try? FileManager.default.attributesOfItem(atPath: jsonlPath))?[.modificationDate] as? Date
            // Set parsing state and wait for SwiftUI to render it.
            DispatchQueue.main.sync {
                self.transcriptLoadState[sessionId] = .parsing
            }
            // Final update: clear state and set transcript.
            DispatchQueue.main.async {
                self.transcriptLoadState.removeValue(forKey: sessionId)
                self.cachedTranscripts[sessionId] = transcript
                if let modDate { self.transcriptModDates[sessionId] = modDate }
                if let idx = self.sessions.firstIndex(where: { $0.id == sessionId }) {
                    var updated = self.sessions
                    updated[idx].transcript = transcript
                    self.sessions = updated
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
