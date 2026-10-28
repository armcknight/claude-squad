import Foundation

/// Loads and caches session transcripts with observable progress. Keyed by an
/// opaque transcript id (`session.transcriptKey` / `subagent.transcriptKey`) so
/// that subagents — which share their parent's session id — don't collide.
@MainActor
final class TranscriptLoader: ObservableObject {

    enum LoadState: Equatable {
        case idle
        case loading(progress: Double)
        case parsing
    }

    /// Per-transcript load state. Views observe this for progress display.
    @Published private(set) var loadStates: [String: LoadState] = [:]

    /// Cached transcripts by transcript key.
    private(set) var cachedTranscripts: [String: [TranscriptMessage]] = [:]

    /// File mod dates for cache invalidation, by transcript key.
    private var transcriptModDates: [String: Date] = [:]

    private let detector: ClaudeSessionDetector
    weak var logger: Logger?

    nonisolated init(detector: ClaudeSessionDetector) {
        self.detector = detector
    }

    /// Returns the cached transcript for a transcript key, or nil.
    func transcript(forKey key: String) -> [TranscriptMessage]? {
        cachedTranscripts[key]
    }

    /// Loads the transcript for a given JSONL if needed. Safe to call repeatedly;
    /// guards against duplicate loads internally. Not async — fires a detached
    /// task so loading is not cancelled when SwiftUI recreates the view.
    func loadIfNeeded(transcriptKey key: String, jsonlPath: String) {
        // Don't restart if already loading.
        if case .loading = loadStates[key] { return }

        // Check if file has changed since we last loaded.
        if let modDate = Self.modificationDate(ofItemAtPath: jsonlPath, logger: logger),
           let lastMod = transcriptModDates[key],
           modDate == lastMod,
           cachedTranscripts[key] != nil {
            logger?.debug("TranscriptLoader: skipping unchanged file for \(key)")
            return
        }

        logger?.info("TranscriptLoader: loading \(key)")
        loadStates[key] = .loading(progress: 0.0)

        // Fire-and-forget detached task so it survives view recreation.
        Task.detached(priority: .userInitiated) { [weak self, detector, weak logger = self.logger] in
            var lastEmitTime: CFAbsoluteTime = 0
            let transcript = detector.readTranscript(jsonlPath: jsonlPath) { progress in
                let now = CFAbsoluteTimeGetCurrent()
                if lastEmitTime == 0 || now - lastEmitTime >= 0.15 || progress >= 1.0 {
                    lastEmitTime = now
                    Task { @MainActor [weak self] in
                        self?.loadStates[key] = .loading(progress: progress)
                    }
                }
            }
            let modDate = TranscriptLoader.modificationDate(ofItemAtPath: jsonlPath, logger: logger)

            await MainActor.run {
                guard let self else { return }
                self.logger?.info("TranscriptLoader: parsed \(transcript.count) messages for \(key)")
                self.cachedTranscripts[key] = transcript
                if let modDate {
                    self.transcriptModDates[key] = modDate
                }
                self.loadStates.removeValue(forKey: key)
            }
        }
    }

    /// Re-applies cached transcripts to a session array (called after refresh).
    /// Walks subagent trees as well so nested transcripts are kept in sync.
    func applyCachedTranscripts(to sessions: inout [ClaudeSession]) {
        for i in sessions.indices {
            if let cached = cachedTranscripts[sessions[i].transcriptKey] {
                sessions[i].transcript = cached
            }
            sessions[i].subagents = applyToSubagents(sessions[i].subagents)
        }
    }

    private func applyToSubagents(_ subs: [Subagent]) -> [Subagent] {
        var result = subs
        for i in result.indices {
            if let cached = cachedTranscripts[result[i].transcriptKey] {
                result[i].transcript = cached
            }
            result[i].subagents = applyToSubagents(result[i].subagents)
        }
        return result
    }
}

private extension TranscriptLoader {
    /// Returns the modification date of a transcript file, or nil if its attributes
    /// can't be read (e.g. the file was removed between polls).
    nonisolated static func modificationDate(ofItemAtPath path: String, logger: Logger?) -> Date? {
        do {
            return try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        } catch {
            logger?.debug("TranscriptLoader: cannot read attributes of \(path): \(error.localizedDescription)")
            return nil
        }
    }
}
