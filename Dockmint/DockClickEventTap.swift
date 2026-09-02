import Cocoa

enum ScrollDirection {
    case up
    case down
}

enum ClickPhase {
    case down
    case dragged
    case up
}

final class DockClickEventTap {
    static let syntheticClickUserData: Int64 = 0xD0C0A11
    static let syntheticReleasePassthroughUserData: Int64 = 0xD0C0A12
    private static let invertDiscreteScrollDirectionKey = "invertDiscreteScrollDirection"

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var clickHandler: ((CGPoint, Int, Int, CGEventFlags, ClickPhase) -> Bool)? // Returns true if event should be consumed
    private var scrollHandler: ((CGPoint, ScrollDirection, CGEventFlags) -> Bool)? // Returns true if event should be consumed
    private var anyEventHandler: ((CGEventType) -> Void)?
    private var syntheticReleaseHandler: (() -> Void)?
    private var tapTimeoutHandler: (() -> Void)?

    private(set) var lastStartError: String?

    private var continuousScrollGesture = ContinuousScrollGestureState()
    private var leftMouseDownPoint: CGPoint?
    private var leftMouseDownButton: Int?
    private var leftMouseDownFlags: CGEventFlags?
    private var leftMouseDownUptime: TimeInterval?
    private var leftMouseDownWasConsumed = false
    private var leftMouseDragExceededThreshold = false
    private let leftMouseDragThreshold: CGFloat = 6
    private let duplicateMouseDownSuppressionWindow: TimeInterval = 0.35
    private var timeoutPassThroughUntilUptime: TimeInterval = 0
    private let timeoutPassThroughCooldown: TimeInterval = 0.18

    private static func replayConsumedMouseDownForDrag(event: CGEvent,
                                                       at downPoint: CGPoint,
                                                       buttonNumber: Int,
                                                       flags: CGEventFlags) {
        event.type = .leftMouseDown
        event.location = downPoint
        event.flags = flags
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(buttonNumber))
        event.setIntegerValueField(.mouseEventClickState, value: 1)
    }

    func start(
        clickHandler: @escaping (CGPoint, Int, Int, CGEventFlags, ClickPhase) -> Bool,
        scrollHandler: @escaping (CGPoint, ScrollDirection, CGEventFlags) -> Bool,
        anyEventHandler: ((CGEventType) -> Void)? = nil,
        syntheticReleaseHandler: (() -> Void)? = nil,
        tapTimeoutHandler: (() -> Void)? = nil
    ) -> Bool {
        stop()
        self.clickHandler = clickHandler
        self.scrollHandler = scrollHandler
        self.anyEventHandler = anyEventHandler
        self.syntheticReleaseHandler = syntheticReleaseHandler
        self.tapTimeoutHandler = tapTimeoutHandler
        self.lastStartError = nil

        // Capture both mouse clicks and scroll wheel events
        let clickDownMask = (1 << CGEventType.leftMouseDown.rawValue)
        let clickUpMask = (1 << CGEventType.leftMouseUp.rawValue)
        let clickDragMask = (1 << CGEventType.leftMouseDragged.rawValue)
        let scrollMask = (1 << CGEventType.scrollWheel.rawValue)
        let mask = clickDownMask | clickUpMask | clickDragMask | scrollMask
        
        Logger.log("Attempting to create event tap.")
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: { _, type, event, refcon in
                                              let coordinator = Unmanaged<DockClickEventTap>.fromOpaque(refcon!).takeUnretainedValue()

                                              coordinator.anyEventHandler?(type)
                                               
                                              var shouldConsume = false
                                              switch type {
                                              case .tapDisabledByTimeout:
                                                  Logger.log("DockClickEventTap: Tap disabled by timeout; resetting state, enabling pass-through cooldown, and re-enabling tap.")
                                                  coordinator.recoverAfterTapTimeout()
                                                  if let tapPort = coordinator.eventTap {
                                                      CGEvent.tapEnable(tap: tapPort, enable: true)
                                                  }
                                                  return Unmanaged.passUnretained(event)
                                              case .tapDisabledByUserInput:
                                                  Logger.log("DockClickEventTap: Tap disabled by user input; re-enabling.")
                                                  if let tapPort = coordinator.eventTap {
                                                      CGEvent.tapEnable(tap: tapPort, enable: true)
                                                  }
                                                  return Unmanaged.passUnretained(event)
                                              case .leftMouseDown:
                                                  shouldConsume = coordinator.didReceiveClick(event: event, phase: .down)
                                              case .leftMouseDragged:
                                                  shouldConsume = coordinator.didReceiveClick(event: event, phase: .dragged)
                                              case .leftMouseUp:
                                                  shouldConsume = coordinator.didReceiveClick(event: event, phase: .up)
                                              case .scrollWheel:
                                                  shouldConsume = coordinator.didReceiveScroll(event: event)
                                              default:
                                                  break
                                              }
                                              
                                              // Return nil to consume the event, or the event to let it pass through
                                              return shouldConsume ? nil : Unmanaged.passUnretained(event)
                                          },
                                          userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())) else {
            Logger.log("Failed to create event tap (tapCreate returned nil).")
            lastStartError = "CGEvent.tapCreate returned nil (missing permission or tap blocked)"
            return false
        }

        eventTap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            lastStartError = "Failed to create run loop source for event tap"
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
            runLoopSource = nil
            return false
        }

        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Logger.log("Event tap run loop source added and enabled.")
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            Logger.log("Event tap disabled.")
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            Logger.log("Event tap run loop source removed.")
        }
        runLoopSource = nil
        eventTap = nil
        clickHandler = nil
        scrollHandler = nil
        anyEventHandler = nil
        syntheticReleaseHandler = nil
        tapTimeoutHandler = nil
        timeoutPassThroughUntilUptime = 0
        resetInteractionState()
    }

    private func resetInteractionState() {
        continuousScrollGesture = ContinuousScrollGestureState()
        leftMouseDownPoint = nil
        leftMouseDownButton = nil
        leftMouseDownFlags = nil
        leftMouseDownUptime = nil
        leftMouseDownWasConsumed = false
        leftMouseDragExceededThreshold = false
    }

    private func recoverAfterTapTimeout() {
        resetInteractionState()
        timeoutPassThroughUntilUptime = ProcessInfo.processInfo.systemUptime + timeoutPassThroughCooldown
        let handler = tapTimeoutHandler
        DispatchQueue.main.async {
            handler?()
        }
    }

    private func isTimeoutPassThroughCooldownActive() -> Bool {
        ProcessInfo.processInfo.systemUptime < timeoutPassThroughUntilUptime
    }

    private func sourceBundleIdentifier(for event: CGEvent) -> String? {
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        guard sourcePID > 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid_t(sourcePID))?.bundleIdentifier
    }

    private func didReceiveClick(event: CGEvent, phase: ClickPhase) -> Bool {
        let sourceUserData = event.getIntegerValueField(.eventSourceUserData)
        if sourceUserData == DockClickEventTap.syntheticReleasePassthroughUserData {
            // This event exists only to restore Dock/AppKit pressed-state semantics after we
            // consume a real click-up. The original physical mouse-up already cleared our
            // tracking state, so a delayed synthetic release must never wipe a newer in-flight
            // physical click.
            syntheticReleaseHandler?()
            if leftMouseDownPoint != nil {
                Logger.debug("DockClickEventTap: Passthrough synthetic release event during active click; preserving tracking state")
            } else {
                Logger.debug("DockClickEventTap: Passthrough synthetic release event")
            }
            return false
        }

        if isTimeoutPassThroughCooldownActive() {
            return false
        }

        let location = event.location
        let buttonNumber = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        let clickCount = Int(event.getIntegerValueField(.mouseEventClickState))
        let currentFlags = event.flags

        switch phase {
        case .down:
            let nowUptime = ProcessInfo.processInfo.systemUptime
            if let existingPoint = leftMouseDownPoint,
               let existingButton = leftMouseDownButton,
               let existingUptime = leftMouseDownUptime {
                let dx = location.x - existingPoint.x
                let dy = location.y - existingPoint.y
                let distance = hypot(dx, dy)
                let withinWindow = nowUptime - existingUptime <= duplicateMouseDownSuppressionWindow
                if existingButton == buttonNumber && withinWindow && distance <= leftMouseDragThreshold {
                    Logger.debug("DockClickEventTap: Healing duplicate mouse down by restarting click tracking (distance=\(distance), dt=\(nowUptime - existingUptime))")
                    leftMouseDownPoint = nil
                    leftMouseDownButton = nil
                    leftMouseDownFlags = nil
                    leftMouseDownUptime = nil
                    leftMouseDownWasConsumed = false
                    leftMouseDragExceededThreshold = false
                }
                else {
                    Logger.debug("DockClickEventTap: Resetting stale pending mouse down before starting a new click")
                    leftMouseDownPoint = nil
                    leftMouseDownButton = nil
                    leftMouseDownFlags = nil
                    leftMouseDownUptime = nil
                    leftMouseDownWasConsumed = false
                    leftMouseDragExceededThreshold = false
                }
            }

            leftMouseDownPoint = location
            leftMouseDownButton = buttonNumber
            leftMouseDownFlags = currentFlags
            leftMouseDownUptime = nowUptime
            leftMouseDownWasConsumed = false
            leftMouseDragExceededThreshold = false
            Logger.debug("DockClickEventTap: Raw click down at \(location.x), \(location.y) (button: \(buttonNumber), clickCount: \(clickCount))")
            let shouldConsume = clickHandler?(location, buttonNumber, clickCount, currentFlags, .down) ?? false
            leftMouseDownWasConsumed = shouldConsume
            Logger.debug("DockClickEventTap: Click down consume=\(shouldConsume)")
            return shouldConsume

        case .dragged:
            if let downPoint = leftMouseDownPoint, !leftMouseDragExceededThreshold {
                let dx = location.x - downPoint.x
                let dy = location.y - downPoint.y
                if hypot(dx, dy) >= leftMouseDragThreshold {
                    leftMouseDragExceededThreshold = true
                    let downButton = leftMouseDownButton ?? buttonNumber
                    let downFlags = leftMouseDownFlags ?? currentFlags
                    Logger.debug("DockClickEventTap: Drag threshold exceeded (distance=\(hypot(dx, dy)))")
                    _ = clickHandler?(location, downButton, clickCount, downFlags, .dragged)
                    if DockDecisionEngine.shouldReplayConsumedMouseDownForDrag(
                        mouseDownWasConsumed: leftMouseDownWasConsumed,
                        dragThresholdExceeded: leftMouseDragExceededThreshold
                    ) {
                        // The Dock cannot begin a reorder if our configured click action consumed
                        // the physical mouse-down. Replace this first threshold-crossing drag event
                        // with that down event; later drag events and mouse-up continue normally.
                        Self.replayConsumedMouseDownForDrag(event: event,
                                                           at: downPoint,
                                                           buttonNumber: downButton,
                                                           flags: downFlags)
                        Logger.debug("DockClickEventTap: Replaying consumed mouse down to begin Dock drag")
                    }
                }
            }
            return false

        case .up:
            let downButton = leftMouseDownButton ?? buttonNumber
            let downFlags = leftMouseDownFlags ?? currentFlags
            let dragged = leftMouseDragExceededThreshold
            Logger.debug("DockClickEventTap: Raw click up at \(location.x), \(location.y) (button: \(downButton), clickCount: \(clickCount), dragged: \(dragged))")
            let shouldConsume = clickHandler?(location, downButton, clickCount, downFlags, .up) ?? false
            leftMouseDownPoint = nil
            leftMouseDownButton = nil
            leftMouseDownFlags = nil
            leftMouseDownUptime = nil
            leftMouseDownWasConsumed = false
            leftMouseDragExceededThreshold = false
            if dragged {
                Logger.debug("DockClickEventTap: Suppressing consume on mouse up due to drag")
                return false
            }
            Logger.debug("DockClickEventTap: Click up consume=\(shouldConsume)")
            return shouldConsume
        }
    }
    
    private func didReceiveScroll(event: CGEvent) -> Bool {
        if isTimeoutPassThroughCooldownActive() {
            return false
        }

        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        if isContinuous {
            let disposition = continuousScrollGesture.disposition(
                nowUptime: ProcessInfo.processInfo.systemUptime,
                scrollPhase: Int(event.getIntegerValueField(.scrollWheelEventScrollPhase)),
                momentumPhase: Int(event.getIntegerValueField(.scrollWheelEventMomentumPhase))
            )
            switch disposition {
            case .evaluate:
                break
            case .returnLatched(let consume):
                return consume
            case .passThrough:
                return false
            }
        }

        let location = event.location
        let flags = event.flags

        let nsEvent = NSEvent(cgEvent: event)
        let primaryAxis = DecisionScrollAxisDelta(
            pointDelta: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
            fixedDelta: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) / 256.0,
            coarseDelta: event.getDoubleValueField(.scrollWheelEventDeltaAxis1),
            appKitDelta: Double(nsEvent?.scrollingDeltaY ?? 0)
        )
        let alternateAxis = DecisionScrollAxisDelta(
            pointDelta: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
            fixedDelta: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) / 256.0,
            coarseDelta: event.getDoubleValueField(.scrollWheelEventDeltaAxis2),
            appKitDelta: Double(nsEvent?.scrollingDeltaX ?? 0)
        )
        let prefersAlternateAxis = flags.contains(.maskShift)
        let resolvedDelta = DockDecisionEngine.resolvedScrollDeltaWithSource(primaryAxis: primaryAxis,
                                                                             alternateAxis: alternateAxis,
                                                                             isContinuous: isContinuous,
                                                                             prefersAlternateAxis: prefersAlternateAxis)
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        let userOverrideInvertDiscrete = UserDefaults.standard.bool(forKey: Self.invertDiscreteScrollDirectionKey)
        let invertDiscreteDirection = DockDecisionEngine.shouldInvertDiscreteScrollDirection(
            isContinuous: isContinuous,
            userOverride: userOverrideInvertDiscrete
        )
        let inversionApplied = DockDecisionEngine.shouldApplyDiscreteScrollInversion(isContinuous: isContinuous,
                                                                                     invertDiscreteDirection: invertDiscreteDirection,
                                                                                     deltaSource: resolvedDelta.source)
        let effectiveDelta = DockDecisionEngine.effectiveScrollDelta(delta: resolvedDelta,
                                                                     isContinuous: isContinuous,
                                                                     invertDiscreteDirection: invertDiscreteDirection)
        // Require a small threshold so accidental micro-movements are ignored, but single notches still count.
        let threshold = 0.2
        if abs(effectiveDelta) < threshold {
            Logger.debug("DockClickEventTap: Scroll delta below threshold at \(location.x), \(location.y) (yAppKit: \(primaryAxis.appKitDelta), yPoint: \(primaryAxis.pointDelta), yFixed: \(primaryAxis.fixedDelta), yCoarse: \(primaryAxis.coarseDelta), xAppKit: \(alternateAxis.appKitDelta), xPoint: \(alternateAxis.pointDelta), xFixed: \(alternateAxis.fixedDelta), xCoarse: \(alternateAxis.coarseDelta), prefersAlternateAxis: \(prefersAlternateAxis), sourcePID: \(sourcePID), sourceBundle: \(sourceBundleIdentifier(for: event) ?? "nil"), inverted: \(nsEvent?.isDirectionInvertedFromDevice ?? false), deltaSource: \(resolvedDelta.source.rawValue), reverseMouseScrollActions: \(invertDiscreteDirection), flipDiscreteApplied: \(inversionApplied), rawDelta: \(resolvedDelta.value), effectiveDelta: \(effectiveDelta), continuous: \(isContinuous)); ignoring")
            return false
        }
        
        // Route Up/Down by the effective delta sign for this event/device.
        // This respects per-device direction settings (trackpad vs mouse) and
        // third-party remappers (e.g. LinearMouse) that transform events upstream.
        let effectiveResolvedDelta = ResolvedScrollDelta(value: effectiveDelta, source: resolvedDelta.source)
        let appKitInterpretedUsesContentDirection = resolvedDelta.source.isAppKitInterpreted && invertDiscreteDirection
        let resolvedDirection = DockDecisionEngine.resolvedScrollDirection(
            delta: effectiveResolvedDelta,
            appKitInterpretedUsesContentDirection: appKitInterpretedUsesContentDirection
        )
        let direction: ScrollDirection = resolvedDirection == .up ? .up : .down

        Logger.debug("DockClickEventTap: Raw scroll at \(location.x), \(location.y) (yAppKit: \(primaryAxis.appKitDelta), yPoint: \(primaryAxis.pointDelta), yFixed: \(primaryAxis.fixedDelta), yCoarse: \(primaryAxis.coarseDelta), xAppKit: \(alternateAxis.appKitDelta), xPoint: \(alternateAxis.pointDelta), xFixed: \(alternateAxis.fixedDelta), xCoarse: \(alternateAxis.coarseDelta), prefersAlternateAxis: \(prefersAlternateAxis), sourcePID: \(sourcePID), sourceBundle: \(sourceBundleIdentifier(for: event) ?? "nil"), inverted: \(nsEvent?.isDirectionInvertedFromDevice ?? false), deltaSource: \(resolvedDelta.source.rawValue), appKitContentMapping: \(appKitInterpretedUsesContentDirection), reverseMouseScrollActions: \(invertDiscreteDirection), flipDiscreteApplied: \(inversionApplied), rawDelta: \(resolvedDelta.value), effectiveDelta: \(effectiveDelta), dir: \(direction == .up ? "up" : "down"), continuous: \(isContinuous))")
        let shouldConsume = scrollHandler?(location, direction, flags) ?? false
        Logger.debug("DockClickEventTap: Scroll consume=\(shouldConsume)")

        if isContinuous {
            continuousScrollGesture.latch(consume: shouldConsume)
        }
        return shouldConsume
    }
}
