import XCTest

final class DockDecisionEngineXCTest: XCTestCase {
    func testAppExposeInteractionActiveWithInvocationToken() {
        XCTAssertTrue(
            DockDecisionEngine.isAppExposeInteractionActive(
                hasInvocationToken: true,
                frontmostBefore: nil,
                hasTrackingState: false,
                isRecentInteraction: false
            )
        )
    }

    func testAppExposeInteractionActiveWhenDockFrontmostAndTracked() {
        XCTAssertTrue(
            DockDecisionEngine.isAppExposeInteractionActive(
                hasInvocationToken: false,
                frontmostBefore: "com.apple.dock",
                hasTrackingState: true,
                isRecentInteraction: true
            )
        )
    }

    func testFirstClickAppExposeGate() {
        XCTAssertFalse(DockDecisionEngine.shouldRunFirstClickAppExpose(windowCount: 0, requiresMultipleWindows: false))
        XCTAssertFalse(DockDecisionEngine.shouldRunFirstClickAppExpose(windowCount: 1, requiresMultipleWindows: true))
        XCTAssertTrue(DockDecisionEngine.shouldRunFirstClickAppExpose(windowCount: 2, requiresMultipleWindows: true))
    }

    func testPlainFirstClickConsumeBehavior() {
        XCTAssertFalse(
            DockDecisionEngine.shouldConsumeFirstClickPlainAction(
                firstClickBehavior: .activateApp,
                isRunning: true,
                windowCount: 2
            )
        )

        XCTAssertTrue(
            DockDecisionEngine.shouldConsumeFirstClickPlainAction(
                firstClickBehavior: .bringAllToFront,
                isRunning: true,
                windowCount: 2
            )
        )

        XCTAssertFalse(
            DockDecisionEngine.shouldConsumeFirstClickPlainAction(
                firstClickBehavior: .appExpose,
                isRunning: true,
                windowCount: 2
            )
        )
    }

    func testScrollDirectionResolutionUsesEventDeltaSign() {
        XCTAssertEqual(
            DockDecisionEngine.resolvedScrollDirection(delta: 1),
            .up
        )
        XCTAssertEqual(
            DockDecisionEngine.resolvedScrollDirection(delta: -1),
            .down
        )
    }
}
