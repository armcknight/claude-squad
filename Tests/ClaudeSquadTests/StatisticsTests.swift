import XCTest
@testable import ClaudeSquad

final class StatisticsTests: XCTestCase {

    private var tempDir: String!
    private var calendar: Calendar!

    override func setUpWithError() throws {
        tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("StatisticsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: tempDir)
    }

    // MARK: - SessionActivityRecord

    func test_record_splitsSegmentsAtIdleThreshold() throws {
        let base = date("2026-10-01T10:00:00Z")
        let timestamps = [0, 60, 120, 120 + 3600, 120 + 3600 + 60].map { base.addingTimeInterval(TimeInterval($0)) }
        let record = try XCTUnwrap(SessionActivityRecord(
            sessionId: "s", projectPath: "/tmp/p", isSubagent: false,
            timestamps: timestamps.shuffled(), tokenUsage: .zero
        ))

        XCTAssertEqual(record.segments.count, 2)
        XCTAssertEqual(record.activeDuration, 180)
        XCTAssertEqual(record.longestIdleGap, 3600)
        XCTAssertEqual(record.start, base)
        XCTAssertEqual(record.projectName, "p")
    }

    func test_record_nilWithoutTimestamps() {
        XCTAssertNil(SessionActivityRecord(sessionId: "s", projectPath: nil, isSubagent: false, timestamps: [], tokenUsage: .zero))
    }

    // MARK: - SessionActivityParser

    func test_parser_readsTimestampsMetadataAndDedupedUsage() throws {
        let path = try writeJSONL(name: "abc.jsonl", lines: [
            #"{"type":"user","timestamp":"2026-10-01T10:00:00.000Z","cwd":"/Users/dev/proj","sessionId":"abc","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"assistant","timestamp":"2026-10-01T10:01:00.000Z","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":30,"cache_read_input_tokens":40}}}"#,
            #"{"type":"assistant","timestamp":"2026-10-01T10:01:01Z","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":30,"cache_read_input_tokens":40}}}"#,
            #"{"type":"assistant","timestamp":"2026-10-01T10:02:00.000Z","message":{"id":"m2","usage":{"input_tokens":1,"output_tokens":2}}}"#,
            "not json",
            #"{"type":"user","timestamp":"2026-10-01T10:03:00.000Z""#,
        ])

        let record = try XCTUnwrap(SessionActivityParser().parse(jsonlPath: path, isSubagent: false))

        XCTAssertEqual(record.sessionId, "abc")
        XCTAssertEqual(record.projectPath, "/Users/dev/proj")
        XCTAssertEqual(record.start, date("2026-10-01T10:00:00Z"))
        XCTAssertEqual(record.end, date("2026-10-01T10:02:00Z"))
        XCTAssertEqual(record.tokenUsage, TokenUsage(input: 11, output: 22, cacheCreation: 30, cacheRead: 40))
    }

    func test_parser_throwsForMissingFile() {
        let path = (tempDir as NSString).appendingPathComponent("missing.jsonl")
        XCTAssertThrowsError(try SessionActivityParser().parse(jsonlPath: path, isSubagent: false))
    }

    func test_parser_returnsNilWithoutTimestamps() throws {
        let path = try writeJSONL(name: "empty.jsonl", lines: [#"{"type":"user"}"#])
        XCTAssertNil(try SessionActivityParser().parse(jsonlPath: path, isSubagent: false))
    }

    // MARK: - StatisticsCalculator

    func test_calculate_emptyRecords() {
        let stats = StatisticsCalculator.calculate(records: [], now: Date(), calendar: calendar)
        XCTAssertEqual(stats.totalSessions, 0)
        XCTAssertNil(stats.longestSession)
        XCTAssertNil(stats.longestIdleGap)
        XCTAssertNil(stats.peakConcurrency)
        XCTAssertEqual(stats.averageSessionsPerActiveDay, 0)
        XCTAssertEqual(stats.longestDailyStreak, 0)
        XCTAssertTrue(stats.badges.allSatisfy { !$0.isEarned })
    }

    func test_calculate_highlightsAndTokens() {
        let short = record(id: "short", start: "2026-10-01T10:00:00Z", offsets: [0, 60], tokens: TokenUsage(input: 1))
        let long = record(id: "long", project: "/p/long", start: "2026-10-01T11:00:00Z", offsets: [0, 300, 600], tokens: TokenUsage(output: 2))
        let idle = record(id: "idle", project: "/p/idle", start: "2026-10-02T09:00:00Z", offsets: [0, 7200], tokens: TokenUsage(cacheRead: 3))
        let sub = record(id: "sub", start: "2026-10-01T10:00:00Z", offsets: [0, 9000], tokens: TokenUsage(cacheCreation: 4), isSubagent: true)

        let stats = StatisticsCalculator.calculate(records: [short, long, idle, sub], now: date("2026-10-02T12:00:00Z"), calendar: calendar)

        XCTAssertEqual(stats.totalSessions, 3)
        XCTAssertEqual(stats.longestSession?.sessionId, "long")
        XCTAssertEqual(stats.longestSession?.projectName, "long")
        XCTAssertEqual(stats.longestSession?.duration, 600)
        XCTAssertEqual(stats.longestIdleGap?.sessionId, "idle")
        XCTAssertEqual(stats.longestIdleGap?.duration, 7200)
        XCTAssertEqual(stats.tokenUsage, TokenUsage(input: 1, output: 2, cacheCreation: 4, cacheRead: 3))
    }

    func test_calculate_frequency() {
        let records = [
            record(id: "a", start: "2026-09-20T10:00:00Z", offsets: [0]),
            record(id: "b", start: "2026-10-04T10:00:00Z", offsets: [0]),
            record(id: "c", start: "2026-10-09T08:00:00Z", offsets: [0]),
            record(id: "d", start: "2026-10-09T09:00:00Z", offsets: [0]),
        ]

        let stats = StatisticsCalculator.calculate(records: records, now: date("2026-10-09T12:00:00Z"), calendar: calendar)

        XCTAssertEqual(stats.sessionsStartedToday, 2)
        XCTAssertEqual(stats.sessionsStartedLast7Days, 3)
        XCTAssertEqual(stats.averageSessionsPerActiveDay, 4.0 / 3.0, accuracy: 0.0001)
    }

    func test_peakConcurrency_countsOverlapsOnly() throws {
        let base = date("2026-10-01T10:00:00Z")
        let segments = [
            DateInterval(start: base, duration: 100),
            DateInterval(start: base.addingTimeInterval(50), duration: 100),
            DateInterval(start: base.addingTimeInterval(60), duration: 10),
            // Starts exactly when the first ends: not overlapping it.
            DateInterval(start: base.addingTimeInterval(100), duration: 100),
            // Zero length: ignored.
            DateInterval(start: base.addingTimeInterval(65), duration: 0),
        ]

        let peak = try XCTUnwrap(StatisticsCalculator.peakConcurrency(segments: segments))

        XCTAssertEqual(peak.count, 3)
        XCTAssertEqual(peak.date, base.addingTimeInterval(60))
    }

    func test_peakConcurrency_nilForNoSegments() {
        XCTAssertNil(StatisticsCalculator.peakConcurrency(segments: []))
    }

    func test_longestStreak() {
        let days: Set<Date> = Set(["2026-10-01", "2026-10-02", "2026-10-03", "2026-10-05", "2026-10-06"].map { date("\($0)T00:00:00Z") })
        XCTAssertEqual(StatisticsCalculator.longestStreak(days: days, calendar: calendar), 3)
        XCTAssertEqual(StatisticsCalculator.longestStreak(days: [], calendar: calendar), 0)
    }

    // MARK: - Badges

    func test_badges_earnedAtThresholds() {
        let badges = BadgeCatalog.evaluate(
            totalSessions: 10,
            longestSessionDuration: 4 * 3600,
            peakConcurrency: 4,
            longestDailyStreak: 6,
            totalTokens: 1_000_000
        )
        let earned = Set(badges.filter(\.isEarned).map(\.id))

        XCTAssertEqual(earned, ["first-session", "ten-sessions", "marathon", "multitasker", "million-tokens"])
        let squadLeader = badges.first { $0.id == "squad-leader" }
        XCTAssertEqual(squadLeader?.progress ?? 0, 0.8, accuracy: 0.0001)
    }

    func test_badge_progressIsClamped() {
        let badge = Badge(id: "x", title: "", detail: "", iconName: "", currentValue: 50, threshold: 10)
        XCTAssertEqual(badge.progress, 1)
    }

    // MARK: - StatisticsStore scanning

    func test_scan_findsSessionsAndSubagentsAndReusesCache() throws {
        let projectDir = (tempDir as NSString).appendingPathComponent("-Users-dev-proj")
        let subagentDir = (projectDir as NSString).appendingPathComponent("abc/subagents")
        try FileManager.default.createDirectory(atPath: subagentDir, withIntermediateDirectories: true)
        let sessionPath = (projectDir as NSString).appendingPathComponent("abc.jsonl")
        let subagentPath = (subagentDir as NSString).appendingPathComponent("agent-1.jsonl")
        try #"{"type":"user","timestamp":"2026-10-01T10:00:00Z","sessionId":"abc"}"#
            .write(toFile: sessionPath, atomically: true, encoding: .utf8)
        try #"{"type":"assistant","timestamp":"2026-10-01T10:00:30Z","message":{"id":"m","usage":{"output_tokens":5}}}"#
            .write(toFile: subagentPath, atomically: true, encoding: .utf8)

        let first = StatisticsStore.scan(projectsDir: tempDir, previousCache: [:])

        XCTAssertTrue(first.failures.isEmpty)
        XCTAssertEqual(first.cache.count, 2)
        let resolvedSubagentPath = try XCTUnwrap(first.cache.keys.first { $0.hasSuffix("agent-1.jsonl") })
        XCTAssertEqual(first.cache[resolvedSubagentPath]?.record?.isSubagent, true)

        // A cached entry with a matching mod date is reused rather than re-parsed.
        let resolvedSessionPath = try XCTUnwrap(first.cache.keys.first { $0.hasSuffix("abc.jsonl") })
        var seeded = first.cache
        let sentinel = record(id: "sentinel", start: "2026-01-01T00:00:00Z", offsets: [0])
        seeded[resolvedSessionPath] = StatisticsStore.CachedRecord(modDate: try XCTUnwrap(first.cache[resolvedSessionPath]?.modDate), record: sentinel)

        let second = StatisticsStore.scan(projectsDir: tempDir, previousCache: seeded)

        XCTAssertEqual(second.cache[resolvedSessionPath]?.record?.sessionId, "sentinel")
    }
}

// MARK: - Helpers

private extension StatisticsTests {
    func date(_ iso: String) -> Date {
        guard let date = ISO8601DateFormatter().date(from: iso) else {
            XCTFail("Invalid date \(iso)")
            return Date()
        }
        return date
    }

    func record(
        id: String,
        project: String? = nil,
        start: String,
        offsets: [TimeInterval],
        tokens: TokenUsage = .zero,
        isSubagent: Bool = false
    ) -> SessionActivityRecord {
        let base = date(start)
        guard let record = SessionActivityRecord(
            sessionId: id,
            projectPath: project,
            isSubagent: isSubagent,
            timestamps: offsets.map { base.addingTimeInterval($0) },
            tokenUsage: tokens
        ) else {
            XCTFail("Could not build record")
            return SessionActivityRecord(sessionId: id, projectPath: nil, isSubagent: isSubagent, start: base, end: base, segments: [], longestIdleGap: 0, tokenUsage: tokens)
        }
        return record
    }

    func writeJSONL(name: String, lines: [String]) throws -> String {
        let path = (tempDir as NSString).appendingPathComponent(name)
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }
}
