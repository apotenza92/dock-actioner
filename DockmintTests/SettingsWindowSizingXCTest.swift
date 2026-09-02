import XCTest

final class SettingsWindowSizingXCTest: XCTestCase {
    func testOnboardingHeightFitsRenderedContentInsteadOfCurrentWindow() {
        XCTAssertEqual(
            SettingsWindowSizing.onboardingFrameHeight(
                contentHeight: 520,
                windowChromeHeight: 28
            ),
            548
        )
    }

    func testOnboardingHeightFitsShortCompletionContent() {
        XCTAssertEqual(
            SettingsWindowSizing.onboardingFrameHeight(
                contentHeight: 180,
                windowChromeHeight: 28
            ),
            208
        )
    }

    func testOnboardingHeightIncludesAllRenderedContent() {
        XCTAssertEqual(
            SettingsWindowSizing.onboardingFrameHeight(
                contentHeight: 900,
                windowChromeHeight: 28,
                maximumFrameHeight: 760
            ),
            760
        )
    }

    func testExpandedOnboardingFrameRemainsInsideVisibleScreen() {
        let frame = SettingsWindowSizing.onboardingFrame(
            currentFrame: CGRect(x: 200, y: 155, width: 420, height: 640),
            targetHeight: 900,
            visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 900)
        )

        XCTAssertEqual(frame, CGRect(x: 200, y: 25, width: 420, height: 900))
    }
}
