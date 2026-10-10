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
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'session-row-' OR identifier BEGINSWITH 'subagent-row-'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "No sidebar rows found")
        XCTAssertGreaterThanOrEqual(rows.count, 3, "Need at least three rows to test navigation")

        let first = rows.element(boundBy: 0)
        let second = rows.element(boundBy: 1)
        let third = rows.element(boundBy: 2)

        first.click()
        XCTAssertTrue(isSelected(first), "Clicked row should be selected")

        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(isSelected(second), "Down arrow should select the next row")
        XCTAssertFalse(isSelected(third), "Down arrow should move exactly one row")

        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(isSelected(third), "Down arrow should select the row after that")

        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(isSelected(second), "Up arrow should select the previous row")
    }

    // MARK: - Helpers

    /// A row counts as selected if it or its enclosing list cell reports selection.
    private func isSelected(_ row: XCUIElement) -> Bool {
        let identifier = row.identifier
        let selectedCells = app.descendants(matching: .any).matching(NSPredicate(format: "isSelected == true"))
        let predicate = NSPredicate(format: "identifier == %@", identifier)
        return row.isSelected || selectedCells.descendants(matching: .any).matching(predicate).count > 0
    }
}
