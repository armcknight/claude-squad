import Foundation
import UserNotifications

/// The subset of `UNUserNotificationCenter` used by `NotificationManager`.
/// Abstracted so tests can substitute a fake (the real center is unavailable
/// in unit test bundles).
protocol NotificationCenterProtocol: AnyObject {
    var delegate: UNUserNotificationCenterDelegate? { get set }
    func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping @Sendable (Bool, Error?) -> Void)
    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?)
}

extension UNUserNotificationCenter: NotificationCenterProtocol {}

/// Posts local notifications when sessions become blocked waiting for user
/// input, and routes notification clicks back to the app.
final class NotificationManager: NSObject {

    /// `userInfo` key holding the id of the session a notification refers to.
    static let sessionIDKey = "sessionID"

    private let center: NotificationCenterProtocol
    weak var logger: Logger?
    weak var analytics: AnalyticsProvider?
    weak var errorReporter: ErrorReporter?

    /// Called on the main thread with the session id when the user clicks a notification.
    var onNotificationClicked: ((_ sessionID: String) -> Void)?

    init(center: NotificationCenterProtocol, logger: Logger, analytics: AnalyticsProvider, errorReporter: ErrorReporter) {
        self.center = center
        self.logger = logger
        self.analytics = analytics
        self.errorReporter = errorReporter
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            guard let self else { return }
            if let error {
                self.logger?.error("Notification authorization failed: \(error.localizedDescription)")
                self.reportError(error, context: ["action": "request_authorization"])
            } else {
                self.logger?.info("Notification authorization granted: \(granted)")
            }
        }
    }

    /// Posts a notification for a session that just started waiting, unless
    /// the user disabled notifications for that kind of wait in Settings.
    func postNotification(for session: ClaudeSession) {
        guard let content = Self.content(for: session) else {
            logger?.debug("Skipping notification for \(session.displayName): disabled or not waiting")
            return
        }

        let request = UNNotificationRequest(
            identifier: "claude-squad-\(session.id)-\(session.status.sortPriority)",
            content: content,
            trigger: nil
        )
        logger?.info("Posting notification for \(session.displayName): \(content.title)")
        center.add(request) { [weak self] error in
            guard let self else { return }
            if let error {
                self.logger?.error("Failed to post notification: \(error.localizedDescription)")
                self.reportError(error, context: ["action": "add_request"])
            }
        }
        if let kind = Self.kind(for: session.status) {
            analytics?.track(event: AnalyticsEvent.notificationPosted.rawValue, properties: ["kind": kind])
        }
    }

    /// Builds notification content for a waiting session, or nil if the
    /// session isn't waiting or the matching setting is turned off.
    static func content(for session: ClaudeSession) -> UNNotificationContent? {
        let content = UNMutableNotificationContent()
        content.sound = .default
        content.userInfo = [sessionIDKey: session.id]

        switch session.status {
        case .waitingForQuestion(_, let question):
            guard AppSettings.notifyOnNeedsInput else { return nil }
            content.title = "\(session.displayName) needs input"
            content.body = question ?? "Claude is asking a question"
        case .waitingIdle:
            guard AppSettings.notifyOnIdle else { return nil }
            content.title = "\(session.displayName) is idle"
            content.body = "Claude has finished and is waiting for your next instruction"
        default:
            return nil
        }
        return content
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {

    /// Show banners even while the app is frontmost; the main window may be
    /// open but showing a different session.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handleClick(userInfo: response.notification.request.content.userInfo)
        completionHandler()
    }
}

// MARK: - Click handling

extension NotificationManager {
    /// Routes a clicked notification's payload to `onNotificationClicked`.
    func handleClick(userInfo: [AnyHashable: Any]) {
        guard let sessionID = userInfo[Self.sessionIDKey] as? String else {
            logger?.warning("Clicked notification has no session id")
            return
        }
        logger?.info("Notification clicked for session \(sessionID)")
        analytics?.track(event: AnalyticsEvent.notificationClicked.rawValue)
        DispatchQueue.main.async { [weak self] in
            self?.onNotificationClicked?(sessionID)
        }
    }
}

private extension NotificationManager {
    static func kind(for status: SessionStatus) -> String? {
        switch status {
        case .waitingForQuestion: return "needs_input"
        case .waitingIdle: return "idle"
        default: return nil
        }
    }

    func reportError(_ error: Error, context: [String: Any]) {
        guard let errorReporter else {
            logger?.warning("NotificationManager: errorReporter is nil")
            return
        }
        errorReporter.capture(error: error, context: context)
    }
}
