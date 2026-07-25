import Foundation

enum AppIdentity {
    enum RunningIdentity {
        case development
        case stable
        case beta
        case unknown
    }

    static let developmentBundleIdentifier = "pzc.Dockmint.dev"
    static let transitionStableBundleIdentifier = "pzc.Dockter"
    static let transitionBetaBundleIdentifier = "pzc.Dockter.beta"
    static let cleanupStableBundleIdentifier = "pzc.Dockmint"
    static let cleanupBetaBundleIdentifier = "pzc.Dockmint.beta"

    static let developmentBundleName = "Dockmint Dev.app"
    static let stableBundleName = "Dockmint.app"
    static let betaBundleName = "Dockmint Beta.app"

    static let developmentAppNames: Set<String> = [
        "Dockmint Dev",
    ]

    static let stableReleaseAppNames: Set<String> = [
        "Dockmint",
        "Docktor",
        "Dockter",
        "DockActioner",
    ]

    static let betaReleaseAppNames: Set<String> = [
        "Dockmint Beta",
        "Docktor Beta",
    ]

    static let legacyStableAppBundleNames: Set<String> = [
        "DockActioner.app",
        "Dockter.app",
        "Docktor.app",
    ]

    static let legacyBetaAppBundleNames: Set<String> = [
        "Docktor Beta.app",
    ]

    static let legacyAppBundleNames: Set<String> = legacyStableAppBundleNames.union(legacyBetaAppBundleNames)

    static let familyAppNames: Set<String> = developmentAppNames
        .union(stableReleaseAppNames)
        .union(betaReleaseAppNames)

    static let familyBundleIdentifiers: Set<String> = [
        developmentBundleIdentifier,
        transitionStableBundleIdentifier,
        transitionBetaBundleIdentifier,
        cleanupStableBundleIdentifier,
        cleanupBetaBundleIdentifier,
    ]

    static let currentURLScheme = "dockmint"
    static let developmentURLScheme = "dockmint-dev"
    static let legacyURLSchemes: Set<String> = ["docktor", "dockter"]
    static let currentOpenSettingsNotification = Notification.Name("pzc.Dockmint.openSettings")
    static let legacyOpenSettingsNotification = Notification.Name("pzc.Docktor.openSettings")

    private static let persistentStableLogDirectoryName = "Dockmint"
    private static let persistentBetaLogDirectoryName = "Dockmint Beta"
    private static let persistentDevelopmentLogDirectoryName = "Dockmint Dev"
    private static let obsoletePersistentLogRelativePaths = [
        "Code/Docktor/logs",
        "Code/Dockmint/logs",
    ]

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? ""
    }

    static var defaultsDomainName: String {
        defaultsDomainName(bundleIdentifier: bundleIdentifier)
    }

    static func defaultsDomainName(bundleIdentifier: String) -> String {
        bundleIdentifier
    }

    static var runningIdentity: RunningIdentity {
        runningIdentity(bundleIdentifier: bundleIdentifier)
    }

    static func runningIdentity(bundleIdentifier: String) -> RunningIdentity {
        switch bundleIdentifier {
        case developmentBundleIdentifier:
            return .development
        case cleanupBetaBundleIdentifier, transitionBetaBundleIdentifier:
            return .beta
        case cleanupStableBundleIdentifier, transitionStableBundleIdentifier:
            return .stable
        default:
            return .unknown
        }
    }

    static var isDevelopmentIdentity: Bool {
        isDevelopmentIdentity(bundleIdentifier: bundleIdentifier)
    }

    static func isDevelopmentIdentity(bundleIdentifier: String) -> Bool {
        bundleIdentifier == developmentBundleIdentifier
    }

    static var isBetaBuild: Bool {
        isBetaBuild(bundleIdentifier: bundleIdentifier)
    }

    static func isBetaBuild(bundleIdentifier: String) -> Bool {
        runningIdentity(bundleIdentifier: bundleIdentifier) == .beta
    }

    static var usesTransitionBundleIdentifier: Bool {
        usesTransitionBundleIdentifier(bundleIdentifier: bundleIdentifier)
    }

    static func usesTransitionBundleIdentifier(bundleIdentifier: String) -> Bool {
        bundleIdentifier == transitionStableBundleIdentifier || bundleIdentifier == transitionBetaBundleIdentifier
    }

    static var usesCleanupBundleIdentifier: Bool {
        usesCleanupBundleIdentifier(bundleIdentifier: bundleIdentifier)
    }

    static func usesCleanupBundleIdentifier(bundleIdentifier: String) -> Bool {
        bundleIdentifier == cleanupStableBundleIdentifier || bundleIdentifier == cleanupBetaBundleIdentifier
    }

    static var supportsUpdates: Bool {
        supportsUpdates(bundleIdentifier: bundleIdentifier)
    }

    static func supportsUpdates(bundleIdentifier: String) -> Bool {
        switch runningIdentity(bundleIdentifier: bundleIdentifier) {
        case .stable, .beta:
            return true
        case .development, .unknown:
            return false
        }
    }

    static var supportsLoginItem: Bool {
        supportsLoginItem(bundleIdentifier: bundleIdentifier)
    }

    static func supportsLoginItem(bundleIdentifier: String) -> Bool {
        switch runningIdentity(bundleIdentifier: bundleIdentifier) {
        case .stable, .beta:
            return true
        case .development, .unknown:
            return false
        }
    }

    static var supportsLegacyDefaultsMigration: Bool {
        supportsLegacyDefaultsMigration(bundleIdentifier: bundleIdentifier)
    }

    static func supportsLegacyDefaultsMigration(bundleIdentifier: String) -> Bool {
        usesCleanupBundleIdentifier(bundleIdentifier: bundleIdentifier)
    }

    static var canCoexistWithRelease: Bool {
        canCoexistWithRelease(bundleIdentifier: bundleIdentifier)
    }

    static func canCoexistWithRelease(bundleIdentifier: String) -> Bool {
        switch runningIdentity(bundleIdentifier: bundleIdentifier) {
        case .development, .beta:
            return true
        case .stable, .unknown:
            return false
        }
    }

    static var logDirectoryName: String {
        logDirectoryName(bundleIdentifier: bundleIdentifier)
    }

    static func logDirectoryName(bundleIdentifier: String) -> String {
        switch runningIdentity(bundleIdentifier: bundleIdentifier) {
        case .development:
            return persistentDevelopmentLogDirectoryName
        case .beta:
            return persistentBetaLogDirectoryName
        case .stable, .unknown:
            return persistentStableLogDirectoryName
        }
    }

    static var currentAppBundleName: String {
        currentAppBundleName(bundleIdentifier: bundleIdentifier)
    }

    static func currentAppBundleName(bundleIdentifier: String) -> String {
        switch runningIdentity(bundleIdentifier: bundleIdentifier) {
        case .development:
            return developmentBundleName
        case .beta:
            return betaBundleName
        case .stable, .unknown:
            return stableBundleName
        }
    }

    static var instanceBundleIdentifiers: Set<String> {
        instanceBundleIdentifiers(bundleIdentifier: bundleIdentifier)
    }

    static func instanceBundleIdentifiers(bundleIdentifier: String) -> Set<String> {
        switch runningIdentity(bundleIdentifier: bundleIdentifier) {
        case .development:
            return [developmentBundleIdentifier]
        case .stable:
            return [cleanupStableBundleIdentifier, transitionStableBundleIdentifier]
        case .beta:
            return [cleanupBetaBundleIdentifier, transitionBetaBundleIdentifier]
        case .unknown:
            return []
        }
    }

    static var instanceAppNames: Set<String> {
        instanceAppNames(bundleIdentifier: bundleIdentifier)
    }

    static func instanceAppNames(bundleIdentifier: String) -> Set<String> {
        switch runningIdentity(bundleIdentifier: bundleIdentifier) {
        case .development:
            return developmentAppNames
        case .stable:
            return stableReleaseAppNames
        case .beta:
            return betaReleaseAppNames
        case .unknown:
            return []
        }
    }

    static var instanceBundleNames: Set<String> {
        instanceBundleNames(bundleIdentifier: bundleIdentifier)
    }

    static func instanceBundleNames(bundleIdentifier: String) -> Set<String> {
        switch runningIdentity(bundleIdentifier: bundleIdentifier) {
        case .development:
            return [developmentBundleName]
        case .stable:
            return legacyStableAppBundleNames.union([stableBundleName])
        case .beta:
            return legacyBetaAppBundleNames.union([betaBundleName])
        case .unknown:
            return []
        }
    }

    static var preferredFeedRepository: String {
        usesTransitionBundleIdentifier ? "apotenza92/docktor" : "apotenza92/dockmint"
    }

    static func preferredFeedRepository(bundleIdentifier: String) -> String {
        usesTransitionBundleIdentifier(bundleIdentifier: bundleIdentifier) ? "apotenza92/docktor" : "apotenza92/dockmint"
    }

    static var preferredFeedBaseURL: String {
        preferredFeedBaseURL(bundleIdentifier: bundleIdentifier)
    }

    static func preferredFeedBaseURL(bundleIdentifier: String) -> String {
        "https://raw.githubusercontent.com/\(preferredFeedRepository(bundleIdentifier: bundleIdentifier))/main/appcasts"
    }

    static var settingsNotificationNames: [Notification.Name] {
        [currentOpenSettingsNotification, legacyOpenSettingsNotification]
    }

    static func supportedURLSchemes(bundleIdentifier: String = AppIdentity.bundleIdentifier) -> Set<String> {
        if isDevelopmentIdentity(bundleIdentifier: bundleIdentifier) {
            return [developmentURLScheme]
        }
        return legacyURLSchemes.union([currentURLScheme])
    }

    static func acceptsURLScheme(_ scheme: String, bundleIdentifier: String = AppIdentity.bundleIdentifier) -> Bool {
        supportedURLSchemes(bundleIdentifier: bundleIdentifier).contains(scheme.lowercased())
    }

    static func flagValue(primary: String, legacy: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let value = environment[primary], !value.isEmpty {
            return value
        }
        guard let legacy, let value = environment[legacy], !value.isEmpty else {
            return nil
        }
        return value
    }

    static func boolFlag(primary: String, legacy: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let value = flagValue(primary: primary, legacy: legacy, environment: environment)?.lowercased() else {
            return false
        }
        return value == "1" || value == "true" || value == "yes"
    }

    static var persistentLogDirectory: URL {
        let libraryDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return libraryDirectory
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(logDirectoryName, isDirectory: true)
    }

    static var obsoletePersistentLogDirectories: [URL] {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        return obsoletePersistentLogRelativePaths.map {
            homeDirectory.appendingPathComponent($0, isDirectory: true)
        }
    }
}
