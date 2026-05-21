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
        XCTAssertFalse(SessionStatus.interrupted(lastActivity: Date()).isActive)
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
        XCTAssertEqual(SessionStatus.interrupted(lastActivity: Date()).sortPriority, 1)
        XCTAssertEqual(SessionStatus.waitingIdle(since: Date()).sortPriority, 2)
        XCTAssertEqual(SessionStatus.running.sortPriority, 3)
        XCTAssertEqual(SessionStatus.inactive(lastActivity: Date()).sortPriority, 4)
    }

    // MARK: - ClaudeSession sorting

    func test_waitingForQuestionSortsFirst() {
        let question = makeSession(id: "a", status: .waitingForQuestion(since: Date(), question: nil))
        let interrupted = makeSession(id: "b", status: .interrupted(lastActivity: Date()))
        let idle = makeSession(id: "c", status: .waitingIdle(since: Date()))
        let running = makeSession(id: "d", status: .running)
        let inactive = makeSession(id: "e", status: .inactive(lastActivity: Date()))

        let sorted = [inactive, running, idle, interrupted, question].sorted()
        XCTAssertEqual(sorted.map(\.id), ["a", "b", "c", "d", "e"])
    }

    func test_longerWaitSortsFirst() {
        let older = makeSession(id: "a", status: .waitingIdle(since: Date(timeIntervalSinceNow: -120)))
        let newer = makeSession(id: "b", status: .waitingIdle(since: Date(timeIntervalSinceNow: -10)))
        let sorted = [newer, older].sorted()
        XCTAssertEqual(sorted.map(\.id), ["a", "b"])
    }

    func test_displayNameAbbreviatesPath() {
        let session = makeSession(id: "x", status: .running)
        // /Users/test/test-project → abbreviated with first letters
        XCTAssertTrue(session.displayName.hasSuffix("test-project"))
        XCTAssertTrue(session.displayName.count < session.projectPath.count)
    }

    func test_abbreviatePath() {
        let home = NSHomeDirectory()
        XCTAssertEqual(abbreviatePath("\(home)/Code/org/repos/my-project"), "~/C/o/r/my-project")
        XCTAssertEqual(abbreviatePath("/tmp/foo"), "/t/foo")
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
            ownStatus: status,
            status: status,
            lastModified: Date()
        )
    }
}
