import Foundation
import Combine
import ServiceManagement

enum DockAction: String, CaseIterable, Codable {
    case none = "none"
    case hideApp = "hideApp"
    case appExpose = "appExpose"
    case minimizeAll = "minimizeAll"
    case quitApp = "quitApp"
    case bringAllToFront = "bringAllToFront"
    case hideOthers = "hideOthers"
    case singleAppMode = "singleAppMode"

    var displayName: String {
        switch self {
        case .none: return "-"
        case .hideApp: return "Hide App"
        case .appExpose: return "App Exposé"
        case .minimizeAll: return "Minimize All"
        case .quitApp: return "Quit App"
        case .bringAllToFront: return "Bring All to Front"
        case .hideOthers: return "Hide Others"
        case .singleAppMode: return "Single App Mode"
        }
    }
}

enum UpdateCheckFrequency: String, CaseIterable, Codable, Identifiable {
    case never
    case startup
    case hourly
    case sixHours
    case twelveHours
    case daily
    case weekly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .never:
            return "Never"
        case .startup:
            return "On Startup"
        case .hourly:
            return "Every Hour"
        case .sixHours:
            return "Every 6 Hours"
        case .twelveHours:
            return "Every 12 Hours"
        case .daily:
            return "Daily"
        case .weekly:
            return "Weekly"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .hourly:
            return 60 * 60
        case .sixHours:
            return 6 * 60 * 60
        case .twelveHours:
            return 12 * 60 * 60
        case .daily:
            return 24 * 60 * 60
        case .weekly:
            return 7 * 24 * 60 * 60
        case .never, .startup:
            return nil
        }
    }
}

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let userDefaults = UserDefaults.standard
    private let clickActionKey = "clickAction"
    private let shiftClickActionKey = "shiftClickAction"
    private let optionClickActionKey = "optionClickAction"
    private let shiftOptionClickActionKey = "shiftOptionClickAction"
    private let scrollUpActionKey = "scrollUpAction"
    private let shiftScrollUpActionKey = "shiftScrollUpAction"
    private let optionScrollUpActionKey = "optionScrollUpAction"
    private let shiftOptionScrollUpActionKey = "shiftOptionScrollUpAction"
    private let scrollDownActionKey = "scrollDownAction"
    private let shiftScrollDownActionKey = "shiftScrollDownAction"
    private let optionScrollDownActionKey = "optionScrollDownAction"
    private let shiftOptionScrollDownActionKey = "shiftOptionScrollDownAction"
    private let scrollDefaultsMigratedKey = "scrollDefaultsMigrated_v3"
    private let behaviorDefaultsMigratedKey = "behaviorDefaultsMigrated_v4"
    private let modifierDefaultsMigratedKey = "modifierDefaultsMigrated_v5"
    private let showOnStartupKey = "showOnStartup"
    private let firstLaunchCompletedKey = "firstLaunchCompleted"
    private let startAtLoginKey = "startAtLogin"
    private let updateCheckFrequencyKey = "updateCheckFrequency"
    private let lastUpdateCheckTimestampKey = "lastUpdateCheckTimestamp"

    // Prevent feedback loop when we adjust login item after a failed toggle.
    private var applyingLoginItemChange = false

    @Published var clickAction: DockAction {
        didSet {
            userDefaults.set(clickAction.rawValue, forKey: clickActionKey)
        }
    }

    @Published var shiftClickAction: DockAction {
        didSet {
            userDefaults.set(shiftClickAction.rawValue, forKey: shiftClickActionKey)
        }
    }

    @Published var optionClickAction: DockAction {
        didSet {
            userDefaults.set(optionClickAction.rawValue, forKey: optionClickActionKey)
        }
    }

    @Published var shiftOptionClickAction: DockAction {
        didSet {
            userDefaults.set(shiftOptionClickAction.rawValue, forKey: shiftOptionClickActionKey)
        }
    }

    @Published var scrollUpAction: DockAction {
        didSet {
            userDefaults.set(scrollUpAction.rawValue, forKey: scrollUpActionKey)
        }
    }

    @Published var shiftScrollUpAction: DockAction {
        didSet {
            userDefaults.set(shiftScrollUpAction.rawValue, forKey: shiftScrollUpActionKey)
        }
    }

    @Published var optionScrollUpAction: DockAction {
        didSet {
            userDefaults.set(optionScrollUpAction.rawValue, forKey: optionScrollUpActionKey)
        }
    }

    @Published var shiftOptionScrollUpAction: DockAction {
        didSet {
            userDefaults.set(shiftOptionScrollUpAction.rawValue, forKey: shiftOptionScrollUpActionKey)
        }
    }

    @Published var scrollDownAction: DockAction {
        didSet {
            userDefaults.set(scrollDownAction.rawValue, forKey: scrollDownActionKey)
        }
    }

    @Published var shiftScrollDownAction: DockAction {
        didSet {
            userDefaults.set(shiftScrollDownAction.rawValue, forKey: shiftScrollDownActionKey)
        }
    }

    @Published var optionScrollDownAction: DockAction {
        didSet {
            userDefaults.set(optionScrollDownAction.rawValue, forKey: optionScrollDownActionKey)
        }
    }

    @Published var shiftOptionScrollDownAction: DockAction {
        didSet {
            userDefaults.set(shiftOptionScrollDownAction.rawValue, forKey: shiftOptionScrollDownActionKey)
        }
    }

    @Published var showOnStartup: Bool {
        didSet {
            userDefaults.set(showOnStartup, forKey: showOnStartupKey)
        }
    }

    @Published var firstLaunchCompleted: Bool {
        didSet {
            userDefaults.set(firstLaunchCompleted, forKey: firstLaunchCompletedKey)
        }
    }

    @Published var startAtLogin: Bool {
        didSet {
            guard !applyingLoginItemChange else { return }
            applyingLoginItemChange = true
            do {
                if startAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                userDefaults.set(startAtLogin, forKey: startAtLoginKey)
            } catch {
                Logger.log("Failed to update login item state: \(error.localizedDescription)")
                // Revert to actual system state to keep UI truthful
                let enabled = SMAppService.mainApp.status == .enabled
                startAtLogin = enabled
                userDefaults.set(enabled, forKey: startAtLoginKey)
            }
            applyingLoginItemChange = false
        }
    }

    @Published var updateCheckFrequency: UpdateCheckFrequency {
        didSet {
            userDefaults.set(updateCheckFrequency.rawValue, forKey: updateCheckFrequencyKey)
        }
    }

    private init() {
        // Load base mappings from UserDefaults or use defaults.
        var clickAction: DockAction
        if let clickRaw = userDefaults.string(forKey: clickActionKey),
           let click = DockAction(rawValue: clickRaw) {
            clickAction = click
        } else {
            clickAction = .appExpose
        }

        var scrollUpAction: DockAction
        if let scrollUpRaw = userDefaults.string(forKey: scrollUpActionKey),
           let scrollUp = DockAction(rawValue: scrollUpRaw) {
            scrollUpAction = scrollUp
        } else {
            scrollUpAction = .hideOthers
        }

        var scrollDownAction: DockAction
        if let scrollDownRaw = userDefaults.string(forKey: scrollDownActionKey),
           let scrollDown = DockAction(rawValue: scrollDownRaw) {
            scrollDownAction = scrollDown
        } else {
            scrollDownAction = .hideApp
        }

        // One-time migration to move older defaults to current defaults.
        let migrated = userDefaults.bool(forKey: scrollDefaultsMigratedKey)
        if !migrated {
            // Legacy v1: minimizeAll up / appExpose down
            if scrollUpAction == .minimizeAll && scrollDownAction == .appExpose {
                scrollUpAction = .hideOthers
                scrollDownAction = .appExpose
                userDefaults.set(scrollUpAction.rawValue, forKey: scrollUpActionKey)
                userDefaults.set(scrollDownAction.rawValue, forKey: scrollDownActionKey)
            }

            // v2 default: appExpose up / minimizeAll down
            if scrollUpAction == .appExpose && scrollDownAction == .minimizeAll {
                scrollUpAction = .hideOthers
                scrollDownAction = .appExpose
                userDefaults.set(scrollUpAction.rawValue, forKey: scrollUpActionKey)
                userDefaults.set(scrollDownAction.rawValue, forKey: scrollDownActionKey)
            }

            userDefaults.set(true, forKey: scrollDefaultsMigratedKey)
        }

        // One-time migration to move prior default behavior to current defaults.
        let behaviorMigrated = userDefaults.bool(forKey: behaviorDefaultsMigratedKey)
        if !behaviorMigrated {
            let looksLikeLegacyDefaults = clickAction == .hideApp
                && scrollUpAction == .hideOthers
                && scrollDownAction == .appExpose

            if looksLikeLegacyDefaults {
                clickAction = .appExpose
                scrollDownAction = .hideApp
                userDefaults.set(clickAction.rawValue, forKey: clickActionKey)
                userDefaults.set(scrollDownAction.rawValue, forKey: scrollDownActionKey)
            }

            userDefaults.set(true, forKey: behaviorDefaultsMigratedKey)
        }

        // Extended modifier mappings.
        var shiftClickAction = Self.loadAction(from: userDefaults, forKey: shiftClickActionKey) ?? .bringAllToFront
        var optionClickAction = Self.loadAction(from: userDefaults, forKey: optionClickActionKey) ?? .singleAppMode
        var shiftOptionClickAction = Self.loadAction(from: userDefaults, forKey: shiftOptionClickActionKey) ?? .none

        var shiftScrollUpAction = Self.loadAction(from: userDefaults, forKey: shiftScrollUpActionKey) ?? .none
        var optionScrollUpAction = Self.loadAction(from: userDefaults, forKey: optionScrollUpActionKey) ?? .none
        var shiftOptionScrollUpAction = Self.loadAction(from: userDefaults, forKey: shiftOptionScrollUpActionKey) ?? .none

        var shiftScrollDownAction = Self.loadAction(from: userDefaults, forKey: shiftScrollDownActionKey) ?? .none
        var optionScrollDownAction = Self.loadAction(from: userDefaults, forKey: optionScrollDownActionKey) ?? .none
        var shiftOptionScrollDownAction = Self.loadAction(from: userDefaults, forKey: shiftOptionScrollDownActionKey) ?? .none

        let modifierMigrated = userDefaults.bool(forKey: modifierDefaultsMigratedKey)
        if !modifierMigrated {
            // Respect explicit values when present, otherwise seed new keys.
            if userDefaults.object(forKey: shiftClickActionKey) == nil {
                shiftClickAction = .bringAllToFront
            }
            if userDefaults.object(forKey: optionClickActionKey) == nil {
                optionClickAction = .singleAppMode
            }
            if userDefaults.object(forKey: shiftOptionClickActionKey) == nil {
                shiftOptionClickAction = .none
            }

            if userDefaults.object(forKey: shiftScrollUpActionKey) == nil {
                shiftScrollUpAction = .none
            }
            if userDefaults.object(forKey: optionScrollUpActionKey) == nil {
                optionScrollUpAction = .none
            }
            if userDefaults.object(forKey: shiftOptionScrollUpActionKey) == nil {
                shiftOptionScrollUpAction = .none
            }

            if userDefaults.object(forKey: shiftScrollDownActionKey) == nil {
                shiftScrollDownAction = .none
            }
            if userDefaults.object(forKey: optionScrollDownActionKey) == nil {
                optionScrollDownAction = .none
            }
            if userDefaults.object(forKey: shiftOptionScrollDownActionKey) == nil {
                shiftOptionScrollDownAction = .none
            }

            userDefaults.set(true, forKey: modifierDefaultsMigratedKey)
        }

        Self.seedIfMissing(shiftClickAction, in: userDefaults, forKey: shiftClickActionKey)
        Self.seedIfMissing(optionClickAction, in: userDefaults, forKey: optionClickActionKey)
        Self.seedIfMissing(shiftOptionClickAction, in: userDefaults, forKey: shiftOptionClickActionKey)
        Self.seedIfMissing(shiftScrollUpAction, in: userDefaults, forKey: shiftScrollUpActionKey)
        Self.seedIfMissing(optionScrollUpAction, in: userDefaults, forKey: optionScrollUpActionKey)
        Self.seedIfMissing(shiftOptionScrollUpAction, in: userDefaults, forKey: shiftOptionScrollUpActionKey)
        Self.seedIfMissing(shiftScrollDownAction, in: userDefaults, forKey: shiftScrollDownActionKey)
        Self.seedIfMissing(optionScrollDownAction, in: userDefaults, forKey: optionScrollDownActionKey)
        Self.seedIfMissing(shiftOptionScrollDownAction, in: userDefaults, forKey: shiftOptionScrollDownActionKey)

        // General settings defaults
        let showOnStartup = userDefaults.object(forKey: showOnStartupKey) as? Bool ?? false
        let firstLaunchCompleted = userDefaults.object(forKey: firstLaunchCompletedKey) as? Bool ?? false

        // Login item: prefer system status; fall back to stored preference
        let loginItemEnabled = SMAppService.mainApp.status == .enabled
        let startAtLogin: Bool
        if loginItemEnabled {
            startAtLogin = true
        } else {
            startAtLogin = userDefaults.object(forKey: startAtLoginKey) as? Bool ?? false
        }

        let updateCheckFrequency: UpdateCheckFrequency
        if let rawFrequency = userDefaults.string(forKey: updateCheckFrequencyKey),
           let frequency = UpdateCheckFrequency(rawValue: rawFrequency) {
            updateCheckFrequency = frequency
        } else {
            updateCheckFrequency = .daily
        }

        // Assign stored properties last
        self.clickAction = clickAction
        self.shiftClickAction = shiftClickAction
        self.optionClickAction = optionClickAction
        self.shiftOptionClickAction = shiftOptionClickAction
        self.scrollUpAction = scrollUpAction
        self.shiftScrollUpAction = shiftScrollUpAction
        self.optionScrollUpAction = optionScrollUpAction
        self.shiftOptionScrollUpAction = shiftOptionScrollUpAction
        self.scrollDownAction = scrollDownAction
        self.shiftScrollDownAction = shiftScrollDownAction
        self.optionScrollDownAction = optionScrollDownAction
        self.shiftOptionScrollDownAction = shiftOptionScrollDownAction
        self.showOnStartup = showOnStartup
        self.firstLaunchCompleted = firstLaunchCompleted
        self.startAtLogin = startAtLogin
        self.updateCheckFrequency = updateCheckFrequency
    }

    private static func loadAction(from defaults: UserDefaults, forKey key: String) -> DockAction? {
        guard let raw = defaults.string(forKey: key) else { return nil }
        return DockAction(rawValue: raw)
    }

    private static func seedIfMissing(_ action: DockAction, in defaults: UserDefaults, forKey key: String) {
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(action.rawValue, forKey: key)
    }

    func resetMappingsToDefaults() {
        clickAction = .appExpose
        shiftClickAction = .bringAllToFront
        optionClickAction = .singleAppMode
        shiftOptionClickAction = .none

        scrollUpAction = .hideOthers
        shiftScrollUpAction = .none
        optionScrollUpAction = .none
        shiftOptionScrollUpAction = .none

        scrollDownAction = .hideApp
        shiftScrollDownAction = .none
        optionScrollDownAction = .none
        shiftOptionScrollDownAction = .none
    }

    func markUpdateCheckNow(_ date: Date = Date()) {
        userDefaults.set(date.timeIntervalSince1970, forKey: lastUpdateCheckTimestampKey)
    }

    func shouldCheckForUpdatesOnLaunch(now: Date = Date()) -> Bool {
        switch updateCheckFrequency {
        case .never:
            return false
        case .startup:
            return true
        case .hourly, .sixHours, .twelveHours, .daily, .weekly:
            guard let interval = updateCheckFrequency.interval else { return false }
            guard let lastCheck = lastUpdateCheckDate() else { return true }
            return now.timeIntervalSince(lastCheck) >= interval
        }
    }

    private func lastUpdateCheckDate() -> Date? {
        let timestamp = userDefaults.double(forKey: lastUpdateCheckTimestampKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

}
