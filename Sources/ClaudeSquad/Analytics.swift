import Foundation

/// Abstract analytics interface. Swap implementations to change providers.
protocol AnalyticsProvider: AnyObject {
    func configure()
    func track(event: String, properties: [String: Any]?)
    func setUser(id: String?, properties: [String: Any]?)
}

extension AnalyticsProvider {
    func track(event: String) {
        track(event: event, properties: nil)
    }
}

// MARK: - Predefined events

enum AnalyticsEvent: String {
    // App lifecycle
    case appLaunched = "app_launched"
    case appTerminated = "app_terminated"

    // Move to Applications
    case moveToAppsPrompted = "move_to_apps_prompted"
    case moveToAppsAccepted = "move_to_apps_accepted"
    case moveToAppsDismissed = "move_to_apps_dismissed"
    case moveToAppsSuppressed = "move_to_apps_suppressed"

    // Session monitoring
    case sessionDetected = "session_detected"
    case sessionNeedsInput = "session_needs_input"
    case sessionSelected = "session_selected"

    // Actions
    case copyPath = "copy_path"
    case copyBranch = "copy_branch"
    case openFinder = "open_finder"
    case openPR = "open_pr"
}

// MARK: - Amplitude implementation

import AmplitudeSwift

final class AmplitudeAnalyticsProvider: AnalyticsProvider {
    private let apiKey: String
    private var amplitude: Amplitude?

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func configure() {
        amplitude = Amplitude(configuration: Configuration(apiKey: apiKey))
    }

    func track(event: String, properties: [String: Any]?) {
        amplitude?.track(eventType: event, eventProperties: properties)
    }

    func setUser(id: String?, properties: [String: Any]?) {
        if let id {
            amplitude?.setUserId(userId: id)
        } else {
            amplitude?.setUserId(userId: nil)
        }
    }
}

// MARK: - No-op implementation

final class NoOpAnalyticsProvider: AnalyticsProvider {
    func configure() {}
    func track(event: String, properties: [String: Any]?) {}
    func setUser(id: String?, properties: [String: Any]?) {}
}
