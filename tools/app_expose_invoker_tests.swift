import AppKit

// Standalone non-UI harness: dispatches are injected and never reach the user's Dock.
enum Logger {
    static func debug(_ message: @autoclosure () -> String) {}
    static func log(_ message: String) {}
}

@main
struct AppExposeInvokerTests {
    @MainActor
    static func main() {
        let target = "test.target"
        let cases: [(AXError, Bool, Bool, AppExposeInvokeStrategy?)] = [
            (.success, true, false, .dockAccessibility),
            (.cannotComplete, true, false, .dockAccessibility),
            (.actionUnsupported, true, true, .dockNotification),
            (.noValue, true, true, .dockNotification),
            (.invalidUIElement, true, true, .dockNotification),
            (.apiDisabled, true, true, .dockNotification),
            (.failure, true, false, nil),
            (.actionUnsupported, false, false, nil)
        ]
        for (result, targetIsFrontmost, expectsNotification, expectedStrategy) in cases {
            var notificationCount = 0
            var completionCount = 0
            let invoker = AppExposeInvoker(
                performDockAction: { bundle in
                    precondition(bundle == target)
                    return result
                },
                postNotification: { name in
                    precondition(name == "com.apple.expose.front.awake")
                    notificationCount += 1
                    return true
                },
                frontmostBundle: { targetIsFrontmost ? target : "other.app" })
            let receipt = invoker.invokeApplicationWindows(for: target, requireEvidence: false) { outcome in
                completionCount += 1
                precondition(outcome.acknowledged == (result == .success))
                precondition(outcome.strategy == expectedStrategy)
                precondition(outcome.dispatched == (expectedStrategy != nil))
            }
            precondition(receipt.strategy == expectedStrategy)
            precondition(notificationCount == (expectsNotification ? 1 : 0))
            precondition(completionCount == 1)
        }
        let invoker = AppExposeInvoker(
            performDockAction: { _ in .actionUnsupported },
            postNotification: { _ in false },
            frontmostBundle: { target })
        let receipt = invoker.invokeApplicationWindows(for: target, requireEvidence: false) {
            precondition(!$0.dispatched && !$0.confirmed)
        }
        precondition(!receipt.dispatched)

        // Alternate ready/late counts across rapid clicks; neither may strand a native down.
        for actionConsumed in [true, false, true, true, false] {
            precondition(!DockDecisionEngine.shouldConsumeMouseUp(
                actionConsumed: actionConsumed, mouseDownWasConsumed: false, dragged: false))
        }
        precondition(!DockDecisionEngine.shouldConsumeMouseUp(
            actionConsumed: true, mouseDownWasConsumed: true, dragged: true))
        precondition(DockDecisionEngine.shouldConsumeMouseUp(
            actionConsumed: true, mouseDownWasConsumed: true, dragged: false))
        precondition(DockDecisionEngine.shouldCommitAppExposeTracking(
            invocationConfirmed: false, invocationAcknowledged: true))
        precondition(!DockDecisionEngine.shouldCommitAppExposeTracking(
            invocationConfirmed: false, invocationAcknowledged: false))
        print("App Exposé dispatch and click pairing regressions passed")
    }
}
