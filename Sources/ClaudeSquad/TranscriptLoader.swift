import Foundation

/// Loads and caches session transcripts with observable progress.
@MainActor
final class TranscriptLoader: ObservableObject {

    enum LoadState: Equatable {
        case idle
        case loading(progress: Double)
        case parsing
    }

    /// Per-session load state. Views observe this for progress display.
    @Published private(set) var loadStates: [String: LoadState] = [:]

    /// Cached transcripts by session ID.
    private(set) var cachedTranscripts: [String: [TranscriptMessage]] = [:]

    /// File mod dates for cache invalidation.
    private var transcriptModDates: [String: Date] = [:]

    private let detector: ClaudeSessionDetector
    weak var logger: Logger?

    nonisolated init(detector: ClaudeSessionDetector) {
        self.detector = detector
    }

    /// Returns the cached transcript for a session, or nil.
    func transcript(for sessionId: String) -> [TranscriptMessage]? {
        cachedTranscripts[sessionId]
    }

    /// Loads the transcript for a session if needed. Safe to call repeatedly;
    /// guards against duplicate loads internally. Not async — fires a detached
    /// task so loading is not cancelled when SwiftUI recreates the view.
    func loadIfNeeded(sessionId: String, jsonlPath: String) {
        // Don't restart if already loading.
        if case .loading = loadStates[sessionId] { return }

        // Check if file has changed since we last loaded.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: jsonlPath),
           let modDate = attrs[.modificationDate] as? Date,
           let lastMod = transcriptModDates[sessionId],
           modDate == lastMod,
           cachedTranscripts[sessionId] != nil {
            logger?.debug("TranscriptLoader: skipping unchanged file for \(sessionId)")
            return
        }

        logger?.info("TranscriptLoader: loading \(sessionId)")
        loadStates[sessionId] = .loading(progress: 0.0)

        // Fire-and-forget detached task so it survives view recreation.
        Task.detached(priority: .userInitiated) { [weak self, detector] in
            var lastEmitTime: CFAbsoluteTime = 0
            let transcript = detector.readTranscript(jsonlPath: jsonlPath) { progress in
                let now = CFAbsoluteTimeGetCurrent()
                if lastEmitTime == 0 || now - lastEmitTime >= 0.15 || progress >= 1.0 {
                    lastEmitTime = now
                    Task { @MainActor [weak self] in
                        self?.loadStates[sessionId] = .loading(progress: progress)
                    }
                }
            }
            let modDate = (try? FileManager.default.attributesOfItem(atPath: jsonlPath))?[.modificationDate] as? Date

            await MainActor.run {
                guard let self else { return }
                self.logger?.info("TranscriptLoader: parsed \(transcript.count) messages for \(sessionId)")
                self.cachedTranscripts[sessionId] = transcript
                if let modDate {
                    self.transcriptModDates[sessionId] = modDate
                }
                self.loadStates.removeValue(forKey: sessionId)
            }
        }
    }

    /// Re-applies cached transcripts to a session array (called after refresh).
    func applyCachedTranscripts(to sessions: inout [ClaudeSession]) {
        for i in sessions.indices {
            if let cached = cachedTranscripts[sessions[i].id] {
                sessions[i].transcript = cached
            }
        }
    }
}
