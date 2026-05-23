import XCTest
@testable import ClaudeSquad

final class AppSettingsTests: XCTestCase {

    private let key = "pollFrequencySeconds"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func test_defaultPollFrequency_whenNoValueStored() {
        XCTAssertEqual(AppSettings.pollFrequency, AppSettings.defaultPollFrequency)
    }

    func test_pollFrequency_roundTrips() {
        AppSettings.pollFrequency = 10
        XCTAssertEqual(AppSettings.pollFrequency, 10)
    }

    func test_pollFrequency_defaultIgnoresZero() {
        UserDefaults.standard.set(0.0, forKey: key)
        XCTAssertEqual(AppSettings.pollFrequency, AppSettings.defaultPollFrequency)
    }
}
