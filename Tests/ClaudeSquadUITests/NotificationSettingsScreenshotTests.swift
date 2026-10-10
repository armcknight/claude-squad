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

        let needsInputToggle = settingsWindow.descendants(matching: .any).matching(identifier: "notify-on-needs-input-toggle").firstMatch
        let idleToggle = settingsWindow.descendants(matching: .any).matching(identifier: "notify-on-idle-toggle").firstMatch
        guard needsInputToggle.waitForExistence(timeout: 5) else {
            let tree = XCTAttachment(string: settingsWindow.debugDescription)
            tree.name = "settings-accessibility-tree"
            tree.lifetime = .keepAlways
            add(tree)
            XCTFail("Needs-input notification toggle missing:\n\(settingsWindow.debugDescription)")
            return
        }
        XCTAssertTrue(idleToggle.exists, "Idle notification toggle missing")
        XCTAssertTrue(isOn(needsInputToggle), "Needs-input toggle should default to on")
        XCTAssertTrue(isOn(idleToggle), "Idle toggle should default to on")

        let attachment = XCTAttachment(screenshot: settingsWindow.screenshot())
        attachment.name = "settings-notification-toggles"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Switches and checkboxes report their state as either an Int or a String.
    private func isOn(_ element: XCUIElement) -> Bool {
        if let number = element.value as? Int { return number == 1 }
        if let string = element.value as? String { return string == "1" }
        return false
    }
}
