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

    nonisolated init(detector: ClaudeSessionDetector = .shared) {
        self.detector = detector
    }

    /// Returns the cached transcript for a session, or nil.
    func transcript(for sessionId: String) -> [TranscriptMessage]? {
        cachedTranscripts[sessionId]
    }

    /// Loads the transcript for a session if needed. Call from view's .onAppear or .task.
    func loadIfNeeded(sessionId: String, jsonlPath: String) async {
        // Check if file has changed since we last loaded.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: jsonlPath),
           let modDate = attrs[.modificationDate] as? Date,
           let lastMod = transcriptModDates[sessionId],
           modDate == lastMod,
           cachedTranscripts[sessionId] != nil {
            Logger.debug("TranscriptLoader: skipping unchanged file for \(sessionId)")
            return
        }

        // Don't restart if already loading.
        if case .loading = loadStates[sessionId] { return }
        if case .parsing = loadStates[sessionId] { return }

        Logger.info("TranscriptLoader: loading \(sessionId)")
        loadStates[sessionId] = .loading(progress: 0.0)

        // Read on a background thread, yielding progress back to main actor.
        let result = await Task.detached(priority: .userInitiated) { [detector] () -> (transcript: [TranscriptMessage], modDate: Date?) in
            var lastEmitTime: CFAbsoluteTime = 0
            let transcript = detector.readTranscript(jsonlPath: jsonlPath) { progress in
                let now = CFAbsoluteTimeGetCurrent()
                if lastEmitTime == 0 || now - lastEmitTime >= 0.15 || progress >= 1.0 {
                    lastEmitTime = now
                    // Fire-and-forget to main actor; we don't block the reader.
                    Task { @MainActor [weak self = self] in
                        self?.loadStates[sessionId] = .loading(progress: progress)
                    }
                }
            }
            let modDate = (try? FileManager.default.attributesOfItem(atPath: jsonlPath))?[.modificationDate] as? Date
            return (transcript, modDate)
        }.value

        Logger.info("TranscriptLoader: parsed \(result.transcript.count) messages for \(sessionId)")
        loadStates[sessionId] = .parsing

        // Yield to let SwiftUI render the parsing state.
        await Task.yield()

        cachedTranscripts[sessionId] = result.transcript
        if let modDate = result.modDate {
            transcriptModDates[sessionId] = modDate
        }
        loadStates.removeValue(forKey: sessionId)
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
