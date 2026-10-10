import XCTest

/// Verifies that the sidebar can be navigated with the arrow keys.
final class KeyboardNavigationTests: XCTestCase {

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

    func test_arrowKeys_moveSelectionOneRowAtATime() throws {
        let rows = sidebarRows()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "No sidebar rows found")

        // One accessibility identifier can be reported on more than one element
        // (e.g. the list cell and its content), so dedupe while keeping order.
        var identifiers: [String] = []
        for identifier in rows.allElementsBoundByIndex.map(\.identifier) where !identifiers.contains(identifier) {
            identifiers.append(identifier)
        }
        XCTAssertGreaterThanOrEqual(identifiers.count, 3, "Need at least three rows to test navigation")

        row(identifiers[0]).click()
        assertSelected(identifiers[0], "Clicked row should be selected")
        takeScreenshot(named: "keyboard-nav-1-first-row-selected")

        app.typeKey(.downArrow, modifierFlags: [])
        assertSelected(identifiers[1], "Down arrow should select the next row")
        takeScreenshot(named: "keyboard-nav-2-after-down-arrow")

        app.typeKey(.downArrow, modifierFlags: [])
        assertSelected(identifiers[2], "Down arrow should select the row after that")
        takeScreenshot(named: "keyboard-nav-3-after-second-down-arrow")

        app.typeKey(.upArrow, modifierFlags: [])
        assertSelected(identifiers[1], "Up arrow should select the previous row")
        takeScreenshot(named: "keyboard-nav-4-after-up-arrow")
    }

    // MARK: - Helpers

    private func sidebarRows() -> XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'session-row-' OR identifier BEGINSWITH 'subagent-row-'"))
    }

    private func row(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Identifiers of sidebar rows that are selected, or that sit inside a selected list cell.
    private func selectedRowIdentifiers() -> [String] {
        let selectedElements = app.descendants(matching: .any).matching(NSPredicate(format: "isSelected == true"))
        let direct = sidebarRows().matching(NSPredicate(format: "isSelected == true")).allElementsBoundByIndex
        let nested = selectedElements.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'session-row-' OR identifier BEGINSWITH 'subagent-row-'"))
            .allElementsBoundByIndex
        return Array(Set((direct + nested).map(\.identifier))).sorted()
    }

    private func assertSelected(_ identifier: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let selected = selectedRowIdentifiers()
        XCTAssertEqual(selected, [identifier], "\(message) (selected: \(selected))", file: file, line: line)
    }

    private func takeScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
