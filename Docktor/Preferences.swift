import Foundation
import Combine
import ServiceManagement
import SwiftUI

enum DockAction: String, CaseIterable, Codable {
    case none = "none"
    case activateApp = "activateApp"
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
        case .activateApp: return "Activate App"
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

enum FirstClickBehavior: String, CaseIterable, Codable {
    case activateApp = "activateApp"
    case bringAllToFront = "bringAllToFront"
    case appExpose = "appExpose"

    var displayName: String {
        switch self {
        case .activateApp: return "Activate App"
        case .bringAllToFront: return "Bring All to Front"
        case .appExpose: return "App Exposé"
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

enum AppExposeSlotSource: String {
    case click
    case firstClick
    case scrollUp
    case scrollDown
}

enum AppExposeSlotModifier: String {
    case none
    case shift
    case option
    case shiftOption
}

enum AppExposeSlotKey {
    static func make(source: AppExposeSlotSource, modifier: AppExposeSlotModifier) -> String {
        make(source: source.rawValue, modifier: modifier.rawValue)
    }

    static func make(source: String, modifier: String) -> String {
        "\(source)_\(modifier)"
    }
}

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let userDefaults = UserDefaults.standard
    private let settingsStore: SettingsStore
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
    private let showMenuBarIconKey = "showMenuBarIcon"
    private let firstLaunchCompletedKey = "firstLaunchCompleted"
    private let startAtLoginKey = "startAtLogin"
    private let updateCheckFrequencyKey = "updateCheckFrequency"
    private let lastUpdateCheckTimestampKey = "lastUpdateCheckTimestamp"
    private let firstClickBehaviorKey = "firstClickBehavior"
    private let firstClickShiftActionKey = "firstClickShiftAction"
    private let firstClickOptionActionKey = "firstClickOptionAction"
    private let firstClickShiftOptionActionKey = "firstClickShiftOptionAction"
    private let firstClickAppExposeRequiresMultipleWindowsKey = "firstClickAppExposeRequiresMultipleWindows"
    private let clickAppExposeRequiresMultipleWindowsKey = "clickAppExposeRequiresMultipleWindows"
    private let appExposeRequiresMultipleWindowsMapKey = "appExposeRequiresMultipleWindowsMap"
    private let firstClickModifierActionsMigratedKey = "firstClickModifierActionsMigrated_v6"

    private static let showOnStartupPreferenceKey = PreferenceKey<Bool>(name: "showOnStartup", defaultValue: false)
    private static let showMenuBarIconPreferenceKey = PreferenceKey<Bool>(name: "showMenuBarIcon", defaultValue: true)
    private static let firstLaunchCompletedPreferenceKey = PreferenceKey<Bool>(name: "firstLaunchCompleted", defaultValue: false)
    private static let updateCheckFrequencyPreferenceKey = PreferenceKey<UpdateCheckFrequency>(name: "updateCheckFrequency", defaultValue: .daily)
    private static let firstClickBehaviorPreferenceKey = PreferenceKey<FirstClickBehavior>(name: "firstClickBehavior", defaultValue: .activateApp)
    private static let lastUpdateCheckTimestampPreferenceKey = PreferenceKey<Double>(name: "lastUpdateCheckTimestamp", defaultValue: 0)

    // Prevent feedback loop when we adjust login item after a failed toggle.
    private var applyingLoginItemChange = false

    @Published var clickAction: DockAction {
        didSet {
            userDefaults.set(clickAction.rawValue, forKey: clickActionKey)
        }
    }

    @Published var firstClickBehavior: FirstClickBehavior {
        didSet {
            settingsStore.set(firstClickBehavior, for: Self.firstClickBehaviorPreferenceKey)
        }
    }

    @Published var firstClickAppExposeRequiresMultipleWindows: Bool {
        didSet {
            userDefaults.set(firstClickAppExposeRequiresMultipleWindows, forKey: firstClickAppExposeRequiresMultipleWindowsKey)
        }
    }

    @Published var clickAppExposeRequiresMultipleWindows: Bool {
        didSet {
            userDefaults.set(clickAppExposeRequiresMultipleWindows, forKey: clickAppExposeRequiresMultipleWindowsKey)
        }
    }

    /// Per-slot ">1 window" gate for modifier rows and scroll rows.
    /// Keys follow the pattern "<source>_<modifier>", e.g. "firstClick_shift", "scrollUp_none".
    /// The no-modifier first-click and active-app-click slots are stored in their own legacy keys above.
    @Published var appExposeRequiresMultipleWindowsMap: [String: Bool] {
        didSet {
            userDefaults.set(appExposeRequiresMultipleWindowsMap, forKey: appExposeRequiresMultipleWindowsMapKey)
        }
    }

    func appExposeMultipleWindowsRequired(slot: String) -> Bool {
        appExposeRequiresMultipleWindowsMap[slot] ?? true
    }

    func appExposeMultipleWindowsBinding(slot: String) -> Binding<Bool> {
        Binding(
            get: { self.appExposeRequiresMultipleWindowsMap[slot] ?? true },
            set: { self.appExposeRequiresMultipleWindowsMap[slot] = $0 }
        )
    }

    @Published var firstClickShiftAction: DockAction {
        didSet {
            userDefaults.set(firstClickShiftAction.rawValue, forKey: firstClickShiftActionKey)
        }
    }

    @Published var firstClickOptionAction: DockAction {
        didSet {
            userDefaults.set(firstClickOptionAction.rawValue, forKey: firstClickOptionActionKey)
        }
    }

    @Published var firstClickShiftOptionAction: DockAction {
        didSet {
            userDefaults.set(firstClickShiftOptionAction.rawValue, forKey: firstClickShiftOptionActionKey)
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
            #if DEBUG
            if !showOnStartup {
                settingsStore.set(true, for: Self.showOnStartupPreferenceKey)
                showOnStartup = true
                Logger.log("Preferences: Forced showOnStartup on in development build")
                return
            }
            #endif
            settingsStore.set(showOnStartup, for: Self.showOnStartupPreferenceKey)
        }
    }

    @Published var showMenuBarIcon: Bool {
        didSet {
            #if DEBUG
            if !showMenuBarIcon {
                settingsStore.set(true, for: Self.showMenuBarIconPreferenceKey)
                showMenuBarIcon = true
                Logger.log("Preferences: Forced showMenuBarIcon on in development build")
                return
            }
            #endif
            settingsStore.set(showMenuBarIcon, for: Self.showMenuBarIconPreferenceKey)
        }
    }

    @Published var firstLaunchCompleted: Bool {
        didSet {
            settingsStore.set(firstLaunchCompleted, for: Self.firstLaunchCompletedPreferenceKey)
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
            settingsStore.set(updateCheckFrequency, for: Self.updateCheckFrequencyPreferenceKey)
        }
    }

    private init() {
        self.settingsStore = SettingsStore(defaults: UserDefaults.standard)

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

        var firstClickShiftAction = Self.loadAction(from: userDefaults, forKey: firstClickShiftActionKey) ?? .bringAllToFront
        var firstClickOptionAction = Self.loadAction(from: userDefaults, forKey: firstClickOptionActionKey) ?? .singleAppMode
        var firstClickShiftOptionAction = Self.loadAction(from: userDefaults, forKey: firstClickShiftOptionActionKey) ?? .none

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

        let firstClickModifierMigrated = userDefaults.bool(forKey: firstClickModifierActionsMigratedKey)
        if !firstClickModifierMigrated {
            firstClickShiftAction = shiftClickAction
            firstClickOptionAction = optionClickAction
            firstClickShiftOptionAction = shiftOptionClickAction

            shiftClickAction = .none
            optionClickAction = .none
            shiftOptionClickAction = .none

            userDefaults.set(firstClickShiftAction.rawValue, forKey: firstClickShiftActionKey)
            userDefaults.set(firstClickOptionAction.rawValue, forKey: firstClickOptionActionKey)
            userDefaults.set(firstClickShiftOptionAction.rawValue, forKey: firstClickShiftOptionActionKey)
            userDefaults.set(shiftClickAction.rawValue, forKey: shiftClickActionKey)
            userDefaults.set(optionClickAction.rawValue, forKey: optionClickActionKey)
            userDefaults.set(shiftOptionClickAction.rawValue, forKey: shiftOptionClickActionKey)
            userDefaults.set(true, forKey: firstClickModifierActionsMigratedKey)
        }

        Self.seedIfMissing(shiftClickAction, in: userDefaults, forKey: shiftClickActionKey)
        Self.seedIfMissing(optionClickAction, in: userDefaults, forKey: optionClickActionKey)
        Self.seedIfMissing(shiftOptionClickAction, in: userDefaults, forKey: shiftOptionClickActionKey)
        Self.seedIfMissing(firstClickShiftAction, in: userDefaults, forKey: firstClickShiftActionKey)
        Self.seedIfMissing(firstClickOptionAction, in: userDefaults, forKey: firstClickOptionActionKey)
        Self.seedIfMissing(firstClickShiftOptionAction, in: userDefaults, forKey: firstClickShiftOptionActionKey)
        Self.seedIfMissing(shiftScrollUpAction, in: userDefaults, forKey: shiftScrollUpActionKey)
        Self.seedIfMissing(optionScrollUpAction, in: userDefaults, forKey: optionScrollUpActionKey)
        Self.seedIfMissing(shiftOptionScrollUpAction, in: userDefaults, forKey: shiftOptionScrollUpActionKey)
        Self.seedIfMissing(shiftScrollDownAction, in: userDefaults, forKey: shiftScrollDownActionKey)
        Self.seedIfMissing(optionScrollDownAction, in: userDefaults, forKey: optionScrollDownActionKey)
        Self.seedIfMissing(shiftOptionScrollDownAction, in: userDefaults, forKey: shiftOptionScrollDownActionKey)

        // General settings defaults
        var showOnStartup = settingsStore.value(for: Self.showOnStartupPreferenceKey)
        var showMenuBarIcon = settingsStore.value(for: Self.showMenuBarIconPreferenceKey)
        #if DEBUG
        showOnStartup = true
        showMenuBarIcon = true
        settingsStore.set(true, for: Self.showOnStartupPreferenceKey)
        settingsStore.set(true, for: Self.showMenuBarIconPreferenceKey)
        #endif
        let firstLaunchCompleted = settingsStore.value(for: Self.firstLaunchCompletedPreferenceKey)

        // Login item: prefer system status; fall back to stored preference
        let loginItemEnabled = SMAppService.mainApp.status == .enabled
        let startAtLogin: Bool
        if loginItemEnabled {
            startAtLogin = true
        } else {
            startAtLogin = userDefaults.object(forKey: startAtLoginKey) as? Bool ?? false
        }

        let updateCheckFrequency = settingsStore.value(for: Self.updateCheckFrequencyPreferenceKey)

        let firstClickBehavior = settingsStore.value(for: Self.firstClickBehaviorPreferenceKey)

        let firstClickAppExposeRequiresMultipleWindows = userDefaults.object(forKey: firstClickAppExposeRequiresMultipleWindowsKey) as? Bool ?? true
        let clickAppExposeRequiresMultipleWindows = userDefaults.object(forKey: clickAppExposeRequiresMultipleWindowsKey) as? Bool ?? true
        let appExposeRequiresMultipleWindowsMap = userDefaults.object(forKey: appExposeRequiresMultipleWindowsMapKey) as? [String: Bool] ?? [:]

        // Assign stored properties last
        self.clickAction = clickAction
        self.firstClickBehavior = firstClickBehavior
        self.firstClickAppExposeRequiresMultipleWindows = firstClickAppExposeRequiresMultipleWindows
        self.clickAppExposeRequiresMultipleWindows = clickAppExposeRequiresMultipleWindows
        self.appExposeRequiresMultipleWindowsMap = appExposeRequiresMultipleWindowsMap
        self.firstClickShiftAction = firstClickShiftAction
        self.firstClickOptionAction = firstClickOptionAction
        self.firstClickShiftOptionAction = firstClickShiftOptionAction
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
        self.showMenuBarIcon = showMenuBarIcon
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
        firstClickBehavior = .activateApp
        firstClickAppExposeRequiresMultipleWindows = true
        clickAppExposeRequiresMultipleWindows = true
        appExposeRequiresMultipleWindowsMap = [:]

        firstClickShiftAction = .bringAllToFront
        firstClickOptionAction = .singleAppMode
        firstClickShiftOptionAction = .none

        shiftClickAction = .none
        optionClickAction = .none
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
        settingsStore.set(date.timeIntervalSince1970, for: Self.lastUpdateCheckTimestampPreferenceKey)
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
        let timestamp = settingsStore.value(for: Self.lastUpdateCheckTimestampPreferenceKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

}
