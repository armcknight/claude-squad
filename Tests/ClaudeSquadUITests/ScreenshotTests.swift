import XCTest

/// Takes marketing screenshots of the app using mock data.
/// Run with: xcodebuild test -scheme ClaudeSquad -destination 'platform=macOS' -only-testing ClaudeSquadUITests/ScreenshotTests
final class ScreenshotTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--mock"]
        app.launch()

        // Wait for the window and sessions to load.
        sleep(3)
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    // MARK: - Screenshots

    func testScreenshot_01_FullOverview() throws {
        takeScreenshot(named: "01-full-overview")
    }

    func testScreenshot_02_NeedsInput() throws {
        try clickFirstRowInSection("Needs Input")
        takeScreenshot(named: "02-needs-input")
    }

    func testScreenshot_03_Idle() throws {
        try clickFirstRowInSection("Idle")
        takeScreenshot(named: "03-idle")
    }

    func testScreenshot_04_Running() throws {
        try clickFirstRowInSection("Running")
        takeScreenshot(named: "04-running")
    }

    func testScreenshot_05_Interrupted() throws {
        try clickFirstRowInSection("Interrupted")
        takeScreenshot(named: "05-interrupted")
    }

    // MARK: - Helpers

    /// Collects all section headers and session rows in document order,
    /// then clicks the first session row that follows the target section header.
    private func clickFirstRowInSection(_ sectionTitle: String) throws {
        // Query all elements whose identifier starts with "section-" or "session-row-".
        let allElements = app.descendants(matching: .any)
        let sectionPredicate = NSPredicate(format: "identifier BEGINSWITH 'section-' OR identifier BEGINSWITH 'session-row-'")
        let matching = allElements.matching(sectionPredicate)
        let count = matching.count

        // Walk in order: find our section header, then click the next session row.
        var foundSection = false
        for i in 0..<count {
            let el = matching.element(boundBy: i)
            let ident = el.identifier
            if ident == "section-\(sectionTitle)" {
                foundSection = true
                continue
            }
            if foundSection && ident.hasPrefix("session-row-") {
                el.click()
                sleep(1)
                return
            }
        }

        XCTFail("Could not find a session row in section '\(sectionTitle)' (foundSection=\(foundSection), checked \(count) elements)")
    }

    private func takeScreenshot(named name: String) {
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
