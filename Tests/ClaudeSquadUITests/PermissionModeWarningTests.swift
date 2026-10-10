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
        let autoRow = element(identifier: "session-row-bbbb2222-2222-2222-2222-222222222222")
        XCTAssertTrue(autoRow.waitForExistence(timeout: 10), "Auto mode session row not found")
        XCTAssertTrue(element(identifier: "session-row-aaaa1111-1111-1111-1111-111111111111").exists,
                      "Default mode session row not found")

        // The row's identifier overrides identifiers inside it, so find the icon
        // by its accessibility label. Only the backend-api mock session is in auto mode.
        let warnings = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Auto mode is on'"))
        XCTAssertTrue(warnings.firstMatch.waitForExistence(timeout: 5), "Auto mode session has no warning icon")
        XCTAssertEqual(warnings.count, 1, "Warning icon shown on a session that is not in auto mode")

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
