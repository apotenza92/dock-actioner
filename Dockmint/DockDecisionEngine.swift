import Foundation

struct DecisionScrollAxisDelta {
    let pointDelta: Double
    let fixedDelta: Double
    let coarseDelta: Double
    let appKitDelta: Double
}

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

enum DecisionScrollDeltaSource: String, Equatable {
    case appKit
    case continuousPoint
    case continuousFixed
    case continuousCoarse
    case discreteMajorityPoint
    case discreteMajorityFixed
    case discreteMajorityCoarse
    case discreteFallbackFixed
    case discreteFallbackCoarse
    case discreteFallbackPoint
    case none

    var isAppKitInterpreted: Bool {
        self == .appKit
    }
}

struct ResolvedScrollDelta: Equatable {
    let value: Double
    let source: DecisionScrollDeltaSource

    var usesAppKitInterpretedDelta: Bool {
        source.isAppKitInterpreted
    }
}

struct EventTapPerformanceSnapshot: Equatable {
    let eventCount: UInt64
    let eventsOver5Milliseconds: UInt64
    let eventsOver10Milliseconds: UInt64
    let eventsOver50Milliseconds: UInt64
    let timeoutCount: UInt64
    let maximumDurationMilliseconds: Double
}

final class EventTapPerformanceTelemetry: @unchecked Sendable {
    private let lock = NSLock()
    private var eventCount: UInt64 = 0
    private var eventsOver5Milliseconds: UInt64 = 0
    private var eventsOver10Milliseconds: UInt64 = 0
    private var eventsOver50Milliseconds: UInt64 = 0
    private var timeoutCount: UInt64 = 0
    private var maximumDurationMilliseconds: Double = 0

    func recordHandlerDuration(_ duration: TimeInterval) {
        let milliseconds = duration * 1_000
        lock.lock()
        eventCount += 1
        if milliseconds >= 5 { eventsOver5Milliseconds += 1 }
        if milliseconds >= 10 { eventsOver10Milliseconds += 1 }
        if milliseconds >= 50 { eventsOver50Milliseconds += 1 }
        maximumDurationMilliseconds = max(maximumDurationMilliseconds, milliseconds)
        lock.unlock()
    }

    func recordTimeout() {
        lock.lock()
        timeoutCount += 1
        lock.unlock()
    }

    func snapshot() -> EventTapPerformanceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return EventTapPerformanceSnapshot(eventCount: eventCount,
                                           eventsOver5Milliseconds: eventsOver5Milliseconds,
                                           eventsOver10Milliseconds: eventsOver10Milliseconds,
                                           eventsOver50Milliseconds: eventsOver50Milliseconds,
                                           timeoutCount: timeoutCount,
                                           maximumDurationMilliseconds: maximumDurationMilliseconds)
    }

    func reset() {
        lock.lock()
        eventCount = 0
        eventsOver5Milliseconds = 0
        eventsOver10Milliseconds = 0
        eventsOver50Milliseconds = 0
        timeoutCount = 0
        maximumDurationMilliseconds = 0
        lock.unlock()
    }
}

enum ContinuousScrollGestureDisposition: Equatable {
    case evaluate
    case returnLatched(Bool)
    case passThrough
}

struct ContinuousScrollGestureState {
    private(set) var isActive = false
    private var consume = false
    private var lastEventUptime: TimeInterval = 0

    mutating func disposition(nowUptime: TimeInterval,
                              scrollPhase: Int,
                              momentumPhase: Int,
                              resetAfterSilence: TimeInterval = 0.25) -> ContinuousScrollGestureDisposition {
        if isActive, nowUptime - lastEventUptime > resetAfterSilence {
            isActive = false
            consume = false
        }
        lastEventUptime = nowUptime

        let beganMask = 1 | 16 // began | mayBegin
        if (scrollPhase & beganMask) != 0 {
            isActive = false
            consume = false
        }

        if !isActive, momentumPhase != 0 {
            return .passThrough
        }
        if isActive {
            return .returnLatched(consume)
        }
        return .evaluate
    }

    mutating func latch(consume: Bool) {
        isActive = true
        self.consume = consume
    }
}

enum DockDecisionEngine {
    static func shouldReplayConsumedMouseDownForDrag(mouseDownWasConsumed: Bool,
                                                     dragThresholdExceeded: Bool) -> Bool {
        mouseDownWasConsumed && dragThresholdExceeded
    }

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

    static func shouldResetStaleAppExposeTracking(trackedBundle: String?,
                                                  clickedBundle: String,
                                                  frontmostBefore: String?,
                                                  isRecentInteraction: Bool) -> Bool {
        guard let trackedBundle else { return false }
        guard trackedBundle == clickedBundle else { return false }
        guard frontmostBefore == clickedBundle else { return false }
        return !isRecentInteraction
    }

    static func appExposeTrackingExpiryDelay(timeSinceLastInteraction: TimeInterval,
                                             expiryWindow: TimeInterval,
                                             minimumDelay: TimeInterval) -> TimeInterval? {
        guard timeSinceLastInteraction < expiryWindow else { return nil }
        return max(minimumDelay, expiryWindow - timeSinceLastInteraction)
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

    static func shouldConsumeActiveClickAction(action: DecisionDockAction,
                                               canRunAppExpose: Bool) -> Bool {
        switch action {
        case .none:
            return false
        case .activateApp,
             .hideApp,
             .minimizeAll,
             .quitApp,
             .bringAllToFront,
             .hideOthers,
             .singleAppMode:
            return true
        case .appExpose:
            _ = canRunAppExpose
            // App Exposé now always follows the single-click pass-through path.
            return false
        }
    }

    static func shouldRecoverDockPressedState(after action: DecisionDockAction) -> Bool {
        switch action {
        case .none:
            return false
        case .appExpose:
            return false
        case .hideApp,
             .quitApp:
            return false
        case .activateApp,
             .minimizeAll,
             .bringAllToFront,
             .hideOthers,
             .singleAppMode:
            return true
        }
    }

    static func shouldConsumeFolderMouseDown(isConfigured: Bool,
                                             opensInDock: Bool) -> Bool {
        guard isConfigured else { return false }
        // Non-Dock folder actions should not leak the initial press into the Dock, otherwise
        // the Dock can still open the stack/popover while Dockmint also opens Finder.
        return !opensInDock
    }

    static func shouldConsumeFolderMouseUp(isConfigured: Bool,
                                           opensInDock: Bool) -> Bool {
        guard isConfigured else { return false }
        // Let Dock-owned actions keep native stack press/drag/drop behavior.
        return !opensInDock
    }

    static func shouldFinishConsumedModifierClickBeforeMouseUp(consumeClick: Bool,
                                                               action: DecisionDockAction,
                                                               hasModifier: Bool,
                                                               isDeferredForDoubleClick: Bool) -> Bool {
        guard consumeClick else { return false }
        guard hasModifier else { return false }
        guard !isDeferredForDoubleClick else { return false }

        switch action {
        case .none, .appExpose:
            return false
        case .activateApp,
             .hideApp,
             .minimizeAll,
             .quitApp,
             .bringAllToFront,
             .hideOthers,
             .singleAppMode:
            return true
        }
    }

    static func shouldConsumePendingMouseDown(consumeClick: Bool,
                                              isDeferredAppExposeWindowCount: Bool,
                                              shouldFinishModifierClickEarly: Bool) -> Bool {
        if isDeferredAppExposeWindowCount {
            // Window counting completes after mouse-down so the event tap stays responsive.
            // Keep the real down event available to the Dock: if the resolved count later
            // fails the App Expose gate, the physical up can pass through as a complete
            // native click instead of relying on manual activation plus a synthetic release.
            return false
        }

        return consumeClick || shouldFinishModifierClickEarly
    }

    /// Returns nil when the asynchronous window count is not ready. Callers must fail open
    /// in that case so the physical Dock click retains its native down/up lifecycle.
    static func shouldRunDeferredAppExpose(cachedWindowCount: Int?,
                                           requiresMultipleWindows: Bool) -> Bool? {
        guard let cachedWindowCount else { return nil }
        return shouldRunFirstClickAppExpose(windowCount: cachedWindowCount,
                                            requiresMultipleWindows: requiresMultipleWindows)
    }

    static func resolveVisibleWindowState(cachedValue: Bool?,
                                          query: () -> Bool) -> Bool {
        cachedValue ?? query()
    }

    static func canReuseMouseDownDockTarget(mouseDown: CGPoint,
                                            mouseUp: CGPoint,
                                            movementThreshold: CGFloat = 6) -> Bool {
        hypot(mouseUp.x - mouseDown.x, mouseUp.y - mouseDown.y) < movementThreshold
    }

    static func shouldConsumeDeferredScrollAction(action: DecisionDockAction,
                                                  isRunning: Bool) -> Bool {
        switch action {
        case .none, .appExpose:
            return false
        case .activateApp, .quitApp:
            return isRunning
        case .hideApp, .minimizeAll, .bringAllToFront, .hideOthers, .singleAppMode:
            return true
        }
    }

    static func resolvedScrollDelta(primaryAxis: DecisionScrollAxisDelta,
                                    alternateAxis: DecisionScrollAxisDelta? = nil,
                                    isContinuous: Bool,
                                    prefersAlternateAxis: Bool = false) -> Double {
        resolvedScrollDeltaWithSource(primaryAxis: primaryAxis,
                                      alternateAxis: alternateAxis,
                                      isContinuous: isContinuous,
                                      prefersAlternateAxis: prefersAlternateAxis).value
    }

    static func resolvedScrollDeltaWithSource(primaryAxis: DecisionScrollAxisDelta,
                                              alternateAxis: DecisionScrollAxisDelta? = nil,
                                              isContinuous: Bool,
                                              prefersAlternateAxis: Bool = false) -> ResolvedScrollDelta {
        let primaryDelta = resolvedScrollDeltaWithSource(axis: primaryAxis, isContinuous: isContinuous)

        guard let alternateAxis else {
            return primaryDelta
        }

        let alternateDelta = resolvedScrollDeltaWithSource(axis: alternateAxis, isContinuous: isContinuous)
        guard prefersAlternateAxis else {
            return primaryDelta
        }

        if abs(alternateDelta.value) > abs(primaryDelta.value) {
            return alternateDelta
        }

        if primaryDelta.value == 0 {
            return alternateDelta
        }

        return primaryDelta
    }

    private static func resolvedScrollDeltaWithSource(axis: DecisionScrollAxisDelta,
                                                      isContinuous: Bool) -> ResolvedScrollDelta {
        // Prefer AppKit's interpreted delta when available. It represents how regular macOS
        // apps see the scroll event after system/device policy and upstream transforms.
        if axis.appKitDelta != 0 {
            return ResolvedScrollDelta(value: axis.appKitDelta, source: .appKit)
        }

        if isContinuous {
            // Trackpad/magic mouse: point deltas are the most expressive signal.
            if axis.pointDelta != 0 { return ResolvedScrollDelta(value: axis.pointDelta, source: .continuousPoint) }
            if axis.fixedDelta != 0 { return ResolvedScrollDelta(value: axis.fixedDelta, source: .continuousFixed) }
            if axis.coarseDelta != 0 { return ResolvedScrollDelta(value: axis.coarseDelta, source: .continuousCoarse) }
            return ResolvedScrollDelta(value: 0, source: .none)
        }

        // Discrete wheel devices can have remappers that rewrite only a subset of fields.
        // If at least two fields agree on sign, follow that majority sign.
        let fields: [(value: Double, source: DecisionScrollDeltaSource)] = [
            (axis.pointDelta, .discreteMajorityPoint),
            (axis.fixedDelta, .discreteMajorityFixed),
            (axis.coarseDelta, .discreteMajorityCoarse),
        ].filter { $0.value != 0 }
        let positiveCount = fields.filter { $0.value > 0 }.count
        let negativeCount = fields.filter { $0.value < 0 }.count

        if positiveCount >= 2 || negativeCount >= 2 {
            let majorityPositive = positiveCount > negativeCount
            let matching = fields.filter { majorityPositive ? ($0.value > 0) : ($0.value < 0) }
            if let strongest = matching.max(by: { abs($0.value) < abs($1.value) }) {
                return ResolvedScrollDelta(value: strongest.value, source: strongest.source)
            }
        }

        // Tie/unknown fallback: fixed-point, then coarse notch, then point.
        if axis.fixedDelta != 0 { return ResolvedScrollDelta(value: axis.fixedDelta, source: .discreteFallbackFixed) }
        if axis.coarseDelta != 0 { return ResolvedScrollDelta(value: axis.coarseDelta, source: .discreteFallbackCoarse) }
        if axis.pointDelta != 0 { return ResolvedScrollDelta(value: axis.pointDelta, source: .discreteFallbackPoint) }
        return ResolvedScrollDelta(value: 0, source: .none)
    }

    static func shouldInvertDiscreteScrollDirection(isContinuous: Bool,
                                                    userOverride: Bool) -> Bool {
        guard !isContinuous else { return false }
        return userOverride
    }

    static func shouldApplyDiscreteScrollInversion(isContinuous: Bool,
                                                   invertDiscreteDirection: Bool,
                                                   deltaSource: DecisionScrollDeltaSource) -> Bool {
        guard !isContinuous, invertDiscreteDirection else { return false }
        return !deltaSource.isAppKitInterpreted
    }

    static func effectiveScrollDelta(delta: Double,
                                     isContinuous: Bool,
                                     invertDiscreteDirection: Bool) -> Double {
        guard !isContinuous, invertDiscreteDirection else { return delta }
        return -delta
    }

    static func effectiveScrollDelta(delta: ResolvedScrollDelta,
                                     isContinuous: Bool,
                                     invertDiscreteDirection: Bool) -> Double {
        guard shouldApplyDiscreteScrollInversion(isContinuous: isContinuous,
                                                 invertDiscreteDirection: invertDiscreteDirection,
                                                 deltaSource: delta.source) else { return delta.value }
        return -delta.value
    }

    static func resolvedScrollDirection(delta: Double) -> DecisionScrollDirection {
        return delta > 0 ? .up : .down
    }

    static func resolvedScrollDirection(delta: ResolvedScrollDelta,
                                        appKitInterpretedUsesContentDirection: Bool) -> DecisionScrollDirection {
        if delta.source.isAppKitInterpreted, appKitInterpretedUsesContentDirection {
            return delta.value > 0 ? .down : .up
        }
        return resolvedScrollDirection(delta: delta.value)
    }
}
