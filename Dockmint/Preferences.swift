import AppKit
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
        case .singleAppMode: return "Hide Current, Activate Clicked"
        }
    }
}

struct DockFolderOpenApplicationOption: Identifiable, Hashable {
    let identifier: String
    let displayName: String

    var id: String { identifier }
    var isFinder: Bool { identifier == DockFolderOpenApplicationCatalog.finderBundleIdentifier }

    static let none = DockFolderOpenApplicationOption(identifier: DockFolderOpenApplicationCatalog.noneIdentifier,
                                                      displayName: "-")
}

enum DockFolderOpenApplicationCatalog {
    static let noneIdentifier = "none"
    static let dockIdentifier = "dock"
    static let finderBundleIdentifier = "com.apple.finder"

    private static let additionalBundleIdentifiers = [
        finderBundleIdentifier,
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "com.github.wez.wezterm",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.microsoft.VSCode",
        "com.visualstudio.code.oss",
        "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed"
    ]

    @MainActor
    static func options(including selectedIdentifier: String? = nil) -> [DockFolderOpenApplicationOption] {
        DockFolderOpenApplicationOptionsCache.shared.options(including: selectedIdentifier)
    }

    @MainActor
    static func refreshOptionsCache() {
        DockFolderOpenApplicationOptionsCache.shared.refresh()
    }

    static func minimalOptions() -> [DockFolderOpenApplicationOption] {
        [
            .none,
            DockFolderOpenApplicationOption(identifier: dockIdentifier, displayName: "Dock"),
            DockFolderOpenApplicationOption(identifier: finderBundleIdentifier, displayName: "Finder")
        ]
    }

    static func placeholderOption(for identifier: String) -> DockFolderOpenApplicationOption {
        DockFolderOpenApplicationOption(
            identifier: normalize(identifier),
            displayName: "Missing App (\(normalize(identifier)))"
        )
    }

    fileprivate static func discoveredOptions() -> [DockFolderOpenApplicationOption] {
        var optionsByIdentifier: [String: DockFolderOpenApplicationOption] = Dictionary(
            uniqueKeysWithValues: minimalOptions().map { ($0.identifier, $0) }
        )

        for applicationURL in discoveredApplicationURLs() {
            guard let option = option(for: applicationURL) else { continue }
            optionsByIdentifier[option.identifier] = option
        }

        for bundleIdentifier in additionalBundleIdentifiers {
            guard let option = option(forBundleIdentifier: bundleIdentifier) else { continue }
            optionsByIdentifier[option.identifier] = option
        }

        let sortedApplications = optionsByIdentifier.values
            .filter { $0.identifier != noneIdentifier && $0.identifier != dockIdentifier }
            .sorted { lhs, rhs in
                if lhs.isFinder != rhs.isFinder {
                    return lhs.isFinder
                }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }

        return [
            .none,
            DockFolderOpenApplicationOption(identifier: dockIdentifier, displayName: "Dock")
        ] + sortedApplications
    }

    static func applicationURL(for identifier: String) -> URL? {
        let normalizedIdentifier = normalize(identifier)
        guard normalizedIdentifier != noneIdentifier, normalizedIdentifier != dockIdentifier else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: normalizedIdentifier)
    }

    static func isFinder(_ identifier: String) -> Bool {
        normalize(identifier) == finderBundleIdentifier
    }

    static func isDock(_ identifier: String) -> Bool {
        normalize(identifier) == dockIdentifier
    }

    static func normalize(_ identifier: String) -> String {
        switch identifier {
        case "", noneIdentifier:
            return noneIdentifier
        case dockIdentifier, "com.apple.dock":
            return dockIdentifier
        case "finder":
            return finderBundleIdentifier
        default:
            return identifier
        }
    }

    private static func discoveredApplicationURLs() -> [URL] {
        guard #available(macOS 12.0, *) else { return [] }
        let sampleFolderURL = FileManager.default.homeDirectoryForCurrentUser
        return NSWorkspace.shared.urlsForApplications(toOpen: sampleFolderURL)
    }

    private static func option(for applicationURL: URL) -> DockFolderOpenApplicationOption? {
        guard let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier else {
            return nil
        }
        return DockFolderOpenApplicationOption(identifier: bundleIdentifier,
                                               displayName: FileManager.default.displayName(atPath: applicationURL.path))
    }

    private static func option(forBundleIdentifier bundleIdentifier: String) -> DockFolderOpenApplicationOption? {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return DockFolderOpenApplicationOption(identifier: bundleIdentifier,
                                               displayName: FileManager.default.displayName(atPath: applicationURL.path))
    }
}

@MainActor
final class DockFolderOpenApplicationOptionsCache {
    static let shared = DockFolderOpenApplicationOptionsCache()

    private var cachedOptions: [DockFolderOpenApplicationOption]

    private init() {
        cachedOptions = DockFolderOpenApplicationCatalog.discoveredOptions()
    }

    func options(including selectedIdentifier: String? = nil) -> [DockFolderOpenApplicationOption] {
        let normalizedSelectedIdentifier = DockFolderOpenApplicationCatalog.normalize(
            selectedIdentifier ?? DockFolderOpenApplicationCatalog.noneIdentifier
        )
        guard normalizedSelectedIdentifier != DockFolderOpenApplicationCatalog.noneIdentifier,
              cachedOptions.contains(where: { $0.identifier == normalizedSelectedIdentifier }) == false else {
            return cachedOptions
        }

        var options = cachedOptions
        options.append(DockFolderOpenApplicationCatalog.placeholderOption(for: normalizedSelectedIdentifier))
        return options
    }

    func refresh() {
        cachedOptions = DockFolderOpenApplicationCatalog.discoveredOptions()
    }
}

enum DockFolderView: String, CaseIterable, Codable {
    case automatic
    case icon
    case list
    case column

    var displayName: String {
        switch self {
        case .automatic: return "System"
        case .icon: return "Icon"
        case .list: return "List"
        case .column: return "Column"
        }
    }
}

enum DockFolderSortBy: String, CaseIterable, Codable {
    case none
    case name
    case kind
    case dateLastOpened
    case dateAdded
    case dateModified
    case dateCreated
    case size
    case tags

    var displayName: String {
        switch self {
        case .none: return "Default"
        case .name: return "Name"
        case .kind: return "Kind"
        case .dateLastOpened: return "Date Last Opened"
        case .dateAdded: return "Date Added"
        case .dateModified: return "Date Modified"
        case .dateCreated: return "Date Created"
        case .size: return "Size"
        case .tags: return "Tags"
        }
    }
}

enum DockFolderGroupBy: String, CaseIterable, Codable {
    case none
    case name
    case kind
    case application
    case dateLastOpened
    case dateAdded
    case dateModified
    case dateCreated
    case size
    case tags

    var displayName: String {
        switch self {
        case .none: return "None"
        case .name: return "Name"
        case .kind: return "Kind"
        case .application: return "Application"
        case .dateLastOpened: return "Date Last Opened"
        case .dateAdded: return "Date Added"
        case .dateModified: return "Date Modified"
        case .dateCreated: return "Date Created"
        case .size: return "Size"
        case .tags: return "Tags"
        }
    }

    var defaultSortBy: DockFolderSortBy? {
        switch self {
        case .none:
            return nil
        case .name:
            return .name
        case .kind:
            return .kind
        case .application:
            return .name
        case .dateLastOpened:
            return .dateLastOpened
        case .dateAdded:
            return .dateAdded
        case .dateModified:
            return .dateModified
        case .dateCreated:
            return .dateCreated
        case .size:
            return .size
        case .tags:
            return .tags
        }
    }
}

enum DockFolderStackSortBy: String, CaseIterable, Codable {
    case current
    case name
    case dateAdded
    case dateModified
    case dateCreated
    case kind

    var displayName: String {
        switch self {
        case .current: return "Current"
        case .name: return "Name"
        case .dateAdded: return "Date Added"
        case .dateModified: return "Date Modified"
        case .dateCreated: return "Date Created"
        case .kind: return "Kind"
        }
    }
}

enum DockFolderStackDisplayAs: String, CaseIterable, Codable {
    case current
    case folder
    case stack

    var displayName: String {
        switch self {
        case .current: return "Current"
        case .folder: return "Folder"
        case .stack: return "Stack"
        }
    }
}

enum DockFolderStackViewContentAs: String, CaseIterable, Codable {
    case current
    case fan
    case grid
    case list
    case automatic

    var displayName: String {
        switch self {
        case .current: return "Current"
        case .fan: return "Fan"
        case .grid: return "Grid"
        case .list: return "List"
        case .automatic: return "Automatic"
        }
    }
}

struct DockFolderAction: Codable, Equatable {
    var openInApplicationIdentifier: String
    var view: DockFolderView
    var sortBy: DockFolderSortBy
    var groupBy: DockFolderGroupBy
    var dockSortBy: DockFolderStackSortBy
    var dockDisplayAs: DockFolderStackDisplayAs
    var dockViewContentAs: DockFolderStackViewContentAs

    static let none = DockFolderAction(openInApplicationIdentifier: DockFolderOpenApplicationCatalog.noneIdentifier,
                                       view: .automatic,
                                       sortBy: .none,
                                       groupBy: .none,
                                       dockSortBy: .current,
                                       dockDisplayAs: .current,
                                       dockViewContentAs: .current)

    var isConfigured: Bool {
        DockFolderOpenApplicationCatalog.normalize(openInApplicationIdentifier) != DockFolderOpenApplicationCatalog.noneIdentifier
    }

    var opensInFinder: Bool {
        DockFolderOpenApplicationCatalog.isFinder(openInApplicationIdentifier)
    }

    var opensInDock: Bool {
        DockFolderOpenApplicationCatalog.isDock(openInApplicationIdentifier)
    }

    var isFinderPassthrough: Bool {
        opensInFinder && view == .automatic
    }

    var appliesDockOverrides: Bool {
        dockSortBy != .current || dockDisplayAs != .current || dockViewContentAs != .current
    }

    var storageValue: String {
        "\(DockFolderOpenApplicationCatalog.normalize(openInApplicationIdentifier))|\(view.rawValue)|\(sortBy.rawValue)|\(groupBy.rawValue)|\(dockSortBy.rawValue)|\(dockDisplayAs.rawValue)|\(dockViewContentAs.rawValue)"
    }

    var debugName: String {
        if !isConfigured {
            return "none"
        }
        return storageValue
    }

    init(openInApplicationIdentifier: String,
         view: DockFolderView,
         sortBy: DockFolderSortBy,
         groupBy: DockFolderGroupBy = .none,
         dockSortBy: DockFolderStackSortBy = .current,
         dockDisplayAs: DockFolderStackDisplayAs = .current,
         dockViewContentAs: DockFolderStackViewContentAs = .current) {
        self.openInApplicationIdentifier = DockFolderOpenApplicationCatalog.normalize(openInApplicationIdentifier)
        self.view = view
        if view == .automatic {
            self.sortBy = .none
            self.groupBy = .none
        } else {
            self.sortBy = sortBy
            self.groupBy = groupBy
        }
        self.dockSortBy = dockSortBy
        self.dockDisplayAs = dockDisplayAs
        self.dockViewContentAs = dockViewContentAs
    }

    init(storageValue: String) {
        let parts = storageValue.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 7,
           let view = DockFolderView(rawValue: parts[1]),
           let sortBy = DockFolderSortBy(rawValue: parts[2]),
           let groupBy = DockFolderGroupBy(rawValue: parts[3]),
           let dockSortBy = DockFolderStackSortBy(rawValue: parts[4]),
           let dockDisplayAs = DockFolderStackDisplayAs(rawValue: parts[5]),
           let dockViewContentAs = DockFolderStackViewContentAs(rawValue: parts[6]) {
            self.init(openInApplicationIdentifier: DockFolderOpenApplicationCatalog.normalize(parts[0]),
                      view: view,
                      sortBy: sortBy,
                      groupBy: groupBy,
                      dockSortBy: dockSortBy,
                      dockDisplayAs: dockDisplayAs,
                      dockViewContentAs: dockViewContentAs)
            return
        }

        if parts.count == 4,
           let view = DockFolderView(rawValue: parts[1]),
           let sortBy = DockFolderSortBy(rawValue: parts[2]),
           let groupBy = DockFolderGroupBy(rawValue: parts[3]) {
            self.init(openInApplicationIdentifier: DockFolderOpenApplicationCatalog.normalize(parts[0]),
                      view: view,
                      sortBy: sortBy,
                      groupBy: groupBy,
                      dockSortBy: .current,
                      dockDisplayAs: .current,
                      dockViewContentAs: .current)
            return
        }

        if parts.count == 3,
           let view = DockFolderView(rawValue: parts[1]),
           let sortBy = DockFolderSortBy(rawValue: parts[2]) {
            self.init(openInApplicationIdentifier: DockFolderOpenApplicationCatalog.normalize(parts[0]),
                      view: view,
                      sortBy: sortBy,
                      groupBy: .none,
                      dockSortBy: .current,
                      dockDisplayAs: .current,
                      dockViewContentAs: .current)
            return
        }

        switch storageValue {
        case "openFolder":
            self.init(openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
                      view: .automatic,
                      sortBy: .none,
                      groupBy: .none)
        case "openFolderIconView":
            self.init(openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
                      view: .icon,
                      sortBy: .none,
                      groupBy: .none)
        case "openFolderListView":
            self.init(openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
                      view: .list,
                      sortBy: .none,
                      groupBy: .none)
        case "openFolderColumnView":
            self.init(openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
                      view: .column,
                      sortBy: .none,
                      groupBy: .none)
        case "openFolderSortByName":
            self.init(openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
                      view: .list,
                      sortBy: .name,
                      groupBy: .none)
        case "openFolderSortByDateModified":
            self.init(openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
                      view: .list,
                      sortBy: .dateModified,
                      groupBy: .none)
        default:
            self = .none
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
        case .bringAllToFront: return "Activate App"
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

enum OnboardingMilestone: String, CaseIterable, Codable, Identifiable {
    case notStarted
    case permissions
    case loginItem
    case privacy
    case tips
    case completed

    var id: String { rawValue }

    var isCompleted: Bool {
        self == .completed
    }

    var next: OnboardingMilestone {
        switch self {
        case .notStarted:
            return .permissions
        case .permissions:
            return .loginItem
        case .loginItem:
            return .privacy
        case .privacy:
            return .tips
        case .tips, .completed:
            return .completed
        }
    }

    var previous: OnboardingMilestone {
        switch self {
        case .notStarted, .permissions:
            return .notStarted
        case .loginItem:
            return .permissions
        case .privacy:
            return .loginItem
        case .tips:
            return .privacy
        case .completed:
            return .tips
        }
    }
}

struct MouseScrollDirectionTool: Equatable, Identifiable {
    let id: String
    let displayName: String
    let bundleIdentifier: String?
    let nameNeedle: String
}

enum MouseScrollDirectionToolDetector {
    static let knownTools: [MouseScrollDirectionTool] = [
        MouseScrollDirectionTool(id: "linearmouse", displayName: "LinearMouse", bundleIdentifier: "com.lujjjh.LinearMouse", nameNeedle: "linearmouse"),
        MouseScrollDirectionTool(id: "mos", displayName: "Mos", bundleIdentifier: "com.caldis.Mos", nameNeedle: "mos"),
        MouseScrollDirectionTool(id: "unnaturalscrollwheels", displayName: "UnnaturalScrollWheels", bundleIdentifier: nil, nameNeedle: "unnaturalscrollwheels"),
    ]

    static func detectedTools(workspace: NSWorkspace = .shared) -> [MouseScrollDirectionTool] {
        let runningApplications = workspace.runningApplications
        return knownTools.filter { tool in
            runningApplications.contains { app in
                let bundle = app.bundleIdentifier?.lowercased() ?? ""
                let name = app.localizedName?.lowercased() ?? ""
                return bundle.contains(tool.nameNeedle) || name.contains(tool.nameNeedle)
            }
            || tool.bundleIdentifier.map { workspace.urlForApplication(withBundleIdentifier: $0) != nil } == true
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
    struct LoginItemClient {
        var status: () -> SMAppService.Status
        var register: () throws -> Void
        var unregister: () throws -> Void

        static let live = LoginItemClient(
            status: { SMAppService.mainApp.status },
            register: { try SMAppService.mainApp.register() },
            unregister: { try SMAppService.mainApp.unregister() }
        )
    }

    static let shared = Preferences()

    private let userDefaults: UserDefaults
    private let settingsStore: SettingsStore
    private let bundleIdentifier: String
    private let loginItemClient: LoginItemClient
    private let loginItemRepairKey = "dockmintLoginItemRepairAttempted_v1"
    private let clickActionKey = "clickAction"
    private let shiftClickActionKey = "shiftClickAction"
    private let optionClickActionKey = "optionClickAction"
    private let shiftOptionClickActionKey = "shiftOptionClickAction"
    private let scrollUpActionKey = "scrollUpAction"
    private let shiftScrollUpActionKey = "shiftScrollUpAction"
    private let optionScrollUpActionKey = "optionScrollUpAction"
    private let shiftOptionScrollUpActionKey = "shiftOptionScrollUpAction"
    private let scrollDownActionKey = "scrollDownAction"
    private let reverseMouseScrollActionsKey = "invertDiscreteScrollDirection"
    private let dismissedMouseScrollToolSuggestionIDsKey = "dismissedMouseScrollToolSuggestionIDs"
    private let seenMouseScrollToolSuggestionIDsKey = "seenMouseScrollToolSuggestionIDs"
    private let shiftScrollDownActionKey = "shiftScrollDownAction"
    private let optionScrollDownActionKey = "optionScrollDownAction"
    private let shiftOptionScrollDownActionKey = "shiftOptionScrollDownAction"
    private let folderClickActionKey = "folderClickAction"
    private let shiftFolderClickActionKey = "shiftFolderClickAction"
    private let optionFolderClickActionKey = "optionFolderClickAction"
    private let shiftOptionFolderClickActionKey = "shiftOptionFolderClickAction"
    private let folderScrollUpActionKey = "folderScrollUpAction"
    private let shiftFolderScrollUpActionKey = "shiftFolderScrollUpAction"
    private let optionFolderScrollUpActionKey = "optionFolderScrollUpAction"
    private let shiftOptionFolderScrollUpActionKey = "shiftOptionFolderScrollUpAction"
    private let folderScrollDownActionKey = "folderScrollDownAction"
    private let shiftFolderScrollDownActionKey = "shiftFolderScrollDownAction"
    private let optionFolderScrollDownActionKey = "optionFolderScrollDownAction"
    private let shiftOptionFolderScrollDownActionKey = "shiftOptionFolderScrollDownAction"
    private let scrollDefaultsMigratedKey = "scrollDefaultsMigrated_v3"
    private let behaviorDefaultsMigratedKey = "behaviorDefaultsMigrated_v4"
    private let modifierDefaultsMigratedKey = "modifierDefaultsMigrated_v5"
    private let showOnStartupKey = "showOnStartup"
    private let showMenuBarIconKey = "showMenuBarIcon"
    private let firstLaunchCompletedKey = "firstLaunchCompleted"
    private let onboardingStateKey = "onboardingState"
    private let startAtLoginKey = "startAtLogin"
    private let backgroundUpdateChecksEnabledKey = "backgroundUpdateChecksEnabled"
    private let updateCheckFrequencyKey = "updateCheckFrequency"
    private let persistentDiagnosticFileLoggingEnabledKey = "persistentDiagnosticFileLoggingEnabled"
    private let lastUpdateCheckTimestampKey = "lastUpdateCheckTimestamp"
    private let onboardingPrivacyMigrationKey = "onboardingPrivacyMigration_v1"
    private let firstClickBehaviorKey = "firstClickBehavior"
    private let firstClickShiftActionKey = "firstClickShiftAction"
    private let firstClickOptionActionKey = "firstClickOptionAction"
    private let firstClickShiftOptionActionKey = "firstClickShiftOptionAction"
    private let firstClickAppExposeRequiresMultipleWindowsKey = "firstClickAppExposeRequiresMultipleWindows"
    private let clickAppExposeRequiresMultipleWindowsKey = "clickAppExposeRequiresMultipleWindows"
    private let appExposeRequiresMultipleWindowsMapKey = "appExposeRequiresMultipleWindowsMap"
    private let firstClickModifierActionsMigratedKey = "firstClickModifierActionsMigrated_v6"
    private let appExposeRequiresMultipleWindowsMapMigratedKey = "appExposeRequiresMultipleWindowsMapMigrated_v7"
    private let folderClickDefaultMigratedKey = "folderClickDefaultMigrated_v8"
    private let deprecatedBringAllToFrontMigratedKey = "deprecatedBringAllToFrontMigrated_v9"
    private let obsoleteAppClickActionsMigratedKey = "obsoleteAppClickActionsMigrated_v10"

    struct GeneralDefaults {
        let showMenuBarIcon: Bool
        let showOnStartup: Bool
        let firstLaunchCompleted: Bool
        let onboardingState: OnboardingMilestone
        let backgroundUpdateChecksEnabled: Bool
        let updateCheckFrequency: UpdateCheckFrequency
        let persistentDiagnosticFileLoggingEnabled: Bool
    }

    struct AppActionDefaults {
        let firstClickBehavior: FirstClickBehavior
        let clickAction: DockAction
        let firstClickAppExposeRequiresMultipleWindows: Bool
        let clickAppExposeRequiresMultipleWindows: Bool
        let appExposeRequiresMultipleWindowsMap: [String: Bool]
    }

    struct ModifierDefaults {
        let firstClickShiftAction: DockAction
        let firstClickOptionAction: DockAction
        let firstClickShiftOptionAction: DockAction
        let shiftClickAction: DockAction
        let optionClickAction: DockAction
        let shiftOptionClickAction: DockAction
        let scrollUpAction: DockAction
        let shiftScrollUpAction: DockAction
        let optionScrollUpAction: DockAction
        let shiftOptionScrollUpAction: DockAction
        let scrollDownAction: DockAction
        let shiftScrollDownAction: DockAction
        let optionScrollDownAction: DockAction
        let shiftOptionScrollDownAction: DockAction
    }

    struct FolderDefaults {
        let click: DockFolderAction
        let shiftClick: DockFolderAction
        let optionClick: DockFolderAction
        let shiftOptionClick: DockFolderAction
        let scrollUp: DockFolderAction
        let shiftScrollUp: DockFolderAction
        let optionScrollUp: DockFolderAction
        let shiftOptionScrollUp: DockFolderAction
        let scrollDown: DockFolderAction
        let shiftScrollDown: DockFolderAction
        let optionScrollDown: DockFolderAction
        let shiftOptionScrollDown: DockFolderAction
    }

    static let shippedGeneralDefaults = GeneralDefaults(
        showMenuBarIcon: true,
        showOnStartup: false,
        firstLaunchCompleted: false,
        onboardingState: .notStarted,
        backgroundUpdateChecksEnabled: true,
        updateCheckFrequency: .weekly,
        persistentDiagnosticFileLoggingEnabled: false
    )

    static let shippedAppActionDefaults = AppActionDefaults(
        firstClickBehavior: .appExpose,
        clickAction: .none,
        firstClickAppExposeRequiresMultipleWindows: true,
        clickAppExposeRequiresMultipleWindows: false,
        appExposeRequiresMultipleWindowsMap: Preferences.defaultAppExposeRequiresMultipleWindowsMap(
            firstClickDefault: true,
            activeAppDefault: false
        )
    )

    static let shippedModifierDefaults = ModifierDefaults(
        firstClickShiftAction: .hideOthers,
        firstClickOptionAction: .singleAppMode,
        firstClickShiftOptionAction: .quitApp,
        shiftClickAction: .none,
        optionClickAction: .none,
        shiftOptionClickAction: .none,
        scrollUpAction: .appExpose,
        shiftScrollUpAction: .none,
        optionScrollUpAction: .none,
        shiftOptionScrollUpAction: .none,
        scrollDownAction: .appExpose,
        shiftScrollDownAction: .none,
        optionScrollDownAction: .none,
        shiftOptionScrollDownAction: .none
    )

    static let shippedFolderDefaults = FolderDefaults(
        click: DockFolderAction(
            openInApplicationIdentifier: DockFolderOpenApplicationCatalog.dockIdentifier,
            view: .automatic,
            sortBy: .none,
            groupBy: .none
        ),
        shiftClick: .none,
        optionClick: DockFolderAction(
            openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
            view: .automatic,
            sortBy: .none,
            groupBy: .none
        ),
        shiftOptionClick: .none,
        scrollUp: .none,
        shiftScrollUp: .none,
        optionScrollUp: .none,
        shiftOptionScrollUp: .none,
        scrollDown: .none,
        shiftScrollDown: .none,
        optionScrollDown: .none,
        shiftOptionScrollDown: .none
    )

    static let defaultFolderClickAction = shippedFolderDefaults.click

    private static let legacyDefaultFolderClickAction = defaultFolderClickAction

    private static let showOnStartupPreferenceKey = PreferenceKey<Bool>(
        name: "showOnStartup",
        defaultValue: shippedGeneralDefaults.showOnStartup
    )
    private static let showMenuBarIconPreferenceKey = PreferenceKey<Bool>(
        name: "showMenuBarIcon",
        defaultValue: shippedGeneralDefaults.showMenuBarIcon
    )
    private static let firstLaunchCompletedPreferenceKey = PreferenceKey<Bool>(
        name: "firstLaunchCompleted",
        defaultValue: shippedGeneralDefaults.firstLaunchCompleted
    )
    private static let onboardingStatePreferenceKey = PreferenceKey<OnboardingMilestone>(
        name: "onboardingState",
        defaultValue: shippedGeneralDefaults.onboardingState
    )
    private static let backgroundUpdateChecksEnabledPreferenceKey = PreferenceKey<Bool>(
        name: "backgroundUpdateChecksEnabled",
        defaultValue: shippedGeneralDefaults.backgroundUpdateChecksEnabled
    )
    private static let updateCheckFrequencyPreferenceKey = PreferenceKey<UpdateCheckFrequency>(
        name: "updateCheckFrequency",
        defaultValue: shippedGeneralDefaults.updateCheckFrequency
    )
    private static let persistentDiagnosticFileLoggingEnabledPreferenceKey = PreferenceKey<Bool>(
        name: "persistentDiagnosticFileLoggingEnabled",
        defaultValue: shippedGeneralDefaults.persistentDiagnosticFileLoggingEnabled
    )
    private static let firstClickBehaviorPreferenceKey = PreferenceKey<FirstClickBehavior>(
        name: "firstClickBehavior",
        defaultValue: shippedAppActionDefaults.firstClickBehavior
    )
    private static let lastUpdateCheckTimestampPreferenceKey = PreferenceKey<Double>(name: "lastUpdateCheckTimestamp", defaultValue: 0)

    // Prevent feedback loop when we adjust login item after a failed toggle.
    private var applyingLoginItemChange = false

    private static var isAutomatedTestSuite: Bool {
        AppIdentity.boolFlag(primary: "DOCKMINT_TEST_SUITE", legacy: "DOCKTOR_TEST_SUITE")
    }

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
    /// The no-modifier first-click slot still uses its dedicated legacy key above; obsolete app-click
    /// slots are retained only for migration/reset cleanup compatibility.
    @Published var appExposeRequiresMultipleWindowsMap: [String: Bool] {
        didSet {
            userDefaults.set(appExposeRequiresMultipleWindowsMap, forKey: appExposeRequiresMultipleWindowsMapKey)
        }
    }

    func appExposeMultipleWindowsRequired(slot: String) -> Bool {
        appExposeRequiresMultipleWindowsMap[slot] ?? legacyAppExposeMultipleWindowsDefault(forSlot: slot)
    }

    func appExposeMultipleWindowsBinding(slot: String) -> Binding<Bool> {
        Binding(
            get: { self.appExposeRequiresMultipleWindowsMap[slot] ?? self.legacyAppExposeMultipleWindowsDefault(forSlot: slot) },
            set: { self.appExposeRequiresMultipleWindowsMap[slot] = $0 }
        )
    }

    private func legacyAppExposeMultipleWindowsDefault(forSlot slot: String) -> Bool {
        if slot.hasPrefix("\(AppExposeSlotSource.firstClick.rawValue)_") {
            return firstClickAppExposeRequiresMultipleWindows
        }
        return clickAppExposeRequiresMultipleWindows
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

    @Published var folderClickAction: DockFolderAction {
        didSet {
            userDefaults.set(folderClickAction.storageValue, forKey: folderClickActionKey)
        }
    }

    @Published var shiftFolderClickAction: DockFolderAction {
        didSet {
            userDefaults.set(shiftFolderClickAction.storageValue, forKey: shiftFolderClickActionKey)
        }
    }

    @Published var optionFolderClickAction: DockFolderAction {
        didSet {
            userDefaults.set(optionFolderClickAction.storageValue, forKey: optionFolderClickActionKey)
        }
    }

    @Published var shiftOptionFolderClickAction: DockFolderAction {
        didSet {
            userDefaults.set(shiftOptionFolderClickAction.storageValue, forKey: shiftOptionFolderClickActionKey)
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

    @Published var folderScrollUpAction: DockFolderAction {
        didSet {
            userDefaults.set(folderScrollUpAction.storageValue, forKey: folderScrollUpActionKey)
        }
    }

    @Published var shiftFolderScrollUpAction: DockFolderAction {
        didSet {
            userDefaults.set(shiftFolderScrollUpAction.storageValue, forKey: shiftFolderScrollUpActionKey)
        }
    }

    @Published var optionFolderScrollUpAction: DockFolderAction {
        didSet {
            userDefaults.set(optionFolderScrollUpAction.storageValue, forKey: optionFolderScrollUpActionKey)
        }
    }

    @Published var shiftOptionFolderScrollUpAction: DockFolderAction {
        didSet {
            userDefaults.set(shiftOptionFolderScrollUpAction.storageValue, forKey: shiftOptionFolderScrollUpActionKey)
        }
    }

    @Published var scrollDownAction: DockAction {
        didSet {
            userDefaults.set(scrollDownAction.rawValue, forKey: scrollDownActionKey)
        }
    }

    @Published var reverseMouseScrollActions: Bool {
        didSet {
            userDefaults.set(reverseMouseScrollActions, forKey: reverseMouseScrollActionsKey)
        }
    }

    @Published private(set) var dismissedMouseScrollToolSuggestionIDs: Set<String> {
        didSet {
            userDefaults.set(Array(dismissedMouseScrollToolSuggestionIDs).sorted(), forKey: dismissedMouseScrollToolSuggestionIDsKey)
        }
    }

    @Published private(set) var seenMouseScrollToolSuggestionIDs: Set<String> {
        didSet {
            userDefaults.set(Array(seenMouseScrollToolSuggestionIDs).sorted(), forKey: seenMouseScrollToolSuggestionIDsKey)
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

    @Published var folderScrollDownAction: DockFolderAction {
        didSet {
            userDefaults.set(folderScrollDownAction.storageValue, forKey: folderScrollDownActionKey)
        }
    }

    @Published var shiftFolderScrollDownAction: DockFolderAction {
        didSet {
            userDefaults.set(shiftFolderScrollDownAction.storageValue, forKey: shiftFolderScrollDownActionKey)
        }
    }

    @Published var optionFolderScrollDownAction: DockFolderAction {
        didSet {
            userDefaults.set(optionFolderScrollDownAction.storageValue, forKey: optionFolderScrollDownActionKey)
        }
    }

    @Published var shiftOptionFolderScrollDownAction: DockFolderAction {
        didSet {
            userDefaults.set(shiftOptionFolderScrollDownAction.storageValue, forKey: shiftOptionFolderScrollDownActionKey)
        }
    }

    @Published var showOnStartup: Bool {
        didSet {
            settingsStore.set(showOnStartup, for: Self.showOnStartupPreferenceKey)
        }
    }

    @Published var showMenuBarIcon: Bool {
        didSet {
            settingsStore.set(showMenuBarIcon, for: Self.showMenuBarIconPreferenceKey)
        }
    }

    @Published var firstLaunchCompleted: Bool {
        didSet {
            settingsStore.set(firstLaunchCompleted, for: Self.firstLaunchCompletedPreferenceKey)
        }
    }

    @Published var onboardingState: OnboardingMilestone {
        didSet {
            settingsStore.set(onboardingState, for: Self.onboardingStatePreferenceKey)
            if onboardingState.isCompleted && !firstLaunchCompleted {
                firstLaunchCompleted = true
            }
        }
    }

    @Published var backgroundUpdateChecksEnabled: Bool {
        didSet {
            settingsStore.set(backgroundUpdateChecksEnabled, for: Self.backgroundUpdateChecksEnabledPreferenceKey)
            if backgroundUpdateChecksEnabled && updateCheckFrequency == .never {
                updateCheckFrequency = .weekly
            }
            if !backgroundUpdateChecksEnabled && updateCheckFrequency != .never {
                updateCheckFrequency = .never
            }
        }
    }

    @Published var startAtLogin: Bool {
        didSet {
            guard !applyingLoginItemChange else { return }

            guard AppIdentity.supportsLoginItem(bundleIdentifier: bundleIdentifier) else {
                if startAtLogin {
                    applyingLoginItemChange = true
                    startAtLogin = false
                    applyingLoginItemChange = false
                }
                userDefaults.set(false, forKey: startAtLoginKey)
                return
            }

            applyingLoginItemChange = true
            defer { applyingLoginItemChange = false }

            do {
                if startAtLogin {
                    try loginItemClient.register()
                } else {
                    try loginItemClient.unregister()
                }
                userDefaults.set(startAtLogin, forKey: startAtLoginKey)
            } catch {
                Logger.log("Failed to update login item state: \(error.localizedDescription)")
                // Revert to actual system state to keep UI truthful
                let enabled = loginItemClient.status() == .enabled
                startAtLogin = enabled
                userDefaults.set(enabled, forKey: startAtLoginKey)
            }
        }
    }

    @Published var updateCheckFrequency: UpdateCheckFrequency {
        didSet {
            settingsStore.set(updateCheckFrequency, for: Self.updateCheckFrequencyPreferenceKey)
            if updateCheckFrequency == .never {
                if backgroundUpdateChecksEnabled {
                    backgroundUpdateChecksEnabled = false
                }
            } else if !backgroundUpdateChecksEnabled {
                backgroundUpdateChecksEnabled = true
            }
        }
    }

    @Published var persistentDiagnosticFileLoggingEnabled: Bool {
        didSet {
            settingsStore.set(
                persistentDiagnosticFileLoggingEnabled,
                for: Self.persistentDiagnosticFileLoggingEnabledPreferenceKey
            )
        }
    }

    var isOnboardingCompleted: Bool {
        onboardingState.isCompleted
    }

    var shouldPresentOnboarding: Bool {
        !isOnboardingCompleted
    }

    func shouldSuggestReverseMouseScrollDuringOnboarding(for tool: MouseScrollDirectionTool) -> Bool {
        !reverseMouseScrollActions && !dismissedMouseScrollToolSuggestionIDs.contains(tool.id)
    }

    func shouldSuggestReverseMouseScrollAfterOnboarding(for tool: MouseScrollDirectionTool) -> Bool {
        !reverseMouseScrollActions
            && !dismissedMouseScrollToolSuggestionIDs.contains(tool.id)
            && !seenMouseScrollToolSuggestionIDs.contains(tool.id)
    }

    func markMouseScrollToolSuggestionSeen(for tool: MouseScrollDirectionTool) {
        seenMouseScrollToolSuggestionIDs.insert(tool.id)
    }

    func dismissMouseScrollToolSuggestion(for tool: MouseScrollDirectionTool) {
        dismissedMouseScrollToolSuggestionIDs.insert(tool.id)
        seenMouseScrollToolSuggestionIDs.insert(tool.id)
    }

    func enableReverseMouseScrollActionsFromSuggestion(for tool: MouseScrollDirectionTool) {
        markMouseScrollToolSuggestionSeen(for: tool)
        reverseMouseScrollActions = true
    }

    private init(userDefaults: UserDefaults = .standard,
                 settingsStore: SettingsStore? = nil,
                 applyLoginItemRepair: Bool = true,
                 bundleIdentifier: String? = nil,
                 loginItemClient: LoginItemClient? = nil) {
        let resolvedBundleIdentifier = bundleIdentifier ?? AppIdentity.bundleIdentifier
        let resolvedLoginItemClient = loginItemClient ?? .live

        self.userDefaults = userDefaults
        self.bundleIdentifier = resolvedBundleIdentifier
        self.loginItemClient = resolvedLoginItemClient
        Self.migrateLegacyDefaultsDomainIfNeeded(defaults: userDefaults, bundleIdentifier: resolvedBundleIdentifier)
        self.settingsStore = settingsStore ?? SettingsStore(defaults: userDefaults,
                                                            defaultsDomainName: SettingsStore.defaultsDomainName(for: resolvedBundleIdentifier))
        Self.applyFolderClickDefaultMigrationIfNeeded(defaults: userDefaults,
                                                      migrationKey: folderClickDefaultMigratedKey,
                                                      actionKey: folderClickActionKey)

        let generalDefaults = Self.shippedGeneralDefaults
        let appActionDefaults = Self.shippedAppActionDefaults
        let modifierDefaults = Self.shippedModifierDefaults
        let folderDefaults = Self.shippedFolderDefaults

        if !userDefaults.bool(forKey: onboardingPrivacyMigrationKey) {
            let legacyFirstLaunchCompleted = userDefaults.object(forKey: firstLaunchCompletedKey) as? Bool
            let hasStoredOnboardingState = userDefaults.object(forKey: onboardingStateKey) != nil
            if !hasStoredOnboardingState {
                let migratedOnboardingState: OnboardingMilestone = legacyFirstLaunchCompleted == true
                    ? .completed
                    : generalDefaults.onboardingState
                userDefaults.set(migratedOnboardingState.rawValue, forKey: onboardingStateKey)
            }

            let storedUpdateFrequencyRaw = userDefaults.string(forKey: updateCheckFrequencyKey)
            let storedUpdateFrequency = storedUpdateFrequencyRaw.flatMap(UpdateCheckFrequency.init(rawValue:))
            let hasStoredUpdateConsent = userDefaults.object(forKey: backgroundUpdateChecksEnabledKey) != nil
            if !hasStoredUpdateConsent {
                let migratedUpdateConsent: Bool
                let migratedUpdateFrequency: UpdateCheckFrequency

                switch storedUpdateFrequency {
                case .some(.weekly):
                    // Legacy `.weekly` was the shipped default before update checks became opt-in.
                    // Treat that exact value as untouched legacy default and move the user to opt-in mode.
                    migratedUpdateConsent = false
                    migratedUpdateFrequency = .never
                case .some(.never):
                    migratedUpdateConsent = false
                    migratedUpdateFrequency = .never
                case .some(let explicitFrequency):
                    migratedUpdateConsent = true
                    migratedUpdateFrequency = explicitFrequency
                case .none:
                    migratedUpdateConsent = generalDefaults.backgroundUpdateChecksEnabled
                    migratedUpdateFrequency = generalDefaults.updateCheckFrequency
                }

                userDefaults.set(migratedUpdateConsent, forKey: backgroundUpdateChecksEnabledKey)
                userDefaults.set(migratedUpdateFrequency.rawValue, forKey: updateCheckFrequencyKey)
            }

            if userDefaults.object(forKey: persistentDiagnosticFileLoggingEnabledKey) == nil {
                userDefaults.set(
                    generalDefaults.persistentDiagnosticFileLoggingEnabled,
                    forKey: persistentDiagnosticFileLoggingEnabledKey
                )
            }

            userDefaults.set(true, forKey: onboardingPrivacyMigrationKey)
        }

        let deprecatedBringAllToFrontMigrated = userDefaults.bool(forKey: deprecatedBringAllToFrontMigratedKey)
        if !deprecatedBringAllToFrontMigrated {
            let actionKeys = [
                clickActionKey,
                scrollUpActionKey,
                scrollDownActionKey,
                shiftClickActionKey,
                optionClickActionKey,
                shiftOptionClickActionKey,
                firstClickShiftActionKey,
                firstClickOptionActionKey,
                firstClickShiftOptionActionKey,
                shiftScrollUpActionKey,
                optionScrollUpActionKey,
                shiftOptionScrollUpActionKey,
                shiftScrollDownActionKey,
                optionScrollDownActionKey,
                shiftOptionScrollDownActionKey,
            ]

            for key in actionKeys where userDefaults.string(forKey: key) == DockAction.bringAllToFront.rawValue {
                userDefaults.set(DockAction.activateApp.rawValue, forKey: key)
            }

            if userDefaults.string(forKey: firstClickBehaviorKey) == FirstClickBehavior.bringAllToFront.rawValue {
                userDefaults.set(FirstClickBehavior.activateApp.rawValue, forKey: firstClickBehaviorKey)
            }

            userDefaults.set(true, forKey: deprecatedBringAllToFrontMigratedKey)
        }

        // Load base mappings from UserDefaults or use the shipped defaults.
        var clickAction = Self.loadAction(from: userDefaults, forKey: clickActionKey) ?? appActionDefaults.clickAction
        var scrollUpAction = Self.loadAction(from: userDefaults, forKey: scrollUpActionKey) ?? modifierDefaults.scrollUpAction
        var scrollDownAction = Self.loadAction(from: userDefaults, forKey: scrollDownActionKey) ?? modifierDefaults.scrollDownAction

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
        var shiftClickAction = Self.loadAction(from: userDefaults, forKey: shiftClickActionKey) ?? modifierDefaults.shiftClickAction
        var optionClickAction = Self.loadAction(from: userDefaults, forKey: optionClickActionKey) ?? modifierDefaults.optionClickAction
        var shiftOptionClickAction = Self.loadAction(from: userDefaults, forKey: shiftOptionClickActionKey) ?? modifierDefaults.shiftOptionClickAction

        var firstClickShiftAction = Self.loadAction(from: userDefaults, forKey: firstClickShiftActionKey) ?? modifierDefaults.firstClickShiftAction
        var firstClickOptionAction = Self.loadAction(from: userDefaults, forKey: firstClickOptionActionKey) ?? modifierDefaults.firstClickOptionAction
        var firstClickShiftOptionAction = Self.loadAction(from: userDefaults, forKey: firstClickShiftOptionActionKey) ?? modifierDefaults.firstClickShiftOptionAction

        var shiftScrollUpAction = Self.loadAction(from: userDefaults, forKey: shiftScrollUpActionKey) ?? modifierDefaults.shiftScrollUpAction
        var optionScrollUpAction = Self.loadAction(from: userDefaults, forKey: optionScrollUpActionKey) ?? modifierDefaults.optionScrollUpAction
        var shiftOptionScrollUpAction = Self.loadAction(from: userDefaults, forKey: shiftOptionScrollUpActionKey) ?? modifierDefaults.shiftOptionScrollUpAction

        var shiftScrollDownAction = Self.loadAction(from: userDefaults, forKey: shiftScrollDownActionKey) ?? modifierDefaults.shiftScrollDownAction
        var optionScrollDownAction = Self.loadAction(from: userDefaults, forKey: optionScrollDownActionKey) ?? modifierDefaults.optionScrollDownAction
        var shiftOptionScrollDownAction = Self.loadAction(from: userDefaults, forKey: shiftOptionScrollDownActionKey) ?? modifierDefaults.shiftOptionScrollDownAction
        let folderClickAction = Self.loadFolderAction(from: userDefaults, forKey: folderClickActionKey) ?? folderDefaults.click
        let shiftFolderClickAction = Self.loadFolderAction(from: userDefaults, forKey: shiftFolderClickActionKey) ?? folderDefaults.shiftClick
        let optionFolderClickAction = Self.loadFolderAction(from: userDefaults, forKey: optionFolderClickActionKey) ?? folderDefaults.optionClick
        let shiftOptionFolderClickAction = Self.loadFolderAction(from: userDefaults, forKey: shiftOptionFolderClickActionKey) ?? folderDefaults.shiftOptionClick
        let folderScrollUpAction = Self.loadFolderAction(from: userDefaults, forKey: folderScrollUpActionKey) ?? folderDefaults.scrollUp
        let shiftFolderScrollUpAction = Self.loadFolderAction(from: userDefaults, forKey: shiftFolderScrollUpActionKey) ?? folderDefaults.shiftScrollUp
        let optionFolderScrollUpAction = Self.loadFolderAction(from: userDefaults, forKey: optionFolderScrollUpActionKey) ?? folderDefaults.optionScrollUp
        let shiftOptionFolderScrollUpAction = Self.loadFolderAction(from: userDefaults, forKey: shiftOptionFolderScrollUpActionKey) ?? folderDefaults.shiftOptionScrollUp
        let reverseMouseScrollActions = userDefaults.bool(forKey: reverseMouseScrollActionsKey)
        let dismissedMouseScrollToolSuggestionIDs = Set(userDefaults.stringArray(forKey: dismissedMouseScrollToolSuggestionIDsKey) ?? [])
        let seenMouseScrollToolSuggestionIDs = Set(userDefaults.stringArray(forKey: seenMouseScrollToolSuggestionIDsKey) ?? [])
        let folderScrollDownAction = Self.loadFolderAction(from: userDefaults, forKey: folderScrollDownActionKey) ?? folderDefaults.scrollDown
        let shiftFolderScrollDownAction = Self.loadFolderAction(from: userDefaults, forKey: shiftFolderScrollDownActionKey) ?? folderDefaults.shiftScrollDown
        let optionFolderScrollDownAction = Self.loadFolderAction(from: userDefaults, forKey: optionFolderScrollDownActionKey) ?? folderDefaults.optionScrollDown
        let shiftOptionFolderScrollDownAction = Self.loadFolderAction(from: userDefaults, forKey: shiftOptionFolderScrollDownActionKey) ?? folderDefaults.shiftOptionScrollDown

        let modifierMigrated = userDefaults.bool(forKey: modifierDefaultsMigratedKey)
        if !modifierMigrated {
            // Respect explicit values when present, otherwise seed new keys.
            if userDefaults.object(forKey: shiftClickActionKey) == nil {
                shiftClickAction = modifierDefaults.shiftClickAction
            }
            if userDefaults.object(forKey: optionClickActionKey) == nil {
                optionClickAction = modifierDefaults.optionClickAction
            }
            if userDefaults.object(forKey: shiftOptionClickActionKey) == nil {
                shiftOptionClickAction = modifierDefaults.shiftOptionClickAction
            }

            if userDefaults.object(forKey: shiftScrollUpActionKey) == nil {
                shiftScrollUpAction = modifierDefaults.shiftScrollUpAction
            }
            if userDefaults.object(forKey: optionScrollUpActionKey) == nil {
                optionScrollUpAction = modifierDefaults.optionScrollUpAction
            }
            if userDefaults.object(forKey: shiftOptionScrollUpActionKey) == nil {
                shiftOptionScrollUpAction = modifierDefaults.shiftOptionScrollUpAction
            }

            if userDefaults.object(forKey: shiftScrollDownActionKey) == nil {
                shiftScrollDownAction = modifierDefaults.shiftScrollDownAction
            }
            if userDefaults.object(forKey: optionScrollDownActionKey) == nil {
                optionScrollDownAction = modifierDefaults.optionScrollDownAction
            }
            if userDefaults.object(forKey: shiftOptionScrollDownActionKey) == nil {
                shiftOptionScrollDownAction = modifierDefaults.shiftOptionScrollDownAction
            }

            userDefaults.set(true, forKey: modifierDefaultsMigratedKey)
        }

        let firstClickModifierMigrated = userDefaults.bool(forKey: firstClickModifierActionsMigratedKey)
        if !firstClickModifierMigrated {
            let hasLegacyClickModifierValues = userDefaults.object(forKey: shiftClickActionKey) != nil
                || userDefaults.object(forKey: optionClickActionKey) != nil
                || userDefaults.object(forKey: shiftOptionClickActionKey) != nil

            if hasLegacyClickModifierValues {
                firstClickShiftAction = shiftClickAction
                firstClickOptionAction = optionClickAction
                firstClickShiftOptionAction = shiftOptionClickAction
            }

            shiftClickAction = modifierDefaults.shiftClickAction
            optionClickAction = modifierDefaults.optionClickAction
            shiftOptionClickAction = modifierDefaults.shiftOptionClickAction

            userDefaults.set(firstClickShiftAction.rawValue, forKey: firstClickShiftActionKey)
            userDefaults.set(firstClickOptionAction.rawValue, forKey: firstClickOptionActionKey)
            userDefaults.set(firstClickShiftOptionAction.rawValue, forKey: firstClickShiftOptionActionKey)
            userDefaults.set(shiftClickAction.rawValue, forKey: shiftClickActionKey)
            userDefaults.set(optionClickAction.rawValue, forKey: optionClickActionKey)
            userDefaults.set(shiftOptionClickAction.rawValue, forKey: shiftOptionClickActionKey)
            userDefaults.set(true, forKey: firstClickModifierActionsMigratedKey)
        }

        let obsoleteAppClickActionsMigrated = userDefaults.bool(forKey: obsoleteAppClickActionsMigratedKey)
        if !obsoleteAppClickActionsMigrated {
            clickAction = appActionDefaults.clickAction
            shiftClickAction = modifierDefaults.shiftClickAction
            optionClickAction = modifierDefaults.optionClickAction
            shiftOptionClickAction = modifierDefaults.shiftOptionClickAction

            userDefaults.set(clickAction.rawValue, forKey: clickActionKey)
            userDefaults.set(shiftClickAction.rawValue, forKey: shiftClickActionKey)
            userDefaults.set(optionClickAction.rawValue, forKey: optionClickActionKey)
            userDefaults.set(shiftOptionClickAction.rawValue, forKey: shiftOptionClickActionKey)
            userDefaults.set(appActionDefaults.clickAppExposeRequiresMultipleWindows,
                             forKey: clickAppExposeRequiresMultipleWindowsKey)

            var updatedAppExposeMap = userDefaults.object(forKey: appExposeRequiresMultipleWindowsMapKey) as? [String: Bool] ?? [:]
            for modifier in [AppExposeSlotModifier.none, .shift, .option, .shiftOption] {
                let slot = AppExposeSlotKey.make(source: .click, modifier: modifier)
                updatedAppExposeMap[slot] = appActionDefaults.clickAppExposeRequiresMultipleWindows
            }
            userDefaults.set(updatedAppExposeMap, forKey: appExposeRequiresMultipleWindowsMapKey)
            userDefaults.set(true, forKey: obsoleteAppClickActionsMigratedKey)
        }

        Self.seedIfMissing(clickAction, in: userDefaults, forKey: clickActionKey)
        Self.seedIfMissing(scrollUpAction, in: userDefaults, forKey: scrollUpActionKey)
        Self.seedIfMissing(scrollDownAction, in: userDefaults, forKey: scrollDownActionKey)
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
        Self.seedIfMissing(folderClickAction, in: userDefaults, forKey: folderClickActionKey)
        Self.seedIfMissing(shiftFolderClickAction, in: userDefaults, forKey: shiftFolderClickActionKey)
        Self.seedIfMissing(optionFolderClickAction, in: userDefaults, forKey: optionFolderClickActionKey)
        Self.seedIfMissing(shiftOptionFolderClickAction, in: userDefaults, forKey: shiftOptionFolderClickActionKey)
        Self.seedIfMissing(folderScrollUpAction, in: userDefaults, forKey: folderScrollUpActionKey)
        Self.seedIfMissing(shiftFolderScrollUpAction, in: userDefaults, forKey: shiftFolderScrollUpActionKey)
        Self.seedIfMissing(optionFolderScrollUpAction, in: userDefaults, forKey: optionFolderScrollUpActionKey)
        Self.seedIfMissing(shiftOptionFolderScrollUpAction, in: userDefaults, forKey: shiftOptionFolderScrollUpActionKey)
        Self.seedIfMissing(folderScrollDownAction, in: userDefaults, forKey: folderScrollDownActionKey)
        Self.seedIfMissing(shiftFolderScrollDownAction, in: userDefaults, forKey: shiftFolderScrollDownActionKey)
        Self.seedIfMissing(optionFolderScrollDownAction, in: userDefaults, forKey: optionFolderScrollDownActionKey)
        Self.seedIfMissing(shiftOptionFolderScrollDownAction, in: userDefaults, forKey: shiftOptionFolderScrollDownActionKey)
        Self.seedIfMissing(generalDefaults.showOnStartup, in: userDefaults, forKey: showOnStartupKey)
        Self.seedIfMissing(generalDefaults.showMenuBarIcon, in: userDefaults, forKey: showMenuBarIconKey)
        Self.seedIfMissing(generalDefaults.firstLaunchCompleted, in: userDefaults, forKey: firstLaunchCompletedKey)
        Self.seedIfMissing(generalDefaults.onboardingState, in: userDefaults, forKey: onboardingStateKey)
        Self.seedIfMissing(generalDefaults.backgroundUpdateChecksEnabled, in: userDefaults, forKey: backgroundUpdateChecksEnabledKey)
        Self.seedIfMissing(generalDefaults.updateCheckFrequency, in: userDefaults, forKey: updateCheckFrequencyKey)
        Self.seedIfMissing(
            generalDefaults.persistentDiagnosticFileLoggingEnabled,
            in: userDefaults,
            forKey: persistentDiagnosticFileLoggingEnabledKey
        )
        Self.seedIfMissing(appActionDefaults.firstClickBehavior, in: userDefaults, forKey: firstClickBehaviorKey)
        Self.seedIfMissing(appActionDefaults.firstClickAppExposeRequiresMultipleWindows,
                           in: userDefaults,
                           forKey: firstClickAppExposeRequiresMultipleWindowsKey)
        Self.seedIfMissing(appActionDefaults.clickAppExposeRequiresMultipleWindows,
                           in: userDefaults,
                           forKey: clickAppExposeRequiresMultipleWindowsKey)

        // General settings defaults
        let showOnStartup = self.settingsStore.value(for: Self.showOnStartupPreferenceKey)
        let showMenuBarIcon = self.settingsStore.value(for: Self.showMenuBarIconPreferenceKey)
        let firstLaunchCompleted = self.settingsStore.value(for: Self.firstLaunchCompletedPreferenceKey)
        let onboardingState = self.settingsStore.value(for: Self.onboardingStatePreferenceKey)
        let backgroundUpdateChecksEnabled = self.settingsStore.value(for: Self.backgroundUpdateChecksEnabledPreferenceKey)

        let startAtLogin = Self.resolvedStartAtLogin(defaults: userDefaults,
                                                     bundleIdentifier: resolvedBundleIdentifier,
                                                     loginItemStatus: resolvedLoginItemClient.status)

        let updateCheckFrequency = self.settingsStore.value(for: Self.updateCheckFrequencyPreferenceKey)
        let persistentDiagnosticFileLoggingEnabled = self.settingsStore.value(
            for: Self.persistentDiagnosticFileLoggingEnabledPreferenceKey
        )

        let firstClickBehavior = self.settingsStore.value(for: Self.firstClickBehaviorPreferenceKey)

        let firstClickAppExposeRequiresMultipleWindows =
            userDefaults.object(forKey: firstClickAppExposeRequiresMultipleWindowsKey) as? Bool
            ?? appActionDefaults.firstClickAppExposeRequiresMultipleWindows
        let clickAppExposeRequiresMultipleWindows =
            userDefaults.object(forKey: clickAppExposeRequiresMultipleWindowsKey) as? Bool
            ?? appActionDefaults.clickAppExposeRequiresMultipleWindows
        var appExposeRequiresMultipleWindowsMap =
            userDefaults.object(forKey: appExposeRequiresMultipleWindowsMapKey) as? [String: Bool]
            ?? appActionDefaults.appExposeRequiresMultipleWindowsMap

        let appExposeMapMigrated = userDefaults.bool(forKey: appExposeRequiresMultipleWindowsMapMigratedKey)
        if !appExposeMapMigrated {
            Self.seedMissingAppExposeGateSlots(in: &appExposeRequiresMultipleWindowsMap,
                                               firstClickDefault: firstClickAppExposeRequiresMultipleWindows,
                                               activeAppDefault: clickAppExposeRequiresMultipleWindows)
            userDefaults.set(appExposeRequiresMultipleWindowsMap, forKey: appExposeRequiresMultipleWindowsMapKey)
            userDefaults.set(true, forKey: appExposeRequiresMultipleWindowsMapMigratedKey)
        } else if userDefaults.object(forKey: appExposeRequiresMultipleWindowsMapKey) == nil {
            userDefaults.set(appExposeRequiresMultipleWindowsMap, forKey: appExposeRequiresMultipleWindowsMapKey)
        }

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
        self.folderClickAction = folderClickAction
        self.shiftFolderClickAction = shiftFolderClickAction
        self.optionFolderClickAction = optionFolderClickAction
        self.shiftOptionFolderClickAction = shiftOptionFolderClickAction
        self.scrollUpAction = scrollUpAction
        self.shiftScrollUpAction = shiftScrollUpAction
        self.optionScrollUpAction = optionScrollUpAction
        self.shiftOptionScrollUpAction = shiftOptionScrollUpAction
        self.folderScrollUpAction = folderScrollUpAction
        self.shiftFolderScrollUpAction = shiftFolderScrollUpAction
        self.optionFolderScrollUpAction = optionFolderScrollUpAction
        self.shiftOptionFolderScrollUpAction = shiftOptionFolderScrollUpAction
        self.scrollDownAction = scrollDownAction
        self.reverseMouseScrollActions = reverseMouseScrollActions
        self.dismissedMouseScrollToolSuggestionIDs = dismissedMouseScrollToolSuggestionIDs
        self.seenMouseScrollToolSuggestionIDs = seenMouseScrollToolSuggestionIDs
        self.shiftScrollDownAction = shiftScrollDownAction
        self.optionScrollDownAction = optionScrollDownAction
        self.shiftOptionScrollDownAction = shiftOptionScrollDownAction
        self.folderScrollDownAction = folderScrollDownAction
        self.shiftFolderScrollDownAction = shiftFolderScrollDownAction
        self.optionFolderScrollDownAction = optionFolderScrollDownAction
        self.shiftOptionFolderScrollDownAction = shiftOptionFolderScrollDownAction
        self.showOnStartup = showOnStartup
        self.showMenuBarIcon = showMenuBarIcon
        self.firstLaunchCompleted = firstLaunchCompleted
        self.onboardingState = onboardingState
        self.backgroundUpdateChecksEnabled = backgroundUpdateChecksEnabled
        self.startAtLogin = startAtLogin
        self.updateCheckFrequency = updateCheckFrequency
        self.persistentDiagnosticFileLoggingEnabled = persistentDiagnosticFileLoggingEnabled

        if applyLoginItemRepair {
            repairLoginItemIfNeeded()
        }
    }

    convenience init(testingUserDefaults: UserDefaults,
                     bundleIdentifier: String? = nil,
                     loginItemClient: LoginItemClient? = nil) {
        let resolvedBundleIdentifier = bundleIdentifier ?? AppIdentity.bundleIdentifier

        self.init(userDefaults: testingUserDefaults,
                  settingsStore: SettingsStore(defaults: testingUserDefaults,
                                               defaultsDomainName: SettingsStore.defaultsDomainName(for: resolvedBundleIdentifier)),
                  applyLoginItemRepair: false,
                  bundleIdentifier: resolvedBundleIdentifier,
                  loginItemClient: loginItemClient)
    }

    static func migrateLegacyDefaultsDomainIfNeeded(defaults: UserDefaults,
                                                    bundleIdentifier: String? = nil) {
        let resolvedBundleIdentifier = bundleIdentifier ?? AppIdentity.bundleIdentifier

        guard AppIdentity.supportsLegacyDefaultsMigration(bundleIdentifier: resolvedBundleIdentifier),
              defaults.bool(forKey: "dockmintDefaultsDomainMigrated_v1") == false else {
            return
        }

        let legacyDomain = AppIdentity.isBetaBuild(bundleIdentifier: resolvedBundleIdentifier)
            ? AppIdentity.transitionBetaBundleIdentifier
            : AppIdentity.transitionStableBundleIdentifier

        guard let domain = defaults.persistentDomain(forName: legacyDomain), !domain.isEmpty else {
            defaults.set(true, forKey: "dockmintDefaultsDomainMigrated_v1")
            return
        }

        for (key, value) in domain where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: "dockmintDefaultsDomainMigrated_v1")
    }

    private static func applyFolderClickDefaultMigrationIfNeeded(defaults: UserDefaults,
                                                                 migrationKey: String,
                                                                 actionKey: String) {
        guard defaults.bool(forKey: migrationKey) == false else {
            return
        }

        defer {
            defaults.set(true, forKey: migrationKey)
        }

        // Existing users keep any intentional folder-click customization. This migration only
        // normalizes the exact historical plain-click Dock default back to the canonical shipped
        // Dock-open action without touching explicit Finder automation or custom app targets.
        guard let storedAction = loadFolderAction(from: defaults, forKey: actionKey),
              storedAction == Self.legacyDefaultFolderClickAction else {
            return
        }

        defaults.set(Self.defaultFolderClickAction.storageValue, forKey: actionKey)
    }

    static func resolvedStartAtLogin(defaults: UserDefaults,
                                     bundleIdentifier: String? = nil,
                                     loginItemStatus: () -> SMAppService.Status = { SMAppService.mainApp.status }) -> Bool {
        let resolvedBundleIdentifier = bundleIdentifier ?? AppIdentity.bundleIdentifier

        guard AppIdentity.supportsLoginItem(bundleIdentifier: resolvedBundleIdentifier) else {
            defaults.set(false, forKey: "startAtLogin")
            return false
        }

        if loginItemStatus() == .enabled {
            return true
        }

        return defaults.object(forKey: "startAtLogin") as? Bool ?? true
    }

    private func repairLoginItemIfNeeded() {
        guard AppIdentity.supportsLegacyDefaultsMigration(bundleIdentifier: bundleIdentifier) else { return }
        guard AppIdentity.supportsLoginItem(bundleIdentifier: bundleIdentifier) else { return }
        guard userDefaults.bool(forKey: loginItemRepairKey) == false else { return }
        guard startAtLogin else {
            userDefaults.set(true, forKey: loginItemRepairKey)
            return
        }
        guard loginItemClient.status() != .enabled else {
            userDefaults.set(true, forKey: loginItemRepairKey)
            return
        }

        do {
            try loginItemClient.register()
            Logger.log("Re-registered login item after Dockmint bundle identifier migration")
        } catch {
            Logger.log("Failed to re-register login item after Dockmint bundle identifier migration: \(error.localizedDescription)")
        }

        userDefaults.set(true, forKey: loginItemRepairKey)
    }

    private static func loadAction(from defaults: UserDefaults, forKey key: String) -> DockAction? {
        guard let raw = defaults.string(forKey: key) else { return nil }
        if raw == DockAction.bringAllToFront.rawValue {
            return .activateApp
        }
        return DockAction(rawValue: raw)
    }

    private static func loadFolderAction(from defaults: UserDefaults, forKey key: String) -> DockFolderAction? {
        guard let raw = defaults.string(forKey: key) else { return nil }
        return DockFolderAction(storageValue: raw)
    }

    private static func seedIfMissing(_ action: DockAction, in defaults: UserDefaults, forKey key: String) {
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(action.rawValue, forKey: key)
    }

    private static func seedIfMissing(_ action: DockFolderAction, in defaults: UserDefaults, forKey key: String) {
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(action.storageValue, forKey: key)
    }

    private static func seedIfMissing(_ value: Bool, in defaults: UserDefaults, forKey key: String) {
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(value, forKey: key)
    }

    private static func seedIfMissing<T: RawRepresentable>(_ value: T,
                                                           in defaults: UserDefaults,
                                                           forKey key: String) where T.RawValue == String {
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(value.rawValue, forKey: key)
    }

    private static func defaultAppExposeRequiresMultipleWindowsMap(firstClickDefault: Bool,
                                                                   activeAppDefault: Bool) -> [String: Bool] {
        var map: [String: Bool] = [:]
        seedMissingAppExposeGateSlots(in: &map,
                                      firstClickDefault: firstClickDefault,
                                      activeAppDefault: activeAppDefault)
        return map
    }

    private static func seedMissingAppExposeGateSlots(in map: inout [String: Bool],
                                                      firstClickDefault: Bool,
                                                      activeAppDefault: Bool) {
        let firstClickModifiers: [AppExposeSlotModifier] = [.shift, .option, .shiftOption]
        let clickModifiers: [AppExposeSlotModifier] = [.none, .shift, .option, .shiftOption]
        let scrollSources: [AppExposeSlotSource] = [.scrollUp, .scrollDown]
        let scrollModifiers: [AppExposeSlotModifier] = [.none, .shift, .option, .shiftOption]

        for modifier in firstClickModifiers {
            let slot = AppExposeSlotKey.make(source: .firstClick, modifier: modifier)
            if map[slot] == nil {
                map[slot] = firstClickDefault
            }
        }

        for modifier in clickModifiers {
            let slot = AppExposeSlotKey.make(source: .click, modifier: modifier)
            if map[slot] == nil {
                map[slot] = activeAppDefault
            }
        }

        for source in scrollSources {
            for modifier in scrollModifiers {
                let slot = AppExposeSlotKey.make(source: source, modifier: modifier)
                if map[slot] == nil {
                    map[slot] = activeAppDefault
                }
            }
        }
    }

    func resetMappingsToDefaults() {
        resetAppActionsToDefaults()
        resetFolderActionsToDefaults()
    }

    func resetAppActionsToDefaults() {
        let appDefaults = Self.shippedAppActionDefaults
        let modifierDefaults = Self.shippedModifierDefaults

        clickAction = appDefaults.clickAction
        firstClickBehavior = appDefaults.firstClickBehavior
        firstClickAppExposeRequiresMultipleWindows = appDefaults.firstClickAppExposeRequiresMultipleWindows
        clickAppExposeRequiresMultipleWindows = appDefaults.clickAppExposeRequiresMultipleWindows
        appExposeRequiresMultipleWindowsMap = appDefaults.appExposeRequiresMultipleWindowsMap

        firstClickShiftAction = modifierDefaults.firstClickShiftAction
        firstClickOptionAction = modifierDefaults.firstClickOptionAction
        firstClickShiftOptionAction = modifierDefaults.firstClickShiftOptionAction

        shiftClickAction = modifierDefaults.shiftClickAction
        optionClickAction = modifierDefaults.optionClickAction
        shiftOptionClickAction = modifierDefaults.shiftOptionClickAction

        scrollUpAction = modifierDefaults.scrollUpAction
        shiftScrollUpAction = modifierDefaults.shiftScrollUpAction
        optionScrollUpAction = modifierDefaults.optionScrollUpAction
        shiftOptionScrollUpAction = modifierDefaults.shiftOptionScrollUpAction

        scrollDownAction = modifierDefaults.scrollDownAction
        shiftScrollDownAction = modifierDefaults.shiftScrollDownAction
        optionScrollDownAction = modifierDefaults.optionScrollDownAction
        shiftOptionScrollDownAction = modifierDefaults.shiftOptionScrollDownAction
    }

    func resetFolderActionsToDefaults() {
        let folderDefaults = Self.shippedFolderDefaults

        folderClickAction = folderDefaults.click
        shiftFolderClickAction = folderDefaults.shiftClick
        optionFolderClickAction = folderDefaults.optionClick
        shiftOptionFolderClickAction = folderDefaults.shiftOptionClick

        folderScrollUpAction = folderDefaults.scrollUp
        shiftFolderScrollUpAction = folderDefaults.shiftScrollUp
        optionFolderScrollUpAction = folderDefaults.optionScrollUp
        shiftOptionFolderScrollUpAction = folderDefaults.shiftOptionScrollUp

        folderScrollDownAction = folderDefaults.scrollDown
        shiftFolderScrollDownAction = folderDefaults.shiftScrollDown
        optionFolderScrollDownAction = folderDefaults.optionScrollDown
        shiftOptionFolderScrollDownAction = folderDefaults.shiftOptionScrollDown
    }

    func advanceOnboarding() {
        guard onboardingState != .completed else { return }
        onboardingState = onboardingState.next
    }

    func returnToPreviousOnboardingStep() {
        guard onboardingState != .notStarted else { return }
        onboardingState = onboardingState.previous
    }

    func completeOnboarding() {
        onboardingState = .completed
    }

    func enableBackgroundUpdateChecks(_ frequency: UpdateCheckFrequency = .weekly) {
        backgroundUpdateChecksEnabled = true
        if updateCheckFrequency == .never {
            updateCheckFrequency = frequency
        }
    }

    func disableBackgroundUpdateChecks() {
        backgroundUpdateChecksEnabled = false
        updateCheckFrequency = .never
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
