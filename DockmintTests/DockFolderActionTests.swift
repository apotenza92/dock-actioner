import XCTest

@MainActor
final class DockFolderActionTests: XCTestCase {
    func testFreshPreferencesDefaultFolderClickUsesDock() {
        let preferences = makePreferences()

        XCTAssertEqual(preferences.folderClickAction, Preferences.defaultFolderClickAction)
        XCTAssertFalse(preferences.folderClickAction.isFinderPassthrough)
        XCTAssertEqual(
            preferences.folderClickAction.openInApplicationIdentifier,
            DockFolderOpenApplicationCatalog.dockIdentifier
        )
        XCTAssertEqual(preferences.optionFolderClickAction, Preferences.shippedFolderDefaults.optionClick)
        XCTAssertTrue(preferences.optionFolderClickAction.isFinderPassthrough)
    }

    func testResetFolderActionsRestoresDockDefault() {
        let preferences = makePreferences()
        preferences.folderClickAction = DockFolderAction(
            openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
            view: .list,
            sortBy: .name,
            groupBy: .none
        )

        preferences.resetFolderActionsToDefaults()

        XCTAssertEqual(preferences.folderClickAction, Preferences.defaultFolderClickAction)
        XCTAssertFalse(preferences.folderClickAction.isFinderPassthrough)
        XCTAssertEqual(preferences.optionFolderClickAction, Preferences.shippedFolderDefaults.optionClick)
    }

    func testLegacyStoredDockDefaultRemainsDock() {
        let defaults = isolatedDefaults()
        let legacyDefault = DockFolderAction(
            openInApplicationIdentifier: DockFolderOpenApplicationCatalog.dockIdentifier,
            view: .automatic,
            sortBy: .none,
            groupBy: .none
        )
        defaults.set(legacyDefault.storageValue, forKey: "folderClickAction")

        let preferences = Preferences(testingUserDefaults: defaults)

        XCTAssertEqual(preferences.folderClickAction, Preferences.defaultFolderClickAction)
        XCTAssertEqual(defaults.string(forKey: "folderClickAction"), Preferences.defaultFolderClickAction.storageValue)
    }

    func testStoredFolderOptionsLoadUsingSystemDefaults() {
        let defaults = isolatedDefaults()
        let configuredFinder = DockFolderAction(
            openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
            view: .list,
            sortBy: .name,
            groupBy: .kind
        )
        defaults.set(configuredFinder.storageValue, forKey: "folderClickAction")

        let preferences = Preferences(testingUserDefaults: defaults)

        XCTAssertEqual(
            preferences.folderClickAction,
            DockFolderAction(
                openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
                view: .automatic,
                sortBy: .none,
                groupBy: .none
            )
        )
    }

    func testDeprecatedBringAllToFrontSettingsMigrateToSingleClickDefaults() {
        let defaults = isolatedDefaults()
        defaults.set(DockAction.bringAllToFront.rawValue, forKey: "clickAction")
        defaults.set(DockAction.bringAllToFront.rawValue, forKey: "shiftScrollDownAction")
        defaults.set(FirstClickBehavior.bringAllToFront.rawValue, forKey: "firstClickBehavior")

        let preferences = Preferences(testingUserDefaults: defaults)

        XCTAssertEqual(preferences.clickAction, .none)
        XCTAssertEqual(preferences.shiftScrollDownAction, .activateApp)
        XCTAssertEqual(preferences.firstClickBehavior, .activateApp)
        XCTAssertEqual(defaults.string(forKey: "clickAction"), DockAction.none.rawValue)
        XCTAssertEqual(defaults.string(forKey: "shiftScrollDownAction"), DockAction.activateApp.rawValue)
        XCTAssertEqual(defaults.string(forKey: "firstClickBehavior"), FirstClickBehavior.activateApp.rawValue)
    }

    func testFinderPassthroughRequiresFinderAndAutomaticViewOnly() {
        let finderAutomatic = DockFolderAction(
            openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
            view: .automatic,
            sortBy: .none,
            groupBy: .none
        )
        let finderList = DockFolderAction(
            openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
            view: .list,
            sortBy: .none,
            groupBy: .none
        )
        let customAutomatic = DockFolderAction(
            openInApplicationIdentifier: "com.apple.Terminal",
            view: .automatic,
            sortBy: .none,
            groupBy: .none
        )

        XCTAssertTrue(finderAutomatic.isFinderPassthrough)
        XCTAssertFalse(finderList.isFinderPassthrough)
        XCTAssertFalse(customAutomatic.isFinderPassthrough)
    }

    func testExplicitFinderOverridesAreNotPassthrough() {
        let explicitView = DockFolderAction(
            openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
            view: .icon,
            sortBy: .none,
            groupBy: .none
        )
        let explicitGroup = DockFolderAction(
            openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
            view: .list,
            sortBy: .name,
            groupBy: .kind
        )

        XCTAssertFalse(explicitView.isFinderPassthrough)
        XCTAssertFalse(explicitGroup.isFinderPassthrough)
    }

    func testExecutionRouteClassificationCoversAllFolderActionBranches() {
        XCTAssertEqual(DockFolderActionExecutor.executionRoute(for: .none), .none)
        XCTAssertEqual(
            DockFolderActionExecutor.executionRoute(
                for: DockFolderAction(
                    openInApplicationIdentifier: DockFolderOpenApplicationCatalog.dockIdentifier,
                    view: .automatic,
                    sortBy: .none,
                    groupBy: .none
                )
            ),
            .dock
        )
        XCTAssertEqual(
            DockFolderActionExecutor.executionRoute(for: Preferences.defaultFolderClickAction),
            .dock
        )
        XCTAssertEqual(
            DockFolderActionExecutor.executionRoute(
                for: DockFolderAction(
                    openInApplicationIdentifier: DockFolderOpenApplicationCatalog.finderBundleIdentifier,
                    view: .list,
                    sortBy: .name,
                    groupBy: .none
                )
            ),
            .finderScripted
        )
        XCTAssertEqual(
            DockFolderActionExecutor.executionRoute(
                for: DockFolderAction(
                    openInApplicationIdentifier: "com.apple.Terminal",
                    view: .automatic,
                    sortBy: .none,
                    groupBy: .none
                )
            ),
            .customApplication
        )
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
