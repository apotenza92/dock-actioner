import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func runDecisionEngineTests() {
    // isAppExposeInteractionActive
    expect(
        DockDecisionEngine.isAppExposeInteractionActive(
            hasInvocationToken: true,
            frontmostBefore: nil,
            hasTrackingState: false,
            isRecentInteraction: false
        ) == true,
        "invocation token should force active"
    )

    expect(
        DockDecisionEngine.isAppExposeInteractionActive(
            hasInvocationToken: false,
            frontmostBefore: "com.apple.dock",
            hasTrackingState: true,
            isRecentInteraction: true
        ) == true,
        "dock frontmost + tracking + recent should be active"
    )

    expect(
        DockDecisionEngine.isAppExposeInteractionActive(
            hasInvocationToken: false,
            frontmostBefore: "com.apple.dock",
            hasTrackingState: false,
            isRecentInteraction: true
        ) == false,
        "dock frontmost without tracking should be inactive"
    )

    // shouldRunFirstClickAppExpose
    expect(
        DockDecisionEngine.shouldRunFirstClickAppExpose(windowCount: 0, requiresMultipleWindows: false) == false,
        "no windows should not run first-click app expose"
    )
    expect(
        DockDecisionEngine.shouldRunFirstClickAppExpose(windowCount: 1, requiresMultipleWindows: true) == false,
        "single window should not run when multiple required"
    )
    expect(
        DockDecisionEngine.shouldRunFirstClickAppExpose(windowCount: 2, requiresMultipleWindows: true) == true,
        "two windows should run when multiple required"
    )

    // appExposeInvocationConfirmed / shouldCommitAppExposeTracking
    expect(
        DockDecisionEngine.appExposeInvocationConfirmed(
            dispatched: true,
            evidence: false,
            requireEvidence: true
        ) == false,
        "require-evidence mode should reject dispatch without evidence"
    )

    expect(
        DockDecisionEngine.appExposeInvocationConfirmed(
            dispatched: true,
            evidence: false,
            requireEvidence: false
        ) == true,
        "best-effort mode should accept dispatch without evidence"
    )

    expect(
        DockDecisionEngine.shouldCommitAppExposeTracking(invocationConfirmed: true) == true,
        "confirmed invocation should commit expose tracking"
    )

    expect(
        DockDecisionEngine.shouldCommitAppExposeTracking(invocationConfirmed: false) == false,
        "unconfirmed invocation should not commit expose tracking"
    )

    // shouldConsumeFirstClickPlainAction
    expect(
        DockDecisionEngine.shouldConsumeFirstClickPlainAction(
            firstClickBehavior: .activateApp,
            isRunning: true,
            windowCount: 3
        ) == false,
        "activateApp plain first-click should pass through"
    )

    expect(
        DockDecisionEngine.shouldConsumeFirstClickPlainAction(
            firstClickBehavior: .bringAllToFront,
            isRunning: true,
            windowCount: 3
        ) == true,
        "bringAllToFront plain first-click should consume when app running"
    )

    expect(
        DockDecisionEngine.shouldConsumeFirstClickPlainAction(
            firstClickBehavior: .bringAllToFront,
            isRunning: false,
            windowCount: 0
        ) == false,
        "bringAllToFront plain first-click should pass through when app not running"
    )

    expect(
        DockDecisionEngine.shouldConsumeFirstClickPlainAction(
            firstClickBehavior: .appExpose,
            isRunning: true,
            windowCount: 2
        ) == false,
        "appExpose plain first-click should remain pass-through"
    )

    // shouldConsumeFirstClickModifierAction
    expect(
        DockDecisionEngine.shouldConsumeFirstClickModifierAction(
            action: .none,
            isRunning: true,
            canRunAppExpose: true
        ) == false,
        "modifier action none should pass through"
    )

    expect(
        DockDecisionEngine.shouldConsumeFirstClickModifierAction(
            action: .hideApp,
            isRunning: true,
            canRunAppExpose: true
        ) == true,
        "modifier hideApp should consume"
    )

    expect(
        DockDecisionEngine.shouldConsumeFirstClickModifierAction(
            action: .appExpose,
            isRunning: true,
            canRunAppExpose: true
        ) == false,
        "modifier appExpose should pass through"
    )

    expect(
        DockDecisionEngine.shouldConsumeFirstClickModifierAction(
            action: .hideApp,
            isRunning: false,
            canRunAppExpose: true
        ) == false,
        "modifier action should pass through when app not running"
    )

    expect(
        DockDecisionEngine.shouldFinishConsumedModifierClickBeforeMouseUp(
            consumeClick: true,
            action: .quitApp,
            hasModifier: true,
            isDeferredForDoubleClick: false
        ) == true,
        "consumed modifier quit should finish before mouse-up"
    )

    expect(
        DockDecisionEngine.shouldFinishConsumedModifierClickBeforeMouseUp(
            consumeClick: true,
            action: .appExpose,
            hasModifier: true,
            isDeferredForDoubleClick: false
        ) == false,
        "modifier appExpose should not finish early"
    )

    expect(
        DockDecisionEngine.shouldFinishConsumedModifierClickBeforeMouseUp(
            consumeClick: true,
            action: .quitApp,
            hasModifier: true,
            isDeferredForDoubleClick: true
        ) == false,
        "deferred modifier clicks should not finish early"
    )

    // shouldConsumeActiveClickAction
    expect(
        DockDecisionEngine.shouldConsumeActiveClickAction(
            action: .none,
            canRunAppExpose: true
        ) == false,
        "active click none should pass through"
    )

    expect(
        DockDecisionEngine.shouldConsumeActiveClickAction(
            action: .hideApp,
            canRunAppExpose: true
        ) == true,
        "active click hideApp should consume"
    )

    expect(
        DockDecisionEngine.shouldConsumeActiveClickAction(
            action: .activateApp,
            canRunAppExpose: true
        ) == true,
        "active click activateApp should consume"
    )

    expect(
        DockDecisionEngine.shouldConsumeActiveClickAction(
            action: .bringAllToFront,
            canRunAppExpose: true
        ) == true,
        "active click bringAllToFront should consume"
    )

    expect(
        DockDecisionEngine.shouldConsumeActiveClickAction(
            action: .hideOthers,
            canRunAppExpose: true
        ) == true,
        "active click hideOthers should consume"
    )

    expect(
        DockDecisionEngine.shouldConsumeActiveClickAction(
            action: .appExpose,
            canRunAppExpose: true
        ) == false,
        "active click appExpose should stay pass-through when runnable"
    )

    expect(
        DockDecisionEngine.shouldConsumeActiveClickAction(
            action: .appExpose,
            canRunAppExpose: false
        ) == false,
        "active click appExpose should pass through when not runnable"
    )

    expect(
        DockDecisionEngine.shouldConsumeActiveClickAction(
            action: .singleAppMode,
            canRunAppExpose: true
        ) == true,
        "active click singleAppMode should consume"
    )

    expect(
        DockDecisionEngine.shouldConsumeActiveClickAction(
            action: .minimizeAll,
            canRunAppExpose: true
        ) == true,
        "active click minimizeAll should consume"
    )

    expect(
        DockDecisionEngine.shouldConsumeActiveClickAction(
            action: .quitApp,
            canRunAppExpose: true
        ) == true,
        "active click quitApp should consume"
    )

    print("Decision engine tests passed")
}

@main
struct DecisionEngineTestRunner {
    static func main() {
        runDecisionEngineTests()
    }
}
