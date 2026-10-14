import XCTest
@testable import ClaudeSquad

final class AppMoverTests: XCTestCase {

    func testShouldSkipLocationCheck_whenArgumentPresent() {
        XCTAssertTrue(AppMover.shouldSkipLocationCheck(arguments: ["/path/to/app", "--skip-app-location-check"]))
    }

    func testShouldSkipLocationCheck_whenArgumentAbsent() {
        XCTAssertFalse(AppMover.shouldSkipLocationCheck(arguments: ["/path/to/app", "--mock"]))
    }

    func testIsInApplicationsFolder_whenInApplications() {
        XCTAssertTrue(AppMover.isInApplicationsFolder(bundlePath: "/Applications/Claude Squad.app"))
    }

    func testIsInApplicationsFolder_whenInDerivedData() {
        XCTAssertFalse(AppMover.isInApplicationsFolder(bundlePath: "/Users/dev/Library/Developer/Xcode/DerivedData/ClaudeSquad/Build/Products/Debug/Claude Squad.app"))
    }

    func testIsInApplicationsFolder_whenInUserApplications() {
        XCTAssertFalse(AppMover.isInApplicationsFolder(bundlePath: "/Users/dev/Applications/Claude Squad.app"))
    }
}
