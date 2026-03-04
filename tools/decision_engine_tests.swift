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

    print("Decision engine tests passed")
}

@main
struct DecisionEngineTestRunner {
    static func main() {
        runDecisionEngineTests()
    }
}
