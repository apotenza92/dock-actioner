import Foundation
import Combine
import AppKit
import Darwin
import Sparkle

@MainActor
final class UpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdateManager(preferences: Preferences.shared)

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var currentVersionText = UpdateManager.makeCurrentVersionText()
    @Published private(set) var updateStatusText = "Update status unavailable."

    private let preferences: Preferences
    private var updateCheckTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var didConfigure = false
    private var isCheckingForUpdates = false

    private struct RelaunchTestConfiguration: Decodable {
        let expectedVersion: String
        let resultPath: String
        let bundlePath: String
        let expiresAt: TimeInterval
    }

    private var relaunchTestConfiguration: RelaunchTestConfiguration? {
        let path = "/tmp/dockmint-sparkle-update-test.json"
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let data = FileManager.default.contents(atPath: path),
              let configuration = try? JSONDecoder().decode(RelaunchTestConfiguration.self, from: data),
              configuration.expiresAt > Date().timeIntervalSince1970,
              URL(fileURLWithPath: configuration.bundlePath).resolvingSymlinksInPath()
                == Bundle.main.bundleURL.resolvingSymlinksInPath(),
              configuration.resultPath.hasPrefix("/") else {
            return nil
        }
        return configuration
    }

    private var releaseUpdateTestEnvironment: [String: String]? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DOCKMINT_SPARKLE_UPDATE_TEST"] == "1",
              let feedURL = environment["DOCKMINT_SPARKLE_TEST_FEED_URL"],
              feedURL.hasPrefix("http://127.0.0.1:"),
              let expectedVersion = environment["DOCKMINT_SPARKLE_TEST_EXPECTED_VERSION"],
              !expectedVersion.isEmpty,
              let resultPath = environment["DOCKMINT_SPARKLE_TEST_RESULT"],
              resultPath.hasPrefix("/") else {
            return nil
        }
        return ["feedURL": feedURL, "expectedVersion": expectedVersion, "resultPath": resultPath]
    }

    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    init(preferences: Preferences) {
        self.preferences = preferences
        super.init()
    }

    func configureForLaunch(isAutomatedMode: Bool) {
        guard !didConfigure else { return }
        didConfigure = true

        if let test = relaunchTestConfiguration,
           Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == test.expectedVersion {
            writeReleaseUpdateTestResult("installed-and-relaunched:\(test.expectedVersion)", path: test.resultPath)
            try? FileManager.default.removeItem(atPath: "/tmp/dockmint-sparkle-update-test.json")
            NSApp.terminate(nil)
            return
        }

        guard !isAutomatedMode else {
            Logger.log("UpdateManager disabled in automated test mode")
            updateStatusText = "Update checks disabled in automated test mode."
            return
        }

        guard AppIdentity.supportsUpdates else {
            Logger.log("UpdateManager disabled for bundle identity \(AppIdentity.bundleIdentifier)")
            canCheckForUpdates = false
            updateStatusText = "Update checks disabled for this app identity."
            return
        }

        updaterController.startUpdater()
        if releaseUpdateTestEnvironment != nil {
            updaterController.updater.automaticallyDownloadsUpdates = true
            DispatchQueue.main.async { [weak self] in
                self?.updaterController.updater.checkForUpdatesInBackground()
            }
        }
        bindUpdaterState()
        bindPreferences()
        refreshIdleStatusText()
        performLaunchUpdateCheckIfNeeded()
        rescheduleAutomaticChecks()
    }

    func checkForUpdates() {
        guard didConfigure else { return }
        guard updaterController.updater.canCheckForUpdates else { return }
        preferences.markUpdateCheckNow()
        beginUpdateCheck(statusText: "Checking for updates...")
        updaterController.checkForUpdates(nil)
    }

    private func bindUpdaterState() {
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
            .store(in: &cancellables)
    }

    private func bindPreferences() {
        preferences.$updateCheckFrequency
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.rescheduleAutomaticChecks()
                self?.refreshIdleStatusText()
            }
            .store(in: &cancellables)
    }

    private func performLaunchUpdateCheckIfNeeded() {
        guard preferences.updateCheckFrequency != .never else {
            refreshIdleStatusText()
            return
        }
        guard preferences.shouldCheckForUpdatesOnLaunch() else { return }
        performBackgroundUpdateCheck()
    }

    private func rescheduleAutomaticChecks() {
        updateCheckTimer?.invalidate()
        updateCheckTimer = nil

        guard let interval = preferences.updateCheckFrequency.interval else {
            refreshIdleStatusText()
            return
        }

        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performBackgroundUpdateCheck()
            }
        }
        timer.tolerance = min(300, interval * 0.15)
        updateCheckTimer = timer
    }

    private func performBackgroundUpdateCheck() {
        guard preferences.updateCheckFrequency != .never else {
            refreshIdleStatusText()
            return
        }
        guard updaterController.updater.canCheckForUpdates else { return }
        preferences.markUpdateCheckNow()
        beginUpdateCheck(statusText: "Checking for updates in the background...")
        updaterController.updater.checkForUpdatesInBackground()
    }

    private func beginUpdateCheck(statusText: String) {
        isCheckingForUpdates = true
        updateStatusText = statusText
    }

    private func refreshIdleStatusText() {
        guard !isCheckingForUpdates else { return }
        if preferences.updateCheckFrequency == .never {
            updateStatusText = "Background update checks are disabled until you enable them."
        } else {
            updateStatusText = "Background update checks are enabled (\(preferences.updateCheckFrequency.displayName.lowercased()))."
        }
    }

    private func finishUpdateCheckIfNeeded() {
        isCheckingForUpdates = false
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        let environment = ProcessInfo.processInfo.environment
        if environment["DOCKMINT_SPARKLE_UPDATE_TEST"] == "1",
           let testFeedURL = environment["DOCKMINT_SPARKLE_TEST_FEED_URL"],
           testFeedURL.hasPrefix("http://127.0.0.1:") {
            return testFeedURL
        }
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        let usesTransitionBundleIdentifier = bundleIdentifier == "pzc.Dockter"
            || bundleIdentifier == "pzc.Dockter.beta"
        let isBetaBuild = bundleIdentifier == "pzc.Dockmint.beta"
            || bundleIdentifier == "pzc.Dockter.beta"
        let repository = usesTransitionBundleIdentifier ? "apotenza92/docktor" : "apotenza92/dockmint"
        let channel = isBetaBuild ? "beta" : "stable"
        let arch = Self.architectureSuffix
        return "https://raw.githubusercontent.com/\(repository)/main/appcasts/\(channel)-\(arch).xml"
    }

    nonisolated private static var architectureSuffix: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }

    private static func makeCurrentVersionText() -> String {
        let bundle = Bundle.main
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

        switch shortVersion {
        case let .some(shortVersion) where !shortVersion.isEmpty:
            return "Version \(shortVersion)"
        default:
            return "Version unavailable"
        }
    }

    private func updateStatusText(for error: Error) -> String {
        let nsError = error as NSError

        if nsError.domain == SUSparkleErrorDomain,
           nsError.userInfo[SPUNoUpdateFoundReasonKey] != nil {
            return "You're up to date."
        }

        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSUserCancelledError {
            return "Update cancelled."
        }

        if nsError.localizedDescription.localizedCaseInsensitiveContains("up to date") {
            return "You're up to date."
        }

        return "Update check failed: \(nsError.localizedDescription)"
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in
            finishUpdateCheckIfNeeded()
            updateStatusText = "Update available: \(item.displayVersionString)"
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            finishUpdateCheckIfNeeded()
            updateStatusText = "You're up to date."
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        Task { @MainActor in
            finishUpdateCheckIfNeeded()
            updateStatusText = "You're up to date."
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Task { @MainActor in
            finishUpdateCheckIfNeeded()
            updateStatusText = "Installing update \(item.displayVersionString)..."
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Task { @MainActor in
            if let test = releaseUpdateTestEnvironment {
                writeReleaseUpdateTestResult("error:\(error.localizedDescription)", path: test["resultPath"]!)
            }
            finishUpdateCheckIfNeeded()
            updateStatusText = updateStatusText(for: error)
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock: @escaping () -> Void
    ) -> Bool {
        guard ProcessInfo.processInfo.environment["DOCKMINT_SPARKLE_UPDATE_TEST"] == "1" else {
            return false
        }
        immediateInstallationBlock()
        return true
    }

    private func writeReleaseUpdateTestResult(_ value: String, path: String) {
        do {
            try value.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            Logger.log("Failed to write Sparkle release-test result: \(error.localizedDescription)")
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        Task { @MainActor in
            if let error {
                finishUpdateCheckIfNeeded()
                updateStatusText = updateStatusText(for: error)
                return
            }

            guard isCheckingForUpdates else { return }
            finishUpdateCheckIfNeeded()
            updateStatusText = "Update check finished."
        }
    }
}
