import Foundation

/// Abstract error reporting interface. Swap implementations to change providers.
protocol ErrorReporter: AnyObject {
    func configure()
    func capture(error: Error, context: [String: Any]?)
    func capture(message: String, level: ErrorReportingLevel, context: [String: Any]?)
    func setUser(id: String?, email: String?)
}

enum ErrorReportingLevel {
    case debug, info, warning, error, fatal
}

extension ErrorReporter {
    func capture(error: Error) {
        capture(error: error, context: nil)
    }

    func capture(message: String, level: ErrorReportingLevel) {
        capture(message: message, level: level, context: nil)
    }
}

// MARK: - Sentry implementation

import Sentry

final class SentryErrorReporter: ErrorReporter {
    private let dsn: String

    init(dsn: String) {
        self.dsn = dsn
    }

    func configure() {
        SentrySDK.start { options in
            options.dsn = self.dsn
            options.tracesSampleRate = 0.2
            options.enableMetricKit = true
            options.enableAppHangTracking = false
            #if DEBUG
            options.debug = true
            options.environment = "debug"
            #else
            options.environment = "release"
            #endif
            options.enableAppHangTracking = false
        }

        let info = Bundle.main.infoDictionary

        SentrySDK.configureScope { scope in
            if let gitCommit = info?["GIT_COMMIT_HASH"] as? String, !gitCommit.isEmpty {
                scope.setTag(value: gitCommit, key: "git.commit")
            }
            if let gitBranch = info?["GIT_BRANCH"] as? String, !gitBranch.isEmpty {
                scope.setTag(value: gitBranch, key: "git.branch")
            }
            if let gitStatusClean = info?["GIT_STATUS_CLEAN"] as? String, !gitStatusClean.isEmpty {
                scope.setTag(value: gitStatusClean, key: "git.clean")
            }
            if let appVersion = info?["CFBundleShortVersionString"] as? String {
                scope.setTag(value: appVersion, key: "app.version")
            }
        }
    }

    func capture(error: Error, context: [String: Any]?) {
        let event = Sentry.Event(error: error)
        if let context {
            event.extra = context
        }
        SentrySDK.capture(event: event)
    }

    func capture(message: String, level: ErrorReportingLevel, context: [String: Any]?) {
        let event = Sentry.Event(level: level.sentryLevel)
        event.message = SentryMessage(formatted: message)
        if let context {
            event.extra = context
        }
        SentrySDK.capture(event: event)
    }

    func setUser(id: String?, email: String?) {
        if let id {
            let user = Sentry.User()
            user.userId = id
            user.email = email
            SentrySDK.setUser(user)
        } else {
            SentrySDK.setUser(nil)
        }
    }
}

private extension ErrorReportingLevel {
    var sentryLevel: SentryLevel {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .warning
        case .error: return .error
        case .fatal: return .fatal
        }
    }
}

// MARK: - No-op implementation

final class NoOpErrorReporter: ErrorReporter {
    func configure() {}
    func capture(error: Error, context: [String: Any]?) {}
    func capture(message: String, level: ErrorReportingLevel, context: [String: Any]?) {}
    func setUser(id: String?, email: String?) {}
}
