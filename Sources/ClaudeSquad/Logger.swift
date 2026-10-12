import Foundation
import SwiftyBeaver

final class Logger {
    /// Maximum size of a single log file before it is rotated.
    static let logFileMaxSize = 1 * 1024 * 1024 // 1 MB
    /// Number of log files kept on disk (the active file plus rotated ones).
    static let logFileAmount = 2

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
        let dest = FileDestination()
        dest.format = "$DHH:mm:ss.SSS$d $C$L$c $N.$F:$l - $M"
        dest.minLevel = minLevel
        // SwiftyBeaver only honors logFileMaxSize when logFileAmount > 1; with the
        // default of 1, rotation is disabled and the file grows without bound.
        dest.logFileMaxSize = Self.logFileMaxSize
        dest.logFileAmount = Self.logFileAmount

        guard let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            print("Logger: could not locate caches directory; file logging disabled")
            dest.logFileURL = nil
            return dest
        }
        let bundleId = Bundle.main.bundleIdentifier ?? "io.mcknight.ClaudeSquad"
        let logDirectory = cachesDir.appendingPathComponent(bundleId).appendingPathComponent("Logs", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        } catch {
            print("Logger: could not create log directory \(logDirectory.path): \(error)")
        }

        Self.removeOversizedLogFiles(in: logDirectory, maxFileSize: Self.logFileMaxSize)

        dest.logFileURL = logDirectory.appendingPathComponent("app.log")
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

// MARK: - Log file cleanup

extension Logger {
    /// Deletes any log files in `directory` that exceed `maxFileSize`.
    ///
    /// Rotation only triggers on the next write, and a rotated file is kept as-is,
    /// so files that grew huge before rotation was enabled would otherwise linger.
    static func removeOversizedLogFiles(in directory: URL, maxFileSize: Int, fileManager: FileManager = .default) {
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        } catch {
            print("Logger: could not list log directory \(directory.path): \(error)")
            return
        }

        for url in contents where url.pathExtension == "log" {
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > maxFileSize else { continue }
                try fileManager.removeItem(at: url)
            } catch {
                print("Logger: could not remove oversized log file \(url.path): \(error)")
            }
        }
    }
}
