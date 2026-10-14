import UserNotifications
import XCTest
@testable import ClaudeSquad

final class NotificationManagerTests: XCTestCase {

    private let settingsKeys = ["notifyOnNeedsInput", "notifyOnIdle"]

    private var center: FakeNotificationCenter!
    private var logger: Logger!
    private var analytics: RecordingAnalyticsProvider!
    private var errorReporter: RecordingErrorReporter!
    private var manager: NotificationManager!

    override func setUp() {
        super.setUp()
        settingsKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        center = FakeNotificationCenter()
        logger = Logger()
        analytics = RecordingAnalyticsProvider()
        errorReporter = RecordingErrorReporter()
        manager = NotificationManager(center: center, logger: logger, analytics: analytics, errorReporter: errorReporter)
    }

    override func tearDown() {
        settingsKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    // MARK: - Settings

    func test_settings_defaultToEnabled() {
        XCTAssertTrue(AppSettings.notifyOnNeedsInput)
        XCTAssertTrue(AppSettings.notifyOnIdle)
    }

    func test_settings_roundTrip() {
        AppSettings.notifyOnNeedsInput = false
        AppSettings.notifyOnIdle = false
        XCTAssertFalse(AppSettings.notifyOnNeedsInput)
        XCTAssertFalse(AppSettings.notifyOnIdle)
    }

    // MARK: - Content

    func test_content_forQuestion_usesQuestionText() throws {
        let session = makeSession(status: .waitingForQuestion(since: Date(), question: "Pick one"))
        let content = try XCTUnwrap(NotificationManager.content(for: session))
        XCTAssertTrue(content.title.hasSuffix("needs input"))
        XCTAssertEqual(content.body, "Pick one")
        XCTAssertEqual(content.userInfo[NotificationManager.sessionIDKey] as? String, session.id)
    }

    func test_content_forIdle() throws {
        let session = makeSession(status: .waitingIdle(since: Date()))
        let content = try XCTUnwrap(NotificationManager.content(for: session))
        XCTAssertTrue(content.title.hasSuffix("is idle"))
    }

    func test_content_nilWhenNotWaiting() {
        XCTAssertNil(NotificationManager.content(for: makeSession(status: .running)))
        XCTAssertNil(NotificationManager.content(for: makeSession(status: .inactive(lastActivity: Date()))))
    }

    func test_content_respectsDisabledSettings() {
        AppSettings.notifyOnNeedsInput = false
        XCTAssertNil(NotificationManager.content(for: makeSession(status: .waitingForQuestion(since: Date(), question: nil))))
        XCTAssertNotNil(NotificationManager.content(for: makeSession(status: .waitingIdle(since: Date()))))

        AppSettings.notifyOnNeedsInput = true
        AppSettings.notifyOnIdle = false
        XCTAssertNil(NotificationManager.content(for: makeSession(status: .waitingIdle(since: Date()))))
    }

    // MARK: - Posting

    func test_init_setsDelegate() {
        XCTAssertTrue(center.delegate === manager)
    }

    func test_postNotification_addsRequestAndTracks() {
        manager.postNotification(for: makeSession(status: .waitingIdle(since: Date())))
        XCTAssertEqual(center.addedRequests.count, 1)
        XCTAssertEqual(analytics.events.map(\.name), [AnalyticsEvent.notificationPosted.rawValue])
        XCTAssertEqual(analytics.events.first?.properties?["kind"] as? String, "idle")
    }

    func test_postNotification_skipsWhenDisabled() {
        AppSettings.notifyOnIdle = false
        manager.postNotification(for: makeSession(status: .waitingIdle(since: Date())))
        XCTAssertTrue(center.addedRequests.isEmpty)
        XCTAssertTrue(analytics.events.isEmpty)
    }

    func test_postNotification_reportsAddError() {
        center.addError = NSError(domain: "test", code: 1)
        manager.postNotification(for: makeSession(status: .waitingIdle(since: Date())))
        XCTAssertEqual(errorReporter.errors.count, 1)
    }

    func test_requestAuthorization_reportsError() {
        center.authorizationError = NSError(domain: "test", code: 2)
        manager.requestAuthorization()
        XCTAssertEqual(errorReporter.errors.count, 1)
    }

    // MARK: - Clicks

    func test_handleClick_invokesCallbackWithSessionID() {
        let expectation = expectation(description: "click")
        manager.onNotificationClicked = { sessionID in
            XCTAssertEqual(sessionID, "abc")
            expectation.fulfill()
        }
        manager.handleClick(userInfo: [NotificationManager.sessionIDKey: "abc"])
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(analytics.events.map(\.name), [AnalyticsEvent.notificationClicked.rawValue])
    }

    func test_handleClick_ignoresMissingSessionID() {
        manager.onNotificationClicked = { _ in XCTFail("Should not be called") }
        manager.handleClick(userInfo: [:])
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertTrue(analytics.events.isEmpty)
    }

    // MARK: - Helpers

    private func makeSession(status: SessionStatus) -> ClaudeSession {
        ClaudeSession(
            id: "session-1",
            projectPath: "/Users/test/test-project",
            ownStatus: status,
            status: status,
            lastModified: Date()
        )
    }
}

// MARK: - Test doubles

final class FakeNotificationCenter: NotificationCenterProtocol {
    weak var delegate: UNUserNotificationCenterDelegate?
    var addedRequests: [UNNotificationRequest] = []
    var addError: Error?
    var authorizationError: Error?

    func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping @Sendable (Bool, Error?) -> Void) {
        completionHandler(authorizationError == nil, authorizationError)
    }

    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?) {
        addedRequests.append(request)
        completionHandler?(addError)
    }
}

final class RecordingAnalyticsProvider: AnalyticsProvider {
    var events: [(name: String, properties: [String: Any]?)] = []
    func configure() {}
    func track(event: String, properties: [String: Any]?) { events.append((event, properties)) }
    func setUser(id: String?, properties: [String: Any]?) {}
}

final class RecordingErrorReporter: ErrorReporter {
    var errors: [Error] = []
    func configure() {}
    func capture(error: Error, context: [String: Any]?) { errors.append(error) }
    func capture(message: String, level: ErrorReportingLevel, context: [String: Any]?) {}
    func setUser(id: String?, email: String?) {}
}
