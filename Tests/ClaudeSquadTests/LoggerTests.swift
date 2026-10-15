import XCTest
@testable import ClaudeSquad

final class LoggerTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoggerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func test_rotationIsEnabled() {
        // SwiftyBeaver ignores logFileMaxSize unless logFileAmount > 1.
        XCTAssertGreaterThan(Logger.logFileAmount, 1)
    }

    func test_totalLogSizeIsCappedAtAFewMegabytes() {
        XCTAssertLessThanOrEqual(Logger.logFileMaxSize * Logger.logFileAmount, 5 * 1024 * 1024)
    }

    func test_removeOversizedLogFiles_removesOnlyOversizedLogFiles() throws {
        let big = try makeFile("app.log", size: 2048)
        let bigRotated = try makeFile("app.1.log", size: 4096)
        let small = try makeFile("app.2.log", size: 512)
        let nonLog = try makeFile("other.txt", size: 4096)

        Logger.removeOversizedLogFiles(in: directory, maxFileSize: 1024)

        XCTAssertFalse(FileManager.default.fileExists(atPath: big.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bigRotated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: small.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nonLog.path))
    }

    func test_removeOversizedLogFiles_missingDirectoryDoesNotCrash() {
        let missing = directory.appendingPathComponent("missing", isDirectory: true)
        Logger.removeOversizedLogFiles(in: missing, maxFileSize: 1024)
    }
}

private extension LoggerTests {
    func makeFile(_ name: String, size: Int) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(count: size).write(to: url)
        return url
    }
}
