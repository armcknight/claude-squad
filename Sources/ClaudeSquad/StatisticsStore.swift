import Foundation

/// Scans every session and subagent JSONL under `<claudeDir>/projects/` and
/// publishes aggregate `SessionStatistics`. Parsed files are cached by
/// modification date so that later refreshes only re-read changed files.
@MainActor
final class StatisticsStore: ObservableObject {

    /// Latest computed statistics, or nil before the first load completes.
    @Published private(set) var statistics: SessionStatistics?

    /// True while a background scan is in progress.
    @Published private(set) var isLoading = false

    /// Cached parse result for one JSONL file. `record` is nil when the file
    /// had no timestamped entries.
    struct CachedRecord {
        let modDate: Date
        let record: SessionActivityRecord?
    }

    private let claudeBasePath: String
    private var cache: [String: CachedRecord] = [:]
    weak var logger: Logger?
    weak var errorReporter: ErrorReporter?

    nonisolated init(claudeBasePath: String) {
        self.claudeBasePath = claudeBasePath
    }

    /// Starts a background scan unless one is already running.
    func refresh() {
        guard !isLoading else { return }
        isLoading = true

        let projectsDir = (claudeBasePath as NSString).appendingPathComponent("projects")
        let previousCache = cache
        logger?.info("StatisticsStore: scanning \(projectsDir)")

        Task.detached(priority: .utility) { [weak self] in
            let result = StatisticsStore.scan(projectsDir: projectsDir, previousCache: previousCache)
            let statistics = StatisticsCalculator.calculate(
                records: result.cache.values.compactMap(\.record),
                now: Date(),
                calendar: .current
            )
            await self?.finishRefresh(result: result, statistics: statistics)
        }
    }
}

extension StatisticsStore {
    struct ScanResult {
        let cache: [String: CachedRecord]
        let failures: [(path: String, error: Error)]
    }

    /// Finds all JSONL files under `projectsDir` and parses any that changed
    /// since `previousCache`. Files that no longer exist are dropped.
    nonisolated static func scan(projectsDir: String, previousCache: [String: CachedRecord]) -> ScanResult {
        let parser = SessionActivityParser()
        var cache: [String: CachedRecord] = [:]
        var failures: [(path: String, error: Error)] = []

        for file in findJSONLFiles(in: projectsDir) {
            if let cached = previousCache[file.path], cached.modDate == file.modDate {
                cache[file.path] = cached
                continue
            }
            do {
                let isSubagent = file.path.contains("/subagents/")
                let record = try parser.parse(jsonlPath: file.path, isSubagent: isSubagent)
                cache[file.path] = CachedRecord(modDate: file.modDate, record: record)
            } catch {
                failures.append((file.path, error))
            }
        }
        return ScanResult(cache: cache, failures: failures)
    }

    /// Recursively lists `.jsonl` files with their modification dates.
    nonisolated static func findJSONLFiles(in directory: String) -> [(path: String, modDate: Date)] {
        let url = URL(fileURLWithPath: directory)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
            return []
        }
        var results: [(path: String, modDate: Date)] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            do {
                let values = try fileURL.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true, let modDate = values.contentModificationDate else { continue }
                results.append((fileURL.path, modDate))
            } catch {
                // The file may have been removed between enumeration and the
                // attribute read; skip it.
                continue
            }
        }
        return results
    }
}

private extension StatisticsStore {
    func finishRefresh(result: ScanResult, statistics: SessionStatistics) {
        cache = result.cache
        self.statistics = statistics
        isLoading = false
        handle(failures: result.failures, fileCount: result.cache.count)
    }

    func handle(failures: [(path: String, error: Error)], fileCount: Int) {
        logger?.info("StatisticsStore: \(fileCount) file(s) cached, \(failures.count) failure(s)")
        guard let first = failures.first else { return }
        for failure in failures {
            logger?.warning("StatisticsStore: failed to parse \(failure.path): \(failure.error.localizedDescription)")
        }
        guard let errorReporter else {
            logger?.warning("StatisticsStore: errorReporter is nil, cannot report parse failures")
            return
        }
        errorReporter.capture(error: first.error, context: ["failure_count": failures.count])
    }
}
