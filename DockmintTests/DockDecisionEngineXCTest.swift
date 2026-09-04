import XCTest

final class DockDecisionEngineXCTest: XCTestCase {
    func testContinuousScrollGestureReturnsLatchedDecisionUntilNextGesture() {
        var state = ContinuousScrollGestureState()

        XCTAssertEqual(state.disposition(nowUptime: 1, scrollPhase: 1, momentumPhase: 0), .evaluate)
        state.latch(consume: true)
        XCTAssertEqual(state.disposition(nowUptime: 1.01, scrollPhase: 4, momentumPhase: 0), .returnLatched(true))
        XCTAssertEqual(state.disposition(nowUptime: 1.02, scrollPhase: 1, momentumPhase: 0), .evaluate)
    }

    func testContinuousScrollGestureIgnoresOrphanMomentumAndResetsAfterSilence() {
        var state = ContinuousScrollGestureState()

        XCTAssertEqual(state.disposition(nowUptime: 1, scrollPhase: 0, momentumPhase: 2), .passThrough)
        XCTAssertEqual(state.disposition(nowUptime: 2, scrollPhase: 0, momentumPhase: 0), .evaluate)
        state.latch(consume: false)
        XCTAssertEqual(state.disposition(nowUptime: 2.3, scrollPhase: 4, momentumPhase: 0), .evaluate)
    }

    func testConsumedMouseDownIsReplayedWhenMovementBecomesDrag() {
        XCTAssertTrue(
            DockDecisionEngine.shouldReplayConsumedMouseDownForDrag(
                mouseDownWasConsumed: true,
                dragThresholdExceeded: true
            )
        )
        XCTAssertFalse(
            DockDecisionEngine.shouldReplayConsumedMouseDownForDrag(
                mouseDownWasConsumed: false,
                dragThresholdExceeded: true
            )
        )
        XCTAssertFalse(
            DockDecisionEngine.shouldReplayConsumedMouseDownForDrag(
                mouseDownWasConsumed: true,
                dragThresholdExceeded: false
            )
        )
    }

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

    func testStaleAppExposeTrackingResetRules() {
        XCTAssertTrue(
            DockDecisionEngine.shouldResetStaleAppExposeTracking(
                trackedBundle: "com.apple.Safari",
                clickedBundle: "com.apple.Safari",
                frontmostBefore: "com.apple.Safari",
                isRecentInteraction: false
            )
        )

        XCTAssertFalse(
            DockDecisionEngine.shouldResetStaleAppExposeTracking(
                trackedBundle: "com.apple.Safari",
                clickedBundle: "com.apple.Safari",
                frontmostBefore: "com.apple.Safari",
                isRecentInteraction: true
            )
        )

        XCTAssertFalse(
            DockDecisionEngine.shouldResetStaleAppExposeTracking(
                trackedBundle: "com.apple.Safari",
                clickedBundle: "com.apple.finder",
                frontmostBefore: "com.apple.finder",
                isRecentInteraction: false
            )
        )
    }

    func testAppExposeTrackingExpiryDelayRules() {
        let standardDelay = DockDecisionEngine.appExposeTrackingExpiryDelay(
            timeSinceLastInteraction: 0.2,
            expiryWindow: 0.9,
            minimumDelay: 0.05
        )
        XCTAssertNotNil(standardDelay)
        XCTAssertEqual(standardDelay!, 0.7, accuracy: 0.0001)

        let minimumDelay = DockDecisionEngine.appExposeTrackingExpiryDelay(
            timeSinceLastInteraction: 0.88,
            expiryWindow: 0.9,
            minimumDelay: 0.05
        )
        XCTAssertNotNil(minimumDelay)
        XCTAssertEqual(minimumDelay!, 0.05, accuracy: 0.0001)

        XCTAssertNil(
            DockDecisionEngine.appExposeTrackingExpiryDelay(
                timeSinceLastInteraction: 0.9,
                expiryWindow: 0.9,
                minimumDelay: 0.05
            )
        )
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

    func testDeferredAppExposeKeepsMouseDownAvailableForNativeFallback() {
        XCTAssertFalse(
            DockDecisionEngine.shouldConsumePendingMouseDown(
                consumeClick: true,
                isDeferredAppExposeWindowCount: true,
                shouldFinishModifierClickEarly: false
            )
        )

        XCTAssertTrue(
            DockDecisionEngine.shouldConsumePendingMouseDown(
                consumeClick: true,
                isDeferredAppExposeWindowCount: false,
                shouldFinishModifierClickEarly: false
            )
        )
    }

    func testDeferredAppExposeFailsOpenWhenWindowCountIsNotReady() {
        XCTAssertNil(
            DockDecisionEngine.shouldRunDeferredAppExpose(
                cachedWindowCount: nil,
                requiresMultipleWindows: true
            )
        )
        XCTAssertEqual(
            DockDecisionEngine.shouldRunDeferredAppExpose(
                cachedWindowCount: 1,
                requiresMultipleWindows: true
            ),
            false
        )
        XCTAssertEqual(
            DockDecisionEngine.shouldRunDeferredAppExpose(
                cachedWindowCount: 2,
                requiresMultipleWindows: true
            ),
            true
        )
    }

    func testVisibleWindowStateIsResolvedOnlyWhenRequested() {
        var queryCount = 0
        let cached = DockDecisionEngine.resolveVisibleWindowState(cachedValue: true) {
            queryCount += 1
            return false
        }
        XCTAssertTrue(cached)
        XCTAssertEqual(queryCount, 0)

        let resolved = DockDecisionEngine.resolveVisibleWindowState(cachedValue: nil) {
            queryCount += 1
            return false
        }
        XCTAssertFalse(resolved)
        XCTAssertEqual(queryCount, 1)
    }

    func testDockTargetCanBeReusedForStationaryMouseUp() {
        XCTAssertTrue(
            DockDecisionEngine.canReuseMouseDownDockTarget(
                mouseDown: CGPoint(x: 100, y: 200),
                mouseUp: CGPoint(x: 103, y: 204),
                movementThreshold: 6
            )
        )
        XCTAssertFalse(
            DockDecisionEngine.canReuseMouseDownDockTarget(
                mouseDown: CGPoint(x: 100, y: 200),
                mouseUp: CGPoint(x: 107, y: 200),
                movementThreshold: 6
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

    func testDiscreteInvertUsesUserPreferenceOnlyAndNeverContinuousEvents() {
        XCTAssertFalse(
            DockDecisionEngine.shouldInvertDiscreteScrollDirection(
                isContinuous: true,
                userOverride: true
            )
        )

        XCTAssertTrue(
            DockDecisionEngine.shouldInvertDiscreteScrollDirection(
                isContinuous: false,
                userOverride: true
            )
        )

        XCTAssertFalse(
            DockDecisionEngine.shouldInvertDiscreteScrollDirection(
                isContinuous: false,
                userOverride: false
            )
        )
    }

    func testAppKitInterpretedDiscreteDeltaUsesUserControlledReverseMapping() {
        let delta = DockDecisionEngine.resolvedScrollDeltaWithSource(
            primaryAxis: DecisionScrollAxisDelta(
                pointDelta: -12,
                fixedDelta: -1,
                coarseDelta: -1,
                appKitDelta: 6
            ),
            isContinuous: false
        )

        XCTAssertEqual(delta.source, .appKit)
        XCTAssertTrue(
            DockDecisionEngine.shouldInvertDiscreteScrollDirection(
                isContinuous: false,
                userOverride: true
            )
        )
        XCTAssertFalse(
            DockDecisionEngine.shouldApplyDiscreteScrollInversion(
                isContinuous: false,
                invertDiscreteDirection: true,
                deltaSource: delta.source
            )
        )
        XCTAssertEqual(
            DockDecisionEngine.effectiveScrollDelta(
                delta: delta,
                isContinuous: false,
                invertDiscreteDirection: true
            ),
            6
        )
        XCTAssertEqual(
            DockDecisionEngine.resolvedScrollDirection(
                delta: delta,
                appKitInterpretedUsesContentDirection: true
            ),
            .down
        )
    }

    func testNegativeAppKitInterpretedDiscreteDeltaIsNotDoubleInvertedForKnownRemapper() {
        let delta = DockDecisionEngine.resolvedScrollDeltaWithSource(
            primaryAxis: DecisionScrollAxisDelta(
                pointDelta: 12,
                fixedDelta: 1,
                coarseDelta: 1,
                appKitDelta: -6
            ),
            isContinuous: false
        )

        XCTAssertEqual(delta.source, .appKit)
        XCTAssertEqual(
            DockDecisionEngine.effectiveScrollDelta(
                delta: delta,
                isContinuous: false,
                invertDiscreteDirection: true
            ),
            -6
        )
        XCTAssertEqual(
            DockDecisionEngine.resolvedScrollDirection(
                delta: delta,
                appKitInterpretedUsesContentDirection: true
            ),
            .up
        )
    }

    func testRawFallbackScrollDirectionKeepsLegacySignConvention() {
        let delta = ResolvedScrollDelta(value: 6, source: .discreteFallbackFixed)

        XCTAssertEqual(
            DockDecisionEngine.resolvedScrollDirection(
                delta: delta,
                appKitInterpretedUsesContentDirection: false
            ),
            .up
        )
    }

    func testAppKitInterpretedDeltaKeepsLegacySignConventionWithoutRemapperDirectionRequest() {
        let delta = ResolvedScrollDelta(value: 6, source: .appKit)

        XCTAssertEqual(
            DockDecisionEngine.resolvedScrollDirection(
                delta: delta,
                appKitInterpretedUsesContentDirection: false
            ),
            .up
        )
    }

    func testUserOverrideDoesNotInvertAppKitInterpretedDelta() {
        let delta = DockDecisionEngine.resolvedScrollDeltaWithSource(
            primaryAxis: DecisionScrollAxisDelta(
                pointDelta: -12,
                fixedDelta: -1,
                coarseDelta: -1,
                appKitDelta: 6
            ),
            isContinuous: false
        )

        XCTAssertTrue(
            DockDecisionEngine.shouldInvertDiscreteScrollDirection(
                isContinuous: false,
                userOverride: true
            )
        )
        XCTAssertFalse(
            DockDecisionEngine.shouldApplyDiscreteScrollInversion(
                isContinuous: false,
                invertDiscreteDirection: true,
                deltaSource: delta.source
            )
        )
        XCTAssertEqual(
            DockDecisionEngine.effectiveScrollDelta(
                delta: delta,
                isContinuous: false,
                invertDiscreteDirection: true
            ),
            6
        )
    }

    func testRawDiscreteFallbackStillInvertsWhenRemapperDetected() {
        let delta = DockDecisionEngine.resolvedScrollDeltaWithSource(
            primaryAxis: DecisionScrollAxisDelta(
                pointDelta: 0,
                fixedDelta: 2,
                coarseDelta: 0,
                appKitDelta: 0
            ),
            isContinuous: false
        )

        XCTAssertEqual(delta.source, .discreteFallbackFixed)
        XCTAssertTrue(
            DockDecisionEngine.shouldApplyDiscreteScrollInversion(
                isContinuous: false,
                invertDiscreteDirection: true,
                deltaSource: delta.source
            )
        )
        XCTAssertEqual(
            DockDecisionEngine.effectiveScrollDelta(
                delta: delta,
                isContinuous: false,
                invertDiscreteDirection: true
            ),
            -2
        )
    }

    func testContinuousDeltaDoesNotInvertEvenWhenRemapperDetected() {
        let delta = DockDecisionEngine.resolvedScrollDeltaWithSource(
            primaryAxis: DecisionScrollAxisDelta(
                pointDelta: 8,
                fixedDelta: 1,
                coarseDelta: 1,
                appKitDelta: 0
            ),
            isContinuous: true
        )

        XCTAssertEqual(delta.source, .continuousPoint)
        XCTAssertEqual(
            DockDecisionEngine.effectiveScrollDelta(
                delta: delta,
                isContinuous: true,
                invertDiscreteDirection: true
            ),
            8
        )
    }

    func testAlternateAxisAppKitDeltaCarriesSourceAndAvoidsRemapperInversion() {
        let delta = DockDecisionEngine.resolvedScrollDeltaWithSource(
            primaryAxis: DecisionScrollAxisDelta(
                pointDelta: 1,
                fixedDelta: 0,
                coarseDelta: 0,
                appKitDelta: 0
            ),
            alternateAxis: DecisionScrollAxisDelta(
                pointDelta: -9,
                fixedDelta: -1,
                coarseDelta: -1,
                appKitDelta: 10
            ),
            isContinuous: false,
            prefersAlternateAxis: true
        )

        XCTAssertEqual(delta, ResolvedScrollDelta(value: 10, source: .appKit))
        XCTAssertEqual(
            DockDecisionEngine.effectiveScrollDelta(
                delta: delta,
                isContinuous: false,
                invertDiscreteDirection: true
            ),
            10
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

    func testDockHitTestStableMetadataCacheReusesAndInvalidatesValues() {
        var cache = DockHitTestStableMetadataCache()
        var displayLoads = 0
        let point = CGPoint(x: 10, y: 10)

        XCTAssertNotNil(cache.displayBounds(containing: point) {
            displayLoads += 1
            return [CGRect(x: 0, y: 0, width: 100, height: 100)]
        })
        XCTAssertNotNil(cache.displayBounds(containing: point) {
            displayLoads += 1
            return []
        })
        XCTAssertEqual(displayLoads, 1)

        cache.invalidateDisplayBounds()
        XCTAssertNil(cache.displayBounds(containing: point) {
            displayLoads += 1
            return []
        })
        XCTAssertEqual(displayLoads, 2)

        var dockPIDLoads = 0
        XCTAssertEqual(cache.dockProcessIdentifier {
            dockPIDLoads += 1
            return 42
        }, 42)
        XCTAssertEqual(cache.dockProcessIdentifier {
            dockPIDLoads += 1
            return 99
        }, 42)
        XCTAssertEqual(dockPIDLoads, 1)

        cache.invalidateDockProcessIdentifier()
        XCTAssertEqual(cache.dockProcessIdentifier {
            dockPIDLoads += 1
            return 99
        }, 99)
        XCTAssertEqual(dockPIDLoads, 2)
    }

    func testPersistentLogWriterPreservesOrderedMessagesAcrossReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dockmint-log-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("test.log")

        var writer: PersistentLogWriter? = try PersistentLogWriter(url: logURL)
        try writer?.append(line: "first")
        try writer?.append(line: "second")
        try writer?.close()
        writer = nil

        let reopenedWriter = try PersistentLogWriter(url: logURL)
        try reopenedWriter.append(line: "third")
        try reopenedWriter.close()

        XCTAssertEqual(try String(contentsOf: logURL, encoding: .utf8), "first\nsecond\nthird\n")
    }

    func testEventTapPerformanceTelemetryReportsLatencyAndTimeouts() {
        let telemetry = EventTapPerformanceTelemetry()
        telemetry.recordHandlerDuration(0.003)
        telemetry.recordHandlerDuration(0.012)
        telemetry.recordHandlerDuration(0.075)
        telemetry.recordTimeout()

        let snapshot = telemetry.snapshot()
        XCTAssertEqual(snapshot.eventCount, 3)
        XCTAssertEqual(snapshot.eventsOver5Milliseconds, 2)
        XCTAssertEqual(snapshot.eventsOver10Milliseconds, 2)
        XCTAssertEqual(snapshot.eventsOver50Milliseconds, 1)
        XCTAssertEqual(snapshot.timeoutCount, 1)
        XCTAssertEqual(snapshot.maximumDurationMilliseconds, 75, accuracy: 0.001)
    }

    func testDeferredScrollActionPreservesPassThroughSemantics() {
        XCTAssertFalse(DockDecisionEngine.shouldConsumeDeferredScrollAction(action: .none,
                                                                            isRunning: true))
        XCTAssertFalse(DockDecisionEngine.shouldConsumeDeferredScrollAction(action: .appExpose,
                                                                            isRunning: true))
        XCTAssertFalse(DockDecisionEngine.shouldConsumeDeferredScrollAction(action: .activateApp,
                                                                            isRunning: false))
        XCTAssertTrue(DockDecisionEngine.shouldConsumeDeferredScrollAction(action: .activateApp,
                                                                           isRunning: true))
        XCTAssertTrue(DockDecisionEngine.shouldConsumeDeferredScrollAction(action: .hideOthers,
                                                                           isRunning: true))
    }
}
