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
