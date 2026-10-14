import Foundation

/// Abstract software-update interface. Swap implementations to change update mechanisms.
protocol AppUpdater: AnyObject {
    /// Whether this updater can deliver updates at all. False for the no-op implementation.
    var isAvailable: Bool { get }
    /// Whether a user-initiated check can start right now (false while a check is in progress).
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    func start()
    func checkForUpdates()
}

/// Reads the Sparkle settings out of an Info.plist dictionary.
struct AppUpdaterConfiguration: Equatable {
    static let feedURLKey = "SUFeedURL"
    static let publicEDKeyKey = "SUPublicEDKey"

    let feedURL: URL
    let publicEDKey: String

    /// Returns nil when the feed URL or the EdDSA public key is missing or empty. Sparkle
    /// refuses to install updates it cannot verify, so there is no point starting it then.
    init?(infoDictionary: [String: Any]?) {
        guard let feed = infoDictionary?[Self.feedURLKey] as? String,
              let feedURL = URL(string: feed),
              feedURL.scheme == "https",
              let publicEDKey = infoDictionary?[Self.publicEDKeyKey] as? String,
              !publicEDKey.isEmpty else {
            return nil
        }
        self.feedURL = feedURL
        self.publicEDKey = publicEDKey
    }
}

// MARK: - No-op implementation

final class NoOpAppUpdater: AppUpdater {
    let isAvailable = false
    let canCheckForUpdates = false
    var automaticallyChecksForUpdates = false
    func start() {}
    func checkForUpdates() {}
}
