import Foundation

enum AppSettings {
    static let defaultPollFrequency: TimeInterval = 3
    private static let pollFrequencyKey = "pollFrequencySeconds"
    private static let notifyOnNeedsInputKey = "notifyOnNeedsInput"
    private static let notifyOnIdleKey = "notifyOnIdle"

    static var pollFrequency: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: pollFrequencyKey)
            return stored > 0 ? stored : defaultPollFrequency
        }
        set {
            UserDefaults.standard.set(newValue, forKey: pollFrequencyKey)
        }
    }

    /// Whether to post a notification when a session asks a question. Defaults to `true`.
    static var notifyOnNeedsInput: Bool {
        get { bool(forKey: notifyOnNeedsInputKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: notifyOnNeedsInputKey) }
    }

    /// Whether to post a notification when a session finishes and goes idle. Defaults to `true`.
    static var notifyOnIdle: Bool {
        get { bool(forKey: notifyOnIdleKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: notifyOnIdleKey) }
    }
}

private extension AppSettings {
    static func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return UserDefaults.standard.bool(forKey: key)
    }
}
