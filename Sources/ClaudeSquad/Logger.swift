import Foundation
import SwiftyBeaver

final class Logger {
    private let log = SwiftyBeaver.self
    private var fileDestination: FileDestination?

    private let defaultLogLevel: SwiftyBeaver.Level = {
        #if DEBUG
        return .debug
        #else
        return .info
        #endif
    }()

    init() {
        resetDestinations(minLevel: defaultLogLevel)
    }

    // MARK: - Destinations

    private func resetDestinations(minLevel: SwiftyBeaver.Level) {
        log.removeAllDestinations()

        let console = ConsoleDestination()
        console.minLevel = minLevel
        log.addDestination(console)

        let file = fileDestination(minLevel: minLevel)
        self.fileDestination = file
        log.addDestination(file)
    }

    private func fileDestination(minLevel: SwiftyBeaver.Level) -> FileDestination {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let bundleId = Bundle.main.bundleIdentifier ?? "com.armcknight.ClaudeSquad"
        let logDirectory = cachesDir.appendingPathComponent(bundleId).appendingPathComponent("Logs", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        } catch {
            // The console destination is already registered, so this still reaches a log.
            log.error("Cannot create log directory at \(logDirectory.path): \(error.localizedDescription)")
        }

        let dest = FileDestination()
        dest.logFileURL = logDirectory.appendingPathComponent("app.log")
        dest.format = "$DHH:mm:ss.SSS$d $C$L$c $N.$F:$l - $M"
        dest.minLevel = minLevel
        dest.logFileMaxSize = 10 * 1024 * 1024 // 10 MB
        return dest
    }

    // MARK: - Logging methods

    func verbose(_ message: @autoclosure () -> Any, file: String = #file, function: String = #function, line: Int = #line) {
        log.verbose(message(), file: file, function: function, line: line)
    }

    func debug(_ message: @autoclosure () -> Any, file: String = #file, function: String = #function, line: Int = #line) {
        log.debug(message(), file: file, function: function, line: line)
    }

    func info(_ message: @autoclosure () -> Any, file: String = #file, function: String = #function, line: Int = #line) {
        log.info(message(), file: file, function: function, line: line)
    }

    func warning(_ message: @autoclosure () -> Any, file: String = #file, function: String = #function, line: Int = #line) {
        log.warning(message(), file: file, function: function, line: line)
    }

    func error(_ message: @autoclosure () -> Any, file: String = #file, function: String = #function, line: Int = #line) {
        log.error(message(), file: file, function: function, line: line)
    }

    // MARK: - Log file access

    func getLogFileURL() -> URL? {
        fileDestination?.logFileURL
    }
}
