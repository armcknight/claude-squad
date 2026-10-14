import XCTest
@testable import ClaudeSquad

final class AppUpdaterConfigurationTests: XCTestCase {

    private let feed = "https://armcknight.github.io/claude-squad/appcast.xml"
    private let key = "pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ="

    func test_init_succeedsWithFeedAndKey() throws {
        let config = try XCTUnwrap(AppUpdaterConfiguration(infoDictionary: [
            AppUpdaterConfiguration.feedURLKey: feed,
            AppUpdaterConfiguration.publicEDKeyKey: key,
        ]))
        XCTAssertEqual(config.feedURL.absoluteString, feed)
        XCTAssertEqual(config.publicEDKey, key)
    }

    func test_init_failsWithNilDictionary() {
        XCTAssertNil(AppUpdaterConfiguration(infoDictionary: nil))
    }

    func test_init_failsWithEmptyKey() {
        XCTAssertNil(AppUpdaterConfiguration(infoDictionary: [
            AppUpdaterConfiguration.feedURLKey: feed,
            AppUpdaterConfiguration.publicEDKeyKey: "",
        ]))
    }

    func test_init_failsWithMissingKey() {
        XCTAssertNil(AppUpdaterConfiguration(infoDictionary: [
            AppUpdaterConfiguration.feedURLKey: feed,
        ]))
    }

    func test_init_failsWithEmptyFeed() {
        XCTAssertNil(AppUpdaterConfiguration(infoDictionary: [
            AppUpdaterConfiguration.feedURLKey: "",
            AppUpdaterConfiguration.publicEDKeyKey: key,
        ]))
    }

    func test_init_failsWithInsecureFeed() {
        XCTAssertNil(AppUpdaterConfiguration(infoDictionary: [
            AppUpdaterConfiguration.feedURLKey: "http://armcknight.github.io/claude-squad/appcast.xml",
            AppUpdaterConfiguration.publicEDKeyKey: key,
        ]))
    }

    /// Guards against the xcconfig `//`-is-a-comment trap truncating the feed URL to `https:`.
    func test_bundleFeedURL_isComplete() throws {
        let feed = try XCTUnwrap(Bundle.main.infoDictionary?[AppUpdaterConfiguration.feedURLKey] as? String)
        XCTAssertEqual(feed, self.feed)
    }

    /// Sparkle compares appcast versions against CFBundleVersion, so it must track the marketing version.
    func test_bundleVersion_matchesMarketingVersion() {
        let info = Bundle.main.infoDictionary
        XCTAssertEqual(info?["CFBundleVersion"] as? String, info?["CFBundleShortVersionString"] as? String)
    }
}

final class NoOpAppUpdaterTests: XCTestCase {

    func test_isUnavailable() {
        let updater = NoOpAppUpdater()
        XCTAssertFalse(updater.isAvailable)
        XCTAssertFalse(updater.canCheckForUpdates)
    }

    func test_settingsHeight_growsOnlyWhenUpdatesAvailable() {
        XCTAssertGreaterThan(SettingsView.height(updatesAvailable: true), SettingsView.height(updatesAvailable: false))
    }
}
