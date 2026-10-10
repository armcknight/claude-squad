import XCTest

/// Verifies the sidebar warning icon for sessions running in Claude Code auto mode.
/// The mock `backend-api` session (bbbb2222…) has `"permissionMode":"auto"`; the
/// mock `ios-app` session (aaaa1111…) has no permission mode recorded.
final class PermissionModeWarningTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--mock"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testAutoModeSessionShowsWarningIcon() throws {
        let autoSessionId = "bbbb2222-2222-2222-2222-222222222222"
        let defaultSessionId = "aaaa1111-1111-1111-1111-111111111111"

        let autoRow = element(identifier: "session-row-\(autoSessionId)")
        XCTAssertTrue(autoRow.waitForExistence(timeout: 10), "Auto mode session row not found")

        let warning = element(identifier: "permission-mode-warning-\(autoSessionId)")
        XCTAssertTrue(warning.exists, "Auto mode session has no warning icon")

        XCTAssertTrue(element(identifier: "session-row-\(defaultSessionId)").exists, "Default mode session row not found")
        XCTAssertFalse(element(identifier: "permission-mode-warning-\(defaultSessionId)").exists,
                       "Session without auto mode shows a warning icon")

        takeScreenshot(named: "auto-mode-warning-sidebar")

        autoRow.click()
        takeScreenshot(named: "auto-mode-warning-selected")
    }

    // MARK: - Helpers

    private func element(identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func takeScreenshot(named name: String) {
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
