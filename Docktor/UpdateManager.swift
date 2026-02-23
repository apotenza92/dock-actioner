import Foundation
import Combine
import Sparkle

@MainActor
final class UpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdateManager()

    @Published private(set) var canCheckForUpdates = false

    private let preferences = Preferences.shared
    private var updateCheckTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var didConfigure = false

    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    private override init() {
        super.init()
    }

    func configureForLaunch(isAutomatedMode: Bool) {
        guard !didConfigure else { return }
        didConfigure = true

        guard !isAutomatedMode else {
            Logger.log("UpdateManager disabled in automated test mode")
            return
        }

        updaterController.startUpdater()
        bindUpdaterState()
        bindPreferences()
        performLaunchUpdateCheckIfNeeded()
        rescheduleAutomaticChecks()
    }

    func checkForUpdates() {
        guard didConfigure else { return }
        guard updaterController.updater.canCheckForUpdates else { return }
        preferences.markUpdateCheckNow()
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
            }
            .store(in: &cancellables)
    }

    private func performLaunchUpdateCheckIfNeeded() {
        guard preferences.shouldCheckForUpdatesOnLaunch() else { return }
        performBackgroundUpdateCheck()
    }

    private func rescheduleAutomaticChecks() {
        updateCheckTimer?.invalidate()
        updateCheckTimer = nil

        guard let interval = preferences.updateCheckFrequency.interval else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performBackgroundUpdateCheck()
            }
        }
        timer.tolerance = min(300, interval * 0.15)
        updateCheckTimer = timer
    }

    private func performBackgroundUpdateCheck() {
        guard updaterController.updater.canCheckForUpdates else { return }
        preferences.markUpdateCheckNow()
        updaterController.updater.checkForUpdatesInBackground()
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        let base = "https://raw.githubusercontent.com/apotenza92/docktor/main/appcasts"
        let channel = Self.isBetaBuild ? "beta" : "stable"
        let arch = Self.architectureSuffix
        return "\(base)/\(channel)-\(arch).xml"
    }

    nonisolated private static var isBetaBuild: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(".beta") == true
    }

    nonisolated private static var architectureSuffix: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }
}
