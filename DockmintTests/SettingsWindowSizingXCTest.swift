import XCTest

final class SettingsWindowSizingXCTest: XCTestCase {
    func testSettingsUseOneCompactFixedContentSize() {
        XCTAssertEqual(SettingsLayout.contentSize, CGSize(width: 789, height: 224))
    }

    func testSwitchingFixedSizePagesPreservesWindowFrame() {
        let initial = CGRect(origin: CGPoint(x: 100, y: 500), size: SettingsLayout.contentSize)
        let refitted = SettingsWindowSizing.topLeftAnchoredFrame(
            currentFrame: initial,
            targetSize: SettingsLayout.contentSize,
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        XCTAssertEqual(refitted, initial)
    }

    func testContentSizeIsLimitedToVisibleDisplay() {
        XCTAssertEqual(SettingsWindowSizing.limitedSize(
            CGSize(width: 1400, height: 1000),
            to: CGSize(width: 1200, height: 780)
        ), CGSize(width: 1200, height: 780))
    }

    func testFirstPresentationCentersOnVisibleDisplay() {
        XCTAssertEqual(SettingsWindowSizing.centeredFrame(
            size: CGSize(width: 600, height: 400),
            in: CGRect(x: 100, y: 25, width: 1400, height: 900)
        ), CGRect(x: 500, y: 275, width: 600, height: 400))
    }

    func testSettingsResizePreservesTopLeftAnchor() {
        let frame = SettingsWindowSizing.topLeftAnchoredFrame(
            currentFrame: CGRect(x: 200, y: 155, width: 700, height: 500),
            targetSize: CGSize(width: 900, height: 600),
            visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 900)
        )
        XCTAssertEqual(frame.minX, 200)
        XCTAssertEqual(frame.maxY, 655)
        XCTAssertEqual(frame.size, CGSize(width: 900, height: 600))
    }

    func testExistingOnboardingMilestonesRemainIncompleteUntilSetupFinishes() {
        for milestone in OnboardingMilestone.allCases where milestone != .completed {
            XCTAssertFalse(milestone.isCompleted)
        }
        XCTAssertTrue(OnboardingMilestone.completed.isCompleted)
    }

    func testPermissionsGateRequiresBothPermissions() {
        XCTAssertFalse(OnboardingSetup.canFinish(accessibilityGranted: false, inputMonitoringGranted: false))
        XCTAssertFalse(OnboardingSetup.canFinish(accessibilityGranted: true, inputMonitoringGranted: false))
        XCTAssertFalse(OnboardingSetup.canFinish(accessibilityGranted: false, inputMonitoringGranted: true))
        XCTAssertTrue(OnboardingSetup.canFinish(accessibilityGranted: true, inputMonitoringGranted: true))
    }
}
