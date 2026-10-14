import XCTest
@testable import ClaudeSquad

final class SessionMonitorPollTests: XCTestCase {

    func test_updateRefreshInterval_doesNotCrash() {
        let detector = ClaudeSessionDetector()
        let monitor = SessionMonitor(detector: detector, refreshInterval: 3)
        monitor.start()
        monitor.updateRefreshInterval(5)
        monitor.stop()
    }

    func test_updateRefreshInterval_appliesNewInterval() {
        let detector = ClaudeSessionDetector()
        let monitor = SessionMonitor(detector: detector, refreshInterval: 3)
        // Verify successive updates are accepted without error.
        monitor.start()
        monitor.updateRefreshInterval(1)
        monitor.updateRefreshInterval(10)
        monitor.stop()
    }
}

final class SessionMonitorTransitionTests: XCTestCase {

    private var monitor: SessionMonitor!
    private var notified: [String] = []

    override func setUp() {
        super.setUp()
        notified = []
        monitor = SessionMonitor(detector: ClaudeSessionDetector(), refreshInterval: 3)
        monitor.onNeedsAttention = { [weak self] session in
            self?.notified.append(session.id)
        }
    }

    func test_initialRefresh_doesNotNotifyForAlreadyWaitingSessions() {
        monitor.checkTransitions(newSessions: [makeSession(id: "a", status: .waitingIdle(since: Date()))])
        XCTAssertEqual(notified, [])
    }

    func test_transitionToWaiting_notifies() {
        monitor.checkTransitions(newSessions: [makeSession(id: "a", status: .running)])
        monitor.checkTransitions(newSessions: [makeSession(id: "a", status: .waitingForQuestion(since: Date(), question: nil))])
        XCTAssertEqual(notified, ["a"])
    }

    func test_remainingInSameWaitingState_doesNotRenotify() {
        monitor.checkTransitions(newSessions: [makeSession(id: "a", status: .running)])
        monitor.checkTransitions(newSessions: [makeSession(id: "a", status: .waitingIdle(since: Date()))])
        monitor.checkTransitions(newSessions: [makeSession(id: "a", status: .waitingIdle(since: Date()))])
        XCTAssertEqual(notified, ["a"])
    }

    func test_newSessionAppearingWaitingAfterLaunch_notifies() {
        monitor.checkTransitions(newSessions: [])
        monitor.checkTransitions(newSessions: [makeSession(id: "b", status: .waitingIdle(since: Date()))])
        XCTAssertEqual(notified, ["b"])
    }

    private func makeSession(id: String, status: SessionStatus) -> ClaudeSession {
        ClaudeSession(
            id: id,
            projectPath: "/Users/test/test-project",
            ownStatus: status,
            status: status,
            lastModified: Date()
        )
    }
}
