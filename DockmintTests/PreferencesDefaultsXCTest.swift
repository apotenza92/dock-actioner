import XCTest

@MainActor
final class PreferencesDefaultsXCTest: XCTestCase {
    func testFreshPreferencesLoadShippedGeneralDefaults() {
        let defaults = isolatedDefaults()
        let preferences = Preferences(testingUserDefaults: defaults)

        XCTAssertEqual(preferences.showMenuBarIcon, Preferences.shippedGeneralDefaults.showMenuBarIcon)
        XCTAssertEqual(preferences.showOnStartup, Preferences.shippedGeneralDefaults.showOnStartup)
        XCTAssertEqual(preferences.firstLaunchCompleted, Preferences.shippedGeneralDefaults.firstLaunchCompleted)
        XCTAssertEqual(preferences.onboardingState, Preferences.shippedGeneralDefaults.onboardingState)
        XCTAssertEqual(
            preferences.backgroundUpdateChecksEnabled,
            Preferences.shippedGeneralDefaults.backgroundUpdateChecksEnabled
        )
        XCTAssertEqual(preferences.updateCheckFrequency, Preferences.shippedGeneralDefaults.updateCheckFrequency)
        XCTAssertEqual(
            preferences.persistentDiagnosticFileLoggingEnabled,
            Preferences.shippedGeneralDefaults.persistentDiagnosticFileLoggingEnabled
        )

        XCTAssertEqual(defaults.object(forKey: "showMenuBarIcon") as? Bool, Preferences.shippedGeneralDefaults.showMenuBarIcon)
        XCTAssertEqual(defaults.object(forKey: "showOnStartup") as? Bool, Preferences.shippedGeneralDefaults.showOnStartup)
        XCTAssertEqual(defaults.object(forKey: "firstLaunchCompleted") as? Bool, Preferences.shippedGeneralDefaults.firstLaunchCompleted)
        XCTAssertEqual(defaults.string(forKey: "onboardingState"), Preferences.shippedGeneralDefaults.onboardingState.rawValue)
        XCTAssertEqual(
            defaults.object(forKey: "backgroundUpdateChecksEnabled") as? Bool,
            Preferences.shippedGeneralDefaults.backgroundUpdateChecksEnabled
        )
        XCTAssertEqual(defaults.string(forKey: "updateCheckFrequency"), Preferences.shippedGeneralDefaults.updateCheckFrequency.rawValue)
        XCTAssertEqual(
            defaults.object(forKey: "persistentDiagnosticFileLoggingEnabled") as? Bool,
            Preferences.shippedGeneralDefaults.persistentDiagnosticFileLoggingEnabled
        )
    }

    func testFreshPreferencesLoadShippedAppActionDefaults() {
        let defaults = isolatedDefaults()
        let preferences = Preferences(testingUserDefaults: defaults)

        assertMatchesShippedAppDefaults(preferences)

        XCTAssertEqual(defaults.string(forKey: "clickAction"), Preferences.shippedAppActionDefaults.clickAction.rawValue)
        XCTAssertEqual(defaults.string(forKey: "firstClickBehavior"), Preferences.shippedAppActionDefaults.firstClickBehavior.rawValue)
        XCTAssertEqual(defaults.string(forKey: "firstClickShiftOptionAction"),
                       Preferences.shippedModifierDefaults.firstClickShiftOptionAction.rawValue)
        XCTAssertEqual(defaults.object(forKey: "firstClickAppExposeRequiresMultipleWindows") as? Bool,
                       Preferences.shippedAppActionDefaults.firstClickAppExposeRequiresMultipleWindows)
        XCTAssertEqual(defaults.object(forKey: "clickAppExposeRequiresMultipleWindows") as? Bool,
                       Preferences.shippedAppActionDefaults.clickAppExposeRequiresMultipleWindows)
        XCTAssertEqual(defaults.dictionary(forKey: "appExposeRequiresMultipleWindowsMap") as? [String: Bool],
                       Preferences.shippedAppActionDefaults.appExposeRequiresMultipleWindowsMap)
    }

    func testFreshPreferencesLoadShippedFolderDefaults() {
        let defaults = isolatedDefaults()
        let preferences = Preferences(testingUserDefaults: defaults)

        assertMatchesShippedFolderDefaults(preferences)

        XCTAssertEqual(defaults.string(forKey: "folderClickAction"), Preferences.shippedFolderDefaults.click.storageValue)
        XCTAssertEqual(defaults.string(forKey: "optionFolderClickAction"), Preferences.shippedFolderDefaults.optionClick.storageValue)
    }

    func testResetAppActionsRestoresShippedDefaults() {
        let defaults = isolatedDefaults()
        let preferences = Preferences(testingUserDefaults: defaults)
        preferences.clickAction = .hideApp
        preferences.firstClickBehavior = .activateApp
        preferences.firstClickAppExposeRequiresMultipleWindows = false
        preferences.clickAppExposeRequiresMultipleWindows = true
        preferences.appExposeRequiresMultipleWindowsMap = [:]
        preferences.firstClickShiftAction = .quitApp
        preferences.firstClickOptionAction = .hideApp
        preferences.firstClickShiftOptionAction = .activateApp
        preferences.shiftClickAction = .hideOthers
        preferences.optionClickAction = .singleAppMode
        preferences.shiftOptionClickAction = .quitApp
        preferences.scrollUpAction = .hideOthers
        preferences.shiftScrollUpAction = .appExpose
        preferences.optionScrollUpAction = .hideApp
        preferences.shiftOptionScrollUpAction = .quitApp
        preferences.scrollDownAction = .appExpose
        preferences.reverseMouseScrollActions = true
        preferences.shiftScrollDownAction = .hideApp
        preferences.optionScrollDownAction = .singleAppMode
        preferences.shiftOptionScrollDownAction = .quitApp

        preferences.resetAppActionsToDefaults()

        assertMatchesShippedAppDefaults(preferences)
        XCTAssertEqual(defaults.string(forKey: "clickAction"), DockAction.none.rawValue)
        XCTAssertEqual(defaults.string(forKey: "shiftClickAction"), DockAction.none.rawValue)
        XCTAssertEqual(defaults.string(forKey: "optionClickAction"), DockAction.none.rawValue)
        XCTAssertEqual(defaults.string(forKey: "firstClickShiftOptionAction"), DockAction.quitApp.rawValue)
        XCTAssertEqual(defaults.string(forKey: "shiftOptionClickAction"), DockAction.none.rawValue)
        XCTAssertEqual(defaults.object(forKey: "clickAppExposeRequiresMultipleWindows") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "invertDiscreteScrollDirection") as? Bool, true)
        XCTAssertTrue(preferences.reverseMouseScrollActions)
    }

    func testMouseScrollToolSuggestionStatePersistsAndSuppressesPrompts() {
        let defaults = isolatedDefaults()
        let preferences = Preferences(testingUserDefaults: defaults)
        let tool = MouseScrollDirectionTool(id: "linearmouse", displayName: "LinearMouse", bundleIdentifier: "com.lujjjh.LinearMouse", nameNeedle: "linearmouse")

        XCTAssertTrue(preferences.shouldSuggestReverseMouseScrollDuringOnboarding(for: tool))
        XCTAssertTrue(preferences.shouldSuggestReverseMouseScrollAfterOnboarding(for: tool))

        preferences.markMouseScrollToolSuggestionSeen(for: tool)
        XCTAssertTrue(preferences.shouldSuggestReverseMouseScrollDuringOnboarding(for: tool))
        XCTAssertFalse(preferences.shouldSuggestReverseMouseScrollAfterOnboarding(for: tool))
        XCTAssertEqual(defaults.stringArray(forKey: "seenMouseScrollToolSuggestionIDs"), ["linearmouse"])

        preferences.dismissMouseScrollToolSuggestion(for: tool)
        XCTAssertFalse(preferences.shouldSuggestReverseMouseScrollDuringOnboarding(for: tool))
        XCTAssertFalse(preferences.shouldSuggestReverseMouseScrollAfterOnboarding(for: tool))
        XCTAssertEqual(defaults.stringArray(forKey: "dismissedMouseScrollToolSuggestionIDs"), ["linearmouse"])
    }

    func testReverseMouseScrollSuggestionTurnOnEnablesPreference() {
        let defaults = isolatedDefaults()
        let preferences = Preferences(testingUserDefaults: defaults)
        let tool = MouseScrollDirectionTool(id: "linearmouse", displayName: "LinearMouse", bundleIdentifier: "com.lujjjh.LinearMouse", nameNeedle: "linearmouse")

        preferences.enableReverseMouseScrollActionsFromSuggestion(for: tool)

        XCTAssertTrue(preferences.reverseMouseScrollActions)
        XCTAssertEqual(defaults.object(forKey: "invertDiscreteScrollDirection") as? Bool, true)
        XCTAssertFalse(preferences.shouldSuggestReverseMouseScrollDuringOnboarding(for: tool))
        XCTAssertFalse(preferences.shouldSuggestReverseMouseScrollAfterOnboarding(for: tool))
    }

    func testLegacyAppDoubleClickKeysAreClearedDuringInitialization() {
        let defaults = isolatedDefaults()
        defaults.set(DockAction.hideApp.rawValue, forKey: "clickAction")
        defaults.set(DockAction.hideOthers.rawValue, forKey: "shiftClickAction")
        defaults.set(DockAction.singleAppMode.rawValue, forKey: "optionClickAction")
        defaults.set(DockAction.quitApp.rawValue, forKey: "shiftOptionClickAction")
        defaults.set(true, forKey: "clickAppExposeRequiresMultipleWindows")
        defaults.set([AppExposeSlotKey.make(source: .click, modifier: .none): true],
                     forKey: "appExposeRequiresMultipleWindowsMap")

        _ = Preferences(testingUserDefaults: defaults)

        XCTAssertEqual(defaults.string(forKey: "clickAction"), DockAction.none.rawValue)
        XCTAssertEqual(defaults.string(forKey: "shiftClickAction"), DockAction.none.rawValue)
        XCTAssertEqual(defaults.string(forKey: "optionClickAction"), DockAction.none.rawValue)
        XCTAssertEqual(defaults.string(forKey: "shiftOptionClickAction"), DockAction.none.rawValue)
        XCTAssertEqual(defaults.object(forKey: "clickAppExposeRequiresMultipleWindows") as? Bool, false)
        XCTAssertEqual(
            defaults.dictionary(forKey: "appExposeRequiresMultipleWindowsMap")?[AppExposeSlotKey.make(source: .click, modifier: .none)] as? Bool,
            false
        )
    }

    func testResetFolderActionsRestoresShippedDefaults() {
        let preferences = makePreferences()
        preferences.folderClickAction = .none
        preferences.shiftFolderClickAction = Preferences.shippedFolderDefaults.optionClick
        preferences.optionFolderClickAction = .none
        preferences.shiftOptionFolderClickAction = Preferences.shippedFolderDefaults.click
        preferences.folderScrollUpAction = Preferences.shippedFolderDefaults.click
        preferences.shiftFolderScrollUpAction = Preferences.shippedFolderDefaults.optionClick
        preferences.optionFolderScrollUpAction = Preferences.shippedFolderDefaults.click
        preferences.shiftOptionFolderScrollUpAction = Preferences.shippedFolderDefaults.optionClick
        preferences.folderScrollDownAction = Preferences.shippedFolderDefaults.click
        preferences.shiftFolderScrollDownAction = Preferences.shippedFolderDefaults.optionClick
        preferences.optionFolderScrollDownAction = Preferences.shippedFolderDefaults.click
        preferences.shiftOptionFolderScrollDownAction = Preferences.shippedFolderDefaults.optionClick

        preferences.resetFolderActionsToDefaults()

        assertMatchesShippedFolderDefaults(preferences)
    }

    func testDevelopmentIdentityKeepsDefaultsIsolatedFromReleaseMigrationData() {
        let defaults = isolatedDefaults()
        defaults.setPersistentDomain(
            [
                "showOnStartup": true,
                "clickAction": DockAction.hideApp.rawValue,
                "firstLaunchCompleted": true,
            ],
            forName: AppIdentity.transitionStableBundleIdentifier
        )

        let preferences = Preferences(
            testingUserDefaults: defaults,
            bundleIdentifier: AppIdentity.developmentBundleIdentifier,
            loginItemClient: .init(status: { .notRegistered }, register: {}, unregister: {})
        )

        XCTAssertEqual(preferences.showOnStartup, Preferences.shippedGeneralDefaults.showOnStartup)
        XCTAssertEqual(preferences.clickAction, Preferences.shippedAppActionDefaults.clickAction)
        XCTAssertEqual(preferences.firstLaunchCompleted, Preferences.shippedGeneralDefaults.firstLaunchCompleted)
        XCTAssertNil(defaults.object(forKey: "dockmintDefaultsDomainMigrated_v1"))
        XCTAssertEqual(SettingsStore.defaultsDomainName(for: AppIdentity.developmentBundleIdentifier), AppIdentity.developmentBundleIdentifier)
    }

    func testDevelopmentIdentityDoesNotRunLegacyDefaultsMigration() {
        let defaults = isolatedDefaults()
        defaults.setPersistentDomain(
            [
                "showOnStartup": true,
                "updateCheckFrequency": UpdateCheckFrequency.daily.rawValue,
            ],
            forName: AppIdentity.transitionStableBundleIdentifier
        )

        Preferences.migrateLegacyDefaultsDomainIfNeeded(
            defaults: defaults,
            bundleIdentifier: AppIdentity.developmentBundleIdentifier
        )

        XCTAssertNil(defaults.object(forKey: "showOnStartup"))
        XCTAssertNil(defaults.object(forKey: "updateCheckFrequency"))
        XCTAssertNil(defaults.object(forKey: "dockmintDefaultsDomainMigrated_v1"))
    }

    func testFreshStableIdentityDefaultsStartAtLoginOn() {
        let defaults = isolatedDefaults()

        let preferences = Preferences(
            testingUserDefaults: defaults,
            bundleIdentifier: AppIdentity.cleanupStableBundleIdentifier,
            loginItemClient: .init(status: { .notRegistered }, register: {}, unregister: {})
        )

        XCTAssertTrue(preferences.startAtLogin)
        XCTAssertTrue(
            Preferences.resolvedStartAtLogin(
                defaults: defaults,
                bundleIdentifier: AppIdentity.cleanupStableBundleIdentifier,
                loginItemStatus: { .notRegistered }
            )
        )
    }

    func testDevelopmentIdentityGatesLoginItemState() {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "startAtLogin")

        var registerCalls = 0
        var unregisterCalls = 0
        let preferences = Preferences(
            testingUserDefaults: defaults,
            bundleIdentifier: AppIdentity.developmentBundleIdentifier,
            loginItemClient: .init(
                status: { .enabled },
                register: { registerCalls += 1 },
                unregister: { unregisterCalls += 1 }
            )
        )

        XCTAssertFalse(preferences.startAtLogin)
        XCTAssertEqual(defaults.object(forKey: "startAtLogin") as? Bool, false)
        XCTAssertFalse(
            Preferences.resolvedStartAtLogin(
                defaults: defaults,
                bundleIdentifier: AppIdentity.developmentBundleIdentifier,
                loginItemStatus: { .enabled }
            )
        )

        preferences.startAtLogin = true

        XCTAssertFalse(preferences.startAtLogin)
        XCTAssertEqual(registerCalls, 0)
        XCTAssertEqual(unregisterCalls, 0)
        XCTAssertEqual(defaults.object(forKey: "startAtLogin") as? Bool, false)
    }

    private func assertMatchesShippedAppDefaults(_ preferences: Preferences,
                                                 file: StaticString = #filePath,
                                                 line: UInt = #line) {
        XCTAssertEqual(preferences.clickAction, Preferences.shippedAppActionDefaults.clickAction, file: file, line: line)
        XCTAssertEqual(preferences.firstClickBehavior, Preferences.shippedAppActionDefaults.firstClickBehavior, file: file, line: line)
        XCTAssertEqual(preferences.firstClickAppExposeRequiresMultipleWindows,
                       Preferences.shippedAppActionDefaults.firstClickAppExposeRequiresMultipleWindows,
                       file: file,
                       line: line)
        XCTAssertEqual(preferences.clickAppExposeRequiresMultipleWindows,
                       Preferences.shippedAppActionDefaults.clickAppExposeRequiresMultipleWindows,
                       file: file,
                       line: line)
        XCTAssertEqual(preferences.appExposeRequiresMultipleWindowsMap,
                       Preferences.shippedAppActionDefaults.appExposeRequiresMultipleWindowsMap,
                       file: file,
                       line: line)

        XCTAssertEqual(preferences.firstClickShiftAction, Preferences.shippedModifierDefaults.firstClickShiftAction, file: file, line: line)
        XCTAssertEqual(preferences.firstClickOptionAction, Preferences.shippedModifierDefaults.firstClickOptionAction, file: file, line: line)
        XCTAssertEqual(preferences.firstClickShiftOptionAction, Preferences.shippedModifierDefaults.firstClickShiftOptionAction, file: file, line: line)
        XCTAssertEqual(preferences.shiftClickAction, Preferences.shippedModifierDefaults.shiftClickAction, file: file, line: line)
        XCTAssertEqual(preferences.optionClickAction, Preferences.shippedModifierDefaults.optionClickAction, file: file, line: line)
        XCTAssertEqual(preferences.shiftOptionClickAction, Preferences.shippedModifierDefaults.shiftOptionClickAction, file: file, line: line)
        XCTAssertEqual(preferences.scrollUpAction, Preferences.shippedModifierDefaults.scrollUpAction, file: file, line: line)
        XCTAssertEqual(preferences.shiftScrollUpAction, Preferences.shippedModifierDefaults.shiftScrollUpAction, file: file, line: line)
        XCTAssertEqual(preferences.optionScrollUpAction, Preferences.shippedModifierDefaults.optionScrollUpAction, file: file, line: line)
        XCTAssertEqual(preferences.shiftOptionScrollUpAction, Preferences.shippedModifierDefaults.shiftOptionScrollUpAction, file: file, line: line)
        XCTAssertEqual(preferences.scrollDownAction, Preferences.shippedModifierDefaults.scrollDownAction, file: file, line: line)
        XCTAssertEqual(preferences.shiftScrollDownAction, Preferences.shippedModifierDefaults.shiftScrollDownAction, file: file, line: line)
        XCTAssertEqual(preferences.optionScrollDownAction, Preferences.shippedModifierDefaults.optionScrollDownAction, file: file, line: line)
        XCTAssertEqual(preferences.shiftOptionScrollDownAction, Preferences.shippedModifierDefaults.shiftOptionScrollDownAction, file: file, line: line)

        XCTAssertEqual(preferences.appExposeMultipleWindowsRequired(slot: AppExposeSlotKey.make(source: .firstClick, modifier: .shift)), true, file: file, line: line)
        XCTAssertEqual(preferences.appExposeMultipleWindowsRequired(slot: AppExposeSlotKey.make(source: .firstClick, modifier: .option)), true, file: file, line: line)
        XCTAssertEqual(preferences.appExposeMultipleWindowsRequired(slot: AppExposeSlotKey.make(source: .click, modifier: .shift)), false, file: file, line: line)
        XCTAssertEqual(preferences.appExposeMultipleWindowsRequired(slot: AppExposeSlotKey.make(source: .scrollUp, modifier: .none)), false, file: file, line: line)
        XCTAssertEqual(preferences.appExposeMultipleWindowsRequired(slot: AppExposeSlotKey.make(source: .scrollDown, modifier: .shiftOption)), false, file: file, line: line)
    }

    private func assertMatchesShippedFolderDefaults(_ preferences: Preferences,
                                                    file: StaticString = #filePath,
                                                    line: UInt = #line) {
        XCTAssertEqual(preferences.folderClickAction, Preferences.shippedFolderDefaults.click, file: file, line: line)
        XCTAssertEqual(preferences.shiftFolderClickAction, Preferences.shippedFolderDefaults.shiftClick, file: file, line: line)
        XCTAssertEqual(preferences.optionFolderClickAction, Preferences.shippedFolderDefaults.optionClick, file: file, line: line)
        XCTAssertEqual(preferences.shiftOptionFolderClickAction, Preferences.shippedFolderDefaults.shiftOptionClick, file: file, line: line)
        XCTAssertEqual(preferences.folderScrollUpAction, Preferences.shippedFolderDefaults.scrollUp, file: file, line: line)
        XCTAssertEqual(preferences.shiftFolderScrollUpAction, Preferences.shippedFolderDefaults.shiftScrollUp, file: file, line: line)
        XCTAssertEqual(preferences.optionFolderScrollUpAction, Preferences.shippedFolderDefaults.optionScrollUp, file: file, line: line)
        XCTAssertEqual(preferences.shiftOptionFolderScrollUpAction, Preferences.shippedFolderDefaults.shiftOptionScrollUp, file: file, line: line)
        XCTAssertEqual(preferences.folderScrollDownAction, Preferences.shippedFolderDefaults.scrollDown, file: file, line: line)
        XCTAssertEqual(preferences.shiftFolderScrollDownAction, Preferences.shippedFolderDefaults.shiftScrollDown, file: file, line: line)
        XCTAssertEqual(preferences.optionFolderScrollDownAction, Preferences.shippedFolderDefaults.optionScrollDown, file: file, line: line)
        XCTAssertEqual(preferences.shiftOptionFolderScrollDownAction, Preferences.shippedFolderDefaults.shiftOptionScrollDown, file: file, line: line)
    }

    private func makePreferences() -> Preferences {
        Preferences(testingUserDefaults: isolatedDefaults())
    }

    private func isolatedDefaults(file: StaticString = #filePath, line: UInt = #line) -> UserDefaults {
        let suiteName = "DockmintTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated defaults", file: file, line: line)
            fatalError("Failed to create isolated defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
