import Foundation

enum AppSettings {
    static let defaultPollFrequency: TimeInterval = 3
    private static let pollFrequencyKey = "pollFrequencySeconds"

    static var pollFrequency: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: pollFrequencyKey)
            return stored > 0 ? stored : defaultPollFrequency
        }
        set {
            UserDefaults.standard.set(newValue, forKey: pollFrequencyKey)
        }
    }
}
