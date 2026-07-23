import XCTest

final class AppIdentityXCTest: XCTestCase {
    func testLegacyDocktorCompatibilityContract() {
        XCTAssertEqual(AppIdentity.transitionStableBundleIdentifier, "pzc.Dockter")
        XCTAssertEqual(AppIdentity.transitionBetaBundleIdentifier, "pzc.Dockter.beta")
        XCTAssertEqual(AppIdentity.legacyURLSchemes, Set(["docktor", "dockter"]))
        XCTAssertTrue(
            AppIdentity.instanceBundleNames(bundleIdentifier: AppIdentity.cleanupStableBundleIdentifier)
                .isSuperset(of: ["Dockter.app", "Docktor.app"])
        )
        XCTAssertEqual(
            AppIdentity.preferredFeedRepository(bundleIdentifier: AppIdentity.transitionStableBundleIdentifier),
            "apotenza92/docktor"
        )
        XCTAssertEqual(
            AppIdentity.preferredFeedRepository(bundleIdentifier: AppIdentity.cleanupStableBundleIdentifier),
            "apotenza92/dockmint"
        )
    }

    func testDevelopmentIdentityRecognition() {
        XCTAssertTrue(AppIdentity.isDevelopmentIdentity(bundleIdentifier: AppIdentity.developmentBundleIdentifier))
        XCTAssertEqual(AppIdentity.runningIdentity(bundleIdentifier: AppIdentity.developmentBundleIdentifier), .development)

        XCTAssertFalse(AppIdentity.isDevelopmentIdentity(bundleIdentifier: AppIdentity.cleanupStableBundleIdentifier))
        XCTAssertEqual(AppIdentity.runningIdentity(bundleIdentifier: AppIdentity.cleanupStableBundleIdentifier), .stable)
        XCTAssertEqual(AppIdentity.runningIdentity(bundleIdentifier: AppIdentity.cleanupBetaBundleIdentifier), .beta)
    }

    func testReleaseAndDevelopmentCapabilities() {
        XCTAssertFalse(AppIdentity.supportsUpdates(bundleIdentifier: AppIdentity.developmentBundleIdentifier))
        XCTAssertFalse(AppIdentity.supportsLoginItem(bundleIdentifier: AppIdentity.developmentBundleIdentifier))
        XCTAssertFalse(AppIdentity.supportsLegacyDefaultsMigration(bundleIdentifier: AppIdentity.developmentBundleIdentifier))
        XCTAssertEqual(AppIdentity.logDirectoryName(bundleIdentifier: AppIdentity.developmentBundleIdentifier), "Dockmint Dev")
        XCTAssertEqual(
            AppIdentity.supportedURLSchemes(bundleIdentifier: AppIdentity.developmentBundleIdentifier),
            Set([AppIdentity.developmentURLScheme])
        )

        XCTAssertTrue(AppIdentity.supportsUpdates(bundleIdentifier: AppIdentity.cleanupStableBundleIdentifier))
        XCTAssertTrue(AppIdentity.supportsUpdates(bundleIdentifier: AppIdentity.cleanupBetaBundleIdentifier))
        XCTAssertTrue(AppIdentity.supportsLoginItem(bundleIdentifier: AppIdentity.cleanupStableBundleIdentifier))
        XCTAssertTrue(AppIdentity.supportsLoginItem(bundleIdentifier: AppIdentity.transitionStableBundleIdentifier))
        XCTAssertTrue(AppIdentity.supportsLegacyDefaultsMigration(bundleIdentifier: AppIdentity.cleanupStableBundleIdentifier))
        XCTAssertTrue(AppIdentity.supportsLegacyDefaultsMigration(bundleIdentifier: AppIdentity.cleanupBetaBundleIdentifier))
        XCTAssertFalse(AppIdentity.supportsLegacyDefaultsMigration(bundleIdentifier: AppIdentity.transitionStableBundleIdentifier))
        XCTAssertEqual(AppIdentity.logDirectoryName(bundleIdentifier: AppIdentity.cleanupStableBundleIdentifier), "Dockmint")
        XCTAssertEqual(
            AppIdentity.supportedURLSchemes(bundleIdentifier: AppIdentity.cleanupStableBundleIdentifier),
            AppIdentity.legacyURLSchemes.union([AppIdentity.currentURLScheme])
        )
    }

    func testCoexistencePolicyAndInstanceDetectionSets() {
        XCTAssertTrue(AppIdentity.canCoexistWithRelease(bundleIdentifier: AppIdentity.developmentBundleIdentifier))
        XCTAssertTrue(AppIdentity.canCoexistWithRelease(bundleIdentifier: AppIdentity.cleanupBetaBundleIdentifier))
        XCTAssertFalse(AppIdentity.canCoexistWithRelease(bundleIdentifier: AppIdentity.cleanupStableBundleIdentifier))

        XCTAssertEqual(
            AppIdentity.instanceBundleIdentifiers(bundleIdentifier: AppIdentity.developmentBundleIdentifier),
            Set([AppIdentity.developmentBundleIdentifier])
        )
        XCTAssertEqual(
            AppIdentity.instanceBundleNames(bundleIdentifier: AppIdentity.developmentBundleIdentifier),
            Set([AppIdentity.developmentBundleName])
        )
        XCTAssertEqual(
            AppIdentity.instanceAppNames(bundleIdentifier: AppIdentity.developmentBundleIdentifier),
            AppIdentity.developmentAppNames
        )

        XCTAssertEqual(
            AppIdentity.instanceBundleIdentifiers(bundleIdentifier: AppIdentity.cleanupStableBundleIdentifier),
            Set([AppIdentity.cleanupStableBundleIdentifier, AppIdentity.transitionStableBundleIdentifier])
        )
        XCTAssertTrue(AppIdentity.instanceAppNames(bundleIdentifier: AppIdentity.cleanupStableBundleIdentifier).contains("Dockmint"))
        XCTAssertFalse(AppIdentity.instanceAppNames(bundleIdentifier: AppIdentity.developmentBundleIdentifier).contains("Dockmint"))
    }
}
