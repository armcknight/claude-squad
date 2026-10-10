import Foundation
import Sparkle

/// `AppUpdater` backed by Sparkle's standard updater UI.
final class SparkleAppUpdater: AppUpdater {
    weak var logger: Logger?
    weak var analytics: AnalyticsProvider?
    weak var errorReporter: ErrorReporter?

    private let delegate: SparkleUpdaterDelegate
    private let controller: SPUStandardUpdaterController

    let isAvailable = true

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            controller.updater.automaticallyChecksForUpdates = newValue
            guard let analytics else {
                logger?.warning("SparkleAppUpdater: analytics is nil")
                return
            }
            analytics.track(event: AnalyticsEvent.autoUpdateCheckToggled.rawValue, properties: ["enabled": newValue])
        }
    }

    init(logger: Logger, analytics: AnalyticsProvider, errorReporter: ErrorReporter) {
        self.logger = logger
        self.analytics = analytics
        self.errorReporter = errorReporter
        let delegate = SparkleUpdaterDelegate()
        delegate.logger = logger
        delegate.analytics = analytics
        delegate.errorReporter = errorReporter
        self.delegate = delegate
        self.controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
    }

    func start() {
        do {
            try controller.updater.start()
            logger?.info("Sparkle updater started")
        } catch {
            logger?.error("Failed to start Sparkle updater: \(error.localizedDescription)")
            guard let errorReporter else {
                logger?.warning("SparkleAppUpdater: errorReporter is nil")
                return
            }
            errorReporter.capture(error: error, context: ["operation": "start_updater"])
        }
    }

    func checkForUpdates() {
        guard let analytics else {
            logger?.warning("SparkleAppUpdater: analytics is nil")
            controller.checkForUpdates(nil)
            return
        }
        analytics.track(event: AnalyticsEvent.updateCheckManual.rawValue)
        controller.checkForUpdates(nil)
    }
}

// MARK: - Delegate

/// Receives Sparkle lifecycle callbacks. Separate from `SparkleAppUpdater` so the
/// controller can be created with its delegate before the updater finishes initializing.
final class SparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    weak var logger: Logger?
    weak var analytics: AnalyticsProvider?
    weak var errorReporter: ErrorReporter?

    /// Sparkle reports these through `didAbortWithError`, but they are normal outcomes, not failures.
    static let benignErrorCodes: Set<Int> = [
        Int(SUError.noUpdateError.rawValue),
        Int(SUError.installationCanceledError.rawValue),
        Int(SUError.installationAuthorizeLaterError.rawValue),
    ]

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        logger?.info("Update available: \(item.displayVersionString)")
        analytics?.track(event: AnalyticsEvent.updateFound.rawValue, properties: ["version": item.displayVersionString])
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        logger?.info("No update available")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        logger?.info("Installing update \(item.displayVersionString)")
        analytics?.track(event: AnalyticsEvent.updateInstalling.rawValue, properties: ["version": item.displayVersionString])
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain, Self.benignErrorCodes.contains(nsError.code) {
            return
        }
        logger?.error("Update aborted: \(error.localizedDescription)")
        guard let errorReporter else {
            logger?.warning("SparkleUpdaterDelegate: errorReporter is nil")
            return
        }
        errorReporter.capture(error: error, context: ["operation": "update"])
    }
}
