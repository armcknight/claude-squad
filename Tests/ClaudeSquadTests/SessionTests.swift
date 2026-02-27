import XCTest
@testable import ClaudeSquad

final class SessionTests: XCTestCase {

    // MARK: - SessionStatus

    func test_isWaiting() {
        XCTAssertFalse(SessionStatus.running.isWaiting)
        XCTAssertTrue(SessionStatus.waitingIdle(since: Date()).isWaiting)
        XCTAssertTrue(SessionStatus.waitingForQuestion(since: Date(), question: "Pick one").isWaiting)
        XCTAssertFalse(SessionStatus.inactive(lastActivity: Date()).isWaiting)
    }

    func test_isActive() {
        XCTAssertTrue(SessionStatus.running.isActive)
        XCTAssertTrue(SessionStatus.waitingIdle(since: Date()).isActive)
        XCTAssertTrue(SessionStatus.waitingForQuestion(since: Date(), question: nil).isActive)
        XCTAssertFalse(SessionStatus.inactive(lastActivity: Date()).isActive)
    }

    func test_waitingDuration() {
        let since = Date(timeIntervalSinceNow: -30)
        let idleDuration = SessionStatus.waitingIdle(since: since).waitingDuration
        XCTAssertGreaterThanOrEqual(idleDuration, 29)
        XCTAssertLessThan(idleDuration, 35)

        let questionDuration = SessionStatus.waitingForQuestion(since: since, question: nil).waitingDuration
        XCTAssertGreaterThanOrEqual(questionDuration, 29)

        XCTAssertEqual(SessionStatus.running.waitingDuration, 0)
        XCTAssertEqual(SessionStatus.inactive(lastActivity: Date()).waitingDuration, 0)
    }

    func test_sortPriority() {
        XCTAssertEqual(SessionStatus.waitingForQuestion(since: Date(), question: nil).sortPriority, 0)
        XCTAssertEqual(SessionStatus.waitingIdle(since: Date()).sortPriority, 1)
        XCTAssertEqual(SessionStatus.running.sortPriority, 2)
        XCTAssertEqual(SessionStatus.inactive(lastActivity: Date()).sortPriority, 3)
    }

    // MARK: - ClaudeSession sorting

    func test_waitingForQuestionSortsFirst() {
        let question = makeSession(id: "a", status: .waitingForQuestion(since: Date(), question: nil))
        let idle = makeSession(id: "b", status: .waitingIdle(since: Date()))
        let running = makeSession(id: "c", status: .running)
        let inactive = makeSession(id: "d", status: .inactive(lastActivity: Date()))

        let sorted = [inactive, running, idle, question].sorted()
        XCTAssertEqual(sorted.map(\.id), ["a", "b", "c", "d"])
    }

    func test_longerWaitSortsFirst() {
        let older = makeSession(id: "a", status: .waitingIdle(since: Date(timeIntervalSinceNow: -120)))
        let newer = makeSession(id: "b", status: .waitingIdle(since: Date(timeIntervalSinceNow: -10)))
        let sorted = [newer, older].sorted()
        XCTAssertEqual(sorted.map(\.id), ["a", "b"])
    }

    func test_displayNameUsesSlugWhenAvailable() {
        var session = makeSession(id: "x", status: .running)
        session.slug = "my-feature"
        XCTAssertEqual(session.displayName, "my-feature")
    }

    func test_displayNameFallsBackToProjectName() {
        let session = makeSession(id: "x", status: .running)
        XCTAssertEqual(session.displayName, "test-project")
    }

    func test_projectName() {
        let session = makeSession(id: "x", status: .running)
        XCTAssertEqual(session.projectName, "test-project")
    }

    // MARK: - Helpers

    private func makeSession(id: String, status: SessionStatus) -> ClaudeSession {
        ClaudeSession(
            id: id,
            projectPath: "/Users/test/test-project",
            status: status,
            lastModified: Date()
        )
    }
}
