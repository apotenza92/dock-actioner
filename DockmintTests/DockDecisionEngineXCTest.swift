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

    func testShippedDefaultAppExposeDecisionMatrix() {
        // Shipped defaults use a single-click App Exposé path gated to multiple windows.
        XCTAssertFalse(DockDecisionEngine.shouldRunFirstClickAppExpose(windowCount: 0, requiresMultipleWindows: true))
        XCTAssertFalse(DockDecisionEngine.shouldRunFirstClickAppExpose(windowCount: 1, requiresMultipleWindows: true))
        XCTAssertTrue(DockDecisionEngine.shouldRunFirstClickAppExpose(windowCount: 2, requiresMultipleWindows: true))
        XCTAssertFalse(DockDecisionEngine.shouldConsumeActiveClickAction(action: .appExpose, canRunAppExpose: true))
        XCTAssertFalse(DockDecisionEngine.shouldConsumeActiveClickAction(action: .appExpose, canRunAppExpose: false))
    }

    func testAppExposeInvocationConfirmationRules() {
        XCTAssertFalse(
            DockDecisionEngine.appExposeInvocationConfirmed(
                dispatched: false,
                evidence: true,
                requireEvidence: true
            )
        )
        XCTAssertFalse(
            DockDecisionEngine.appExposeInvocationConfirmed(
                dispatched: true,
                evidence: false,
                requireEvidence: true
            )
        )
        XCTAssertTrue(
            DockDecisionEngine.appExposeInvocationConfirmed(
                dispatched: true,
                evidence: true,
                requireEvidence: true
            )
        )
        XCTAssertTrue(
            DockDecisionEngine.appExposeInvocationConfirmed(
                dispatched: true,
                evidence: false,
                requireEvidence: false
            )
        )
    }

    func testExposeTrackingCommitDecision() {
        XCTAssertTrue(DockDecisionEngine.shouldCommitAppExposeTracking(invocationConfirmed: true))
        XCTAssertFalse(DockDecisionEngine.shouldCommitAppExposeTracking(invocationConfirmed: false))
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

    func testActiveClickConsumeBehavior() {
        XCTAssertFalse(
            DockDecisionEngine.shouldConsumeActiveClickAction(
                action: .none,
                canRunAppExpose: true
            )
        )

        XCTAssertTrue(
            DockDecisionEngine.shouldConsumeActiveClickAction(
                action: .hideApp,
                canRunAppExpose: true
            )
        )

        XCTAssertTrue(
            DockDecisionEngine.shouldConsumeActiveClickAction(
                action: .activateApp,
                canRunAppExpose: true
            )
        )

        XCTAssertTrue(
            DockDecisionEngine.shouldConsumeActiveClickAction(
                action: .bringAllToFront,
                canRunAppExpose: true
            )
        )

        XCTAssertTrue(
            DockDecisionEngine.shouldConsumeActiveClickAction(
                action: .hideOthers,
                canRunAppExpose: true
            )
        )

        XCTAssertFalse(
            DockDecisionEngine.shouldConsumeActiveClickAction(
                action: .appExpose,
                canRunAppExpose: false
            )
        )
        
        XCTAssertFalse(
            DockDecisionEngine.shouldConsumeActiveClickAction(
                action: .appExpose,
                canRunAppExpose: true
            )
        )

        XCTAssertTrue(
            DockDecisionEngine.shouldConsumeActiveClickAction(
                action: .singleAppMode,
                canRunAppExpose: true
            )
        )

        XCTAssertTrue(
            DockDecisionEngine.shouldConsumeActiveClickAction(
                action: .minimizeAll,
                canRunAppExpose: true
            )
        )

        XCTAssertTrue(
            DockDecisionEngine.shouldConsumeActiveClickAction(
                action: .quitApp,
                canRunAppExpose: true
            )
        )
    }

    func testDockPressedStateRecoveryRules() {
        XCTAssertFalse(
            DockDecisionEngine.shouldRecoverDockPressedState(after: .none)
        )

        XCTAssertFalse(
            DockDecisionEngine.shouldRecoverDockPressedState(after: .appExpose)
        )

        XCTAssertFalse(
            DockDecisionEngine.shouldRecoverDockPressedState(after: .hideApp)
        )

        XCTAssertFalse(
            DockDecisionEngine.shouldRecoverDockPressedState(after: .quitApp)
        )

        XCTAssertTrue(
            DockDecisionEngine.shouldRecoverDockPressedState(after: .minimizeAll)
        )
    }

    func testFolderMouseDownConsumptionSemantics() {
        XCTAssertFalse(
            DockDecisionEngine.shouldConsumeFolderMouseDown(
                isConfigured: false,
                opensInDock: false
            )
        )

        XCTAssertFalse(
            DockDecisionEngine.shouldConsumeFolderMouseDown(
                isConfigured: true,
                opensInDock: true
            )
        )

        XCTAssertTrue(
            DockDecisionEngine.shouldConsumeFolderMouseDown(
                isConfigured: true,
                opensInDock: false
            )
        )
    }

    func testFolderMouseUpConsumptionSemantics() {
        XCTAssertFalse(
            DockDecisionEngine.shouldConsumeFolderMouseUp(
                isConfigured: false,
                opensInDock: false
            )
        )

        XCTAssertFalse(
            DockDecisionEngine.shouldConsumeFolderMouseUp(
                isConfigured: true,
                opensInDock: true
            )
        )

        XCTAssertTrue(
            DockDecisionEngine.shouldConsumeFolderMouseUp(
                isConfigured: true,
                opensInDock: false
            )
        )
    }

    func testConsumedModifierClickWatchdogRules() {
        XCTAssertTrue(
            DockDecisionEngine.shouldFinishConsumedModifierClickBeforeMouseUp(
                consumeClick: true,
                action: .quitApp,
                hasModifier: true,
                isDeferredForDoubleClick: false
            )
        )

        XCTAssertFalse(
            DockDecisionEngine.shouldFinishConsumedModifierClickBeforeMouseUp(
                consumeClick: true,
                action: .appExpose,
                hasModifier: true,
                isDeferredForDoubleClick: false
            )
        )

        XCTAssertFalse(
            DockDecisionEngine.shouldFinishConsumedModifierClickBeforeMouseUp(
                consumeClick: true,
                action: .quitApp,
                hasModifier: true,
                isDeferredForDoubleClick: true
            )
        )

        XCTAssertFalse(
            DockDecisionEngine.shouldFinishConsumedModifierClickBeforeMouseUp(
                consumeClick: true,
                action: .quitApp,
                hasModifier: false,
                isDeferredForDoubleClick: false
            )
        )
    }

    func testEffectiveScrollDeltaCanFlipDiscreteDirectionOnly() {
        XCTAssertEqual(
            DockDecisionEngine.effectiveScrollDelta(
                delta: 3,
                isContinuous: false,
                invertDiscreteDirection: false
            ),
            3
        )

        XCTAssertEqual(
            DockDecisionEngine.effectiveScrollDelta(
                delta: 3,
                isContinuous: false,
                invertDiscreteDirection: true
            ),
            -3
        )

        XCTAssertEqual(
            DockDecisionEngine.effectiveScrollDelta(
                delta: 3,
                isContinuous: true,
                invertDiscreteDirection: true
            ),
            3
        )
    }

    func testAutoDiscreteInvertHeuristic() {
        XCTAssertFalse(
            DockDecisionEngine.shouldInvertDiscreteScrollDirection(
                isContinuous: true,
                sourceBundleIdentifier: "com.caldis.Mos",
                knownRemapperRunning: true,
                userOverride: false
            )
        )

        XCTAssertTrue(
            DockDecisionEngine.shouldInvertDiscreteScrollDirection(
                isContinuous: false,
                sourceBundleIdentifier: nil,
                knownRemapperRunning: false,
                userOverride: true
            )
        )

        XCTAssertTrue(
            DockDecisionEngine.shouldInvertDiscreteScrollDirection(
                isContinuous: false,
                sourceBundleIdentifier: "com.caldis.Mos",
                knownRemapperRunning: false,
                userOverride: false
            )
        )

        XCTAssertTrue(
            DockDecisionEngine.shouldInvertDiscreteScrollDirection(
                isContinuous: false,
                sourceBundleIdentifier: nil,
                knownRemapperRunning: true,
                userOverride: false
            )
        )

        XCTAssertFalse(
            DockDecisionEngine.shouldInvertDiscreteScrollDirection(
                isContinuous: false,
                sourceBundleIdentifier: nil,
                knownRemapperRunning: false,
                userOverride: false
            )
        )
    }

    func testResolvedScrollDeltaPrefersAppKitInterpretedDeltaWhenAvailable() {
        XCTAssertEqual(
            DockDecisionEngine.resolvedScrollDelta(
                primaryAxis: DecisionScrollAxisDelta(
                    pointDelta: -8,
                    fixedDelta: -1,
                    coarseDelta: 1,
                    appKitDelta: 6
                ),
                isContinuous: false
            ),
            6
        )
    }

    func testResolvedScrollDeltaPrefersPointForContinuousDevices() {
        XCTAssertEqual(
            DockDecisionEngine.resolvedScrollDelta(
                primaryAxis: DecisionScrollAxisDelta(
                    pointDelta: -8,
                    fixedDelta: -1,
                    coarseDelta: 1,
                    appKitDelta: 0
                ),
                isContinuous: true
            ),
            -8
        )
    }

    func testResolvedScrollDeltaUsesMajoritySignForDiscreteWheelConflicts() {
        XCTAssertEqual(
            DockDecisionEngine.resolvedScrollDelta(
                primaryAxis: DecisionScrollAxisDelta(
                    pointDelta: 12,
                    fixedDelta: 1,
                    coarseDelta: -1,
                    appKitDelta: 0
                ),
                isContinuous: false
            ),
            12
        )
    }

    func testResolvedScrollDeltaFallsBackWhenNoMajorityForDiscreteWheel() {
        XCTAssertEqual(
            DockDecisionEngine.resolvedScrollDelta(
                primaryAxis: DecisionScrollAxisDelta(
                    pointDelta: -8,
                    fixedDelta: 0,
                    coarseDelta: 1,
                    appKitDelta: 0
                ),
                isContinuous: false
            ),
            1
        )

        XCTAssertEqual(
            DockDecisionEngine.resolvedScrollDelta(
                primaryAxis: DecisionScrollAxisDelta(
                    pointDelta: 0,
                    fixedDelta: 2,
                    coarseDelta: 0,
                    appKitDelta: 0
                ),
                isContinuous: false
            ),
            2
        )
    }

    func testResolvedScrollDeltaCanUseAlternateAxisForShiftModifiedScroll() {
        XCTAssertEqual(
            DockDecisionEngine.resolvedScrollDelta(
                primaryAxis: DecisionScrollAxisDelta(
                    pointDelta: 0,
                    fixedDelta: 0,
                    coarseDelta: 0,
                    appKitDelta: 0
                ),
                alternateAxis: DecisionScrollAxisDelta(
                    pointDelta: -9,
                    fixedDelta: 0,
                    coarseDelta: 0,
                    appKitDelta: 0
                ),
                isContinuous: true,
                prefersAlternateAxis: true
            ),
            -9
        )

        XCTAssertEqual(
            DockDecisionEngine.resolvedScrollDelta(
                primaryAxis: DecisionScrollAxisDelta(
                    pointDelta: -1,
                    fixedDelta: 0,
                    coarseDelta: 0,
                    appKitDelta: 0
                ),
                alternateAxis: DecisionScrollAxisDelta(
                    pointDelta: -7,
                    fixedDelta: 0,
                    coarseDelta: 0,
                    appKitDelta: 0
                ),
                isContinuous: true,
                prefersAlternateAxis: true
            ),
            -7
        )
    }

    func testDockHitTestClassifiesApplicationDockItemFromBundleURL() {
        let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app", isDirectory: true)

        XCTAssertEqual(
            DockHitTest.classifyDockItem(subrole: "AXApplicationDockItem", url: finderURL),
            .appDockIcon("com.apple.finder")
        )
    }

    func testDockHitTestRequiresBundleURLForApplicationDockItem() {
        XCTAssertNil(
            DockHitTest.classifyDockItem(subrole: "AXApplicationDockItem", url: nil)
        )

        let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        XCTAssertNil(
            DockHitTest.classifyDockItem(subrole: "AXApplicationDockItem", url: applicationsURL)
        )
    }

    func testDockHitTestClassifiesFolderDockItemFromFileURL() {
        let downloadsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)

        XCTAssertEqual(
            DockHitTest.classifyDockItem(subrole: "AXFolderDockItem", url: downloadsURL),
            .folderDockItem(downloadsURL)
        )
    }

    func testDockHitTestIgnoresNonAppDockSubroles() {
        XCTAssertNil(
            DockHitTest.classifyDockItem(subrole: "AXTrashDockItem", url: nil)
        )
        XCTAssertNil(
            DockHitTest.classifyDockItem(subrole: "AXSeparatorDockItem", url: nil)
        )
        XCTAssertNil(
            DockHitTest.classifyDockItem(subrole: nil, url: nil)
        )
    }
}
