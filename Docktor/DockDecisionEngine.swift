import Foundation

enum DecisionFirstClickBehavior {
    case activateApp
    case bringAllToFront
    case appExpose
}

enum DecisionDockAction {
    case none
    case activateApp
    case hideApp
    case appExpose
    case minimizeAll
    case quitApp
    case bringAllToFront
    case hideOthers
    case singleAppMode
}

enum DecisionScrollDirection: Equatable {
    case up
    case down
}

enum DockDecisionEngine {
    static func isAppExposeInteractionActive(hasInvocationToken: Bool,
                                             frontmostBefore: String?,
                                             hasTrackingState: Bool,
                                             isRecentInteraction: Bool) -> Bool {
        if hasInvocationToken {
            return true
        }

        return frontmostBefore == "com.apple.dock" && hasTrackingState && isRecentInteraction
    }

    static func appExposeInvocationConfirmed(dispatched: Bool,
                                             evidence: Bool,
                                             requireEvidence: Bool) -> Bool {
        if requireEvidence {
            return dispatched && evidence
        }
        return dispatched
    }

    static func shouldCommitAppExposeTracking(invocationConfirmed: Bool) -> Bool {
        invocationConfirmed
    }

    static func shouldRunFirstClickAppExpose(windowCount: Int,
                                             requiresMultipleWindows: Bool) -> Bool {
        guard windowCount > 0 else { return false }
        if requiresMultipleWindows && windowCount < 2 {
            return false
        }
        return true
    }

    static func shouldConsumeFirstClickPlainAction(firstClickBehavior: DecisionFirstClickBehavior,
                                                   isRunning: Bool,
                                                   windowCount: Int) -> Bool {
        switch firstClickBehavior {
        case .activateApp:
            return false
        case .bringAllToFront:
            return isRunning
        case .appExpose:
            guard isRunning else { return false }
            // App Exposé should stay pass-through to preserve Dock click semantics.
            if windowCount == 0 {
                return false
            }
            return false
        }
    }

    static func shouldConsumeFirstClickModifierAction(action: DecisionDockAction,
                                                      isRunning: Bool,
                                                      canRunAppExpose: Bool) -> Bool {
        guard isRunning else { return false }

        switch action {
        case .none:
            return false
        case .appExpose:
            _ = canRunAppExpose
            return false
        default:
            return true
        }
    }

    static func resolvedScrollDelta(pointDelta: Double,
                                    fixedDelta: Double,
                                    coarseDelta: Double,
                                    isContinuous: Bool) -> Double {
        // Continuous devices (trackpad/magic mouse) are best represented by point deltas.
        // Discrete wheels should prefer coarse/fixed deltas because some per-device remappers
        // only rewrite those fields (which can leave point delta sign stale).
        let priority = isContinuous
            ? [pointDelta, fixedDelta, coarseDelta]
            : [coarseDelta, fixedDelta, pointDelta]

        return priority.first(where: { $0 != 0 }) ?? 0
    }

    static func resolvedScrollDirection(delta: Double) -> DecisionScrollDirection {
        return delta > 0 ? .up : .down
    }
}
