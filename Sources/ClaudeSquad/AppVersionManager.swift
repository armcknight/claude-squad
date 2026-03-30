import Foundation

protocol AppVersionManagerProtocol: AnyObject {
    var currentVersion: String? { get }
    var lastLaunchedVersion: String? { get }
    func checkForUpgrade() -> Bool
    func saveCurrentVersion()
}

final class AppVersionManager: AppVersionManagerProtocol {
    private let userDefaults: UserDefaults
    private let lastLaunchedVersionKey = "lastLaunchedAppVersion"

    var currentVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    var lastLaunchedVersion: String? {
        userDefaults.string(forKey: lastLaunchedVersionKey)
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Returns true if the current version differs from the last launched version.
    func checkForUpgrade() -> Bool {
        guard let current = currentVersion else { return false }
        let last = lastLaunchedVersion
        return last != nil && last != current
    }

    func saveCurrentVersion() {
        guard let current = currentVersion else { return }
        userDefaults.set(current, forKey: lastLaunchedVersionKey)
    }
}
