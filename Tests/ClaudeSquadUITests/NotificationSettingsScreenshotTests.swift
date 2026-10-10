import XCTest

/// Shows the notification toggles in Settings > General.
final class NotificationSettingsScreenshotTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Argument-domain defaults pin both toggles on without writing to the
        // app's persistent defaults.
        app.launchArguments = ["--mock", "-notifyOnNeedsInput", "YES", "-notifyOnIdle", "YES"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testNotificationTogglesAppearInSettings() throws {
        app.typeKey(",", modifierFlags: .command)

        let settingsWindow = app.windows["Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5), "Settings window did not open")

        let needsInputToggle = settingsWindow.checkBoxes["notify-on-needs-input-toggle"]
        let idleToggle = settingsWindow.checkBoxes["notify-on-idle-toggle"]
        XCTAssertTrue(needsInputToggle.waitForExistence(timeout: 5), "Needs-input notification toggle missing")
        XCTAssertTrue(idleToggle.exists, "Idle notification toggle missing")
        XCTAssertEqual(needsInputToggle.value as? Int, 1)
        XCTAssertEqual(idleToggle.value as? Int, 1)

        let attachment = XCTAttachment(screenshot: settingsWindow.screenshot())
        attachment.name = "settings-notification-toggles"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
