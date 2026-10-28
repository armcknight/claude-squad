import Pippin
import XCTest

/// Verifies that Pippin's `ChangelogParser` handles the format of this app's CHANGELOG.md.
final class ChangelogParsingTests: XCTestCase {

    private let markdown = """
    # Changelog

    ## [Unreleased]

    ### Added
    - Something not yet released

    ## [1.1.0] - 2026-04-01

    ### Added
    - New feature

    ## [1.0.1] - 2026-03-15

    ### Fixed
    - A bug

    ## [1.0.0] - 2026-03-06

    ### Added
    - Initial release
    """

    func test_parse_skipsUnreleasedAndReadsVersionsAndDates() {
        let entries = ChangelogParser.parse(from: markdown)

        XCTAssertEqual(entries.map(\.version), ["1.1.0", "1.0.1", "1.0.0"])
        XCTAssertEqual(entries.map(\.date), ["2026-04-01", "2026-03-15", "2026-03-06"])
        XCTAssertEqual(entries.first?.content, "### Added\n- New feature")
    }

    func test_entriesSince_returnsNewerEntriesUpToCurrentVersion() {
        let entries = ChangelogParser.parse(from: markdown)

        let newEntries = ChangelogParser.entriesSince("1.0.0", upTo: "1.1.0", from: entries)

        XCTAssertEqual(newEntries.map(\.version), ["1.1.0", "1.0.1"])
    }

    func test_entriesSince_returnsEmptyWhenLastVersionIsUnknown() {
        let entries = ChangelogParser.parse(from: markdown)

        let newEntries = ChangelogParser.entriesSince("0.9.0", upTo: "1.1.0", from: entries)

        XCTAssertTrue(newEntries.isEmpty)
    }

    func test_parse_bundledChangelog() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"))
        let content = try String(contentsOf: url, encoding: .utf8)

        let entries = ChangelogParser.parse(from: content)

        XCTAssertTrue(entries.contains { $0.version == "1.0.0" })
        XCTAssertFalse(entries.contains { $0.version.lowercased() == "unreleased" })
    }
}
