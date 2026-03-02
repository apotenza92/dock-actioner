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

    static func resolvedScrollDirection(delta: Double) -> DecisionScrollDirection {
        // Use event delta direction directly. macOS (and input tools like LinearMouse)
        // already apply per-device scroll direction policy before we receive the event.
        // This keeps mapping aligned with the user's actual device expectations.
        return delta > 0 ? .up : .down
    }
}
