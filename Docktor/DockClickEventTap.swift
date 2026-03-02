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

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var clickHandler: ((CGPoint, Int, CGEventFlags, ClickPhase) -> Bool)? // Returns true if event should be consumed
    private var scrollHandler: ((CGPoint, ScrollDirection, CGEventFlags) -> Bool)? // Returns true if event should be consumed
    private var anyEventHandler: ((CGEventType) -> Void)?
    private var syntheticReleaseHandler: (() -> Void)?

    private(set) var lastStartError: String?

    private var continuousScrollActive = false
    private var continuousScrollConsume = false
    private var lastContinuousScrollTime: TimeInterval = 0
    private var leftMouseDownPoint: CGPoint?
    private var leftMouseDownButton: Int?
    private var leftMouseDownFlags: CGEventFlags?
    private var leftMouseDragExceededThreshold = false
    private let leftMouseDragThreshold: CGFloat = 6

    func start(
        clickHandler: @escaping (CGPoint, Int, CGEventFlags, ClickPhase) -> Bool,
        scrollHandler: @escaping (CGPoint, ScrollDirection, CGEventFlags) -> Bool,
        anyEventHandler: ((CGEventType) -> Void)? = nil,
        syntheticReleaseHandler: (() -> Void)? = nil
    ) -> Bool {
        stop()
        self.clickHandler = clickHandler
        self.scrollHandler = scrollHandler
        self.anyEventHandler = anyEventHandler
        self.syntheticReleaseHandler = syntheticReleaseHandler
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
                                              case .tapDisabledByTimeout, .tapDisabledByUserInput:
                                                  Logger.log("DockClickEventTap: Tap disabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input")); re-enabling.")
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
        continuousScrollActive = false
        continuousScrollConsume = false
        lastContinuousScrollTime = 0
        leftMouseDownPoint = nil
        leftMouseDownButton = nil
        leftMouseDownFlags = nil
        leftMouseDragExceededThreshold = false
    }

    private func didReceiveClick(event: CGEvent, phase: ClickPhase) -> Bool {
        let sourceUserData = event.getIntegerValueField(.eventSourceUserData)
        if sourceUserData == DockClickEventTap.syntheticReleasePassthroughUserData {
            syntheticReleaseHandler?()
            Logger.debug("DockClickEventTap: Passthrough synthetic release event")
            return false
        }

        let location = event.location
        let buttonNumber = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        let currentFlags = event.flags

        switch phase {
        case .down:
            leftMouseDownPoint = location
            leftMouseDownButton = buttonNumber
            leftMouseDownFlags = currentFlags
            leftMouseDragExceededThreshold = false
            Logger.debug("DockClickEventTap: Raw click down at \(location.x), \(location.y) (button: \(buttonNumber))")
            let shouldConsume = clickHandler?(location, buttonNumber, currentFlags, .down) ?? false
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
                    _ = clickHandler?(location, downButton, downFlags, .dragged)
                }
            }
            return false

        case .up:
            let downButton = leftMouseDownButton ?? buttonNumber
            let downFlags = leftMouseDownFlags ?? currentFlags
            let dragged = leftMouseDragExceededThreshold
            Logger.debug("DockClickEventTap: Raw click up at \(location.x), \(location.y) (button: \(downButton), dragged: \(dragged))")
            let shouldConsume = clickHandler?(location, downButton, downFlags, .up) ?? false
            leftMouseDownPoint = nil
            leftMouseDownButton = nil
            leftMouseDownFlags = nil
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
        let location = event.location
        let flags = event.flags
        
        // Use the first non-zero delta we can get, preferring point deltas for sensitivity.
        let pointDelta = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) // pixel-ish for trackpads
        let fixedDelta = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) / 256.0 // convert 16.16 fixed to float
        let coarseDelta = event.getDoubleValueField(.scrollWheelEventDeltaAxis1) // wheel notch count
        let delta = [pointDelta, fixedDelta, coarseDelta].first(where: { $0 != 0 }) ?? 0

        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let scrollPhase = Int(event.getIntegerValueField(.scrollWheelEventScrollPhase))
        let momentumPhase = Int(event.getIntegerValueField(.scrollWheelEventMomentumPhase))

        if isContinuous {
            // Collapse trackpad/magic mouse scroll into a single logical gesture for action triggers.
            // We still decide whether to consume the whole gesture based on the first eligible event.
            let now = ProcessInfo.processInfo.systemUptime
            let resetAfterSilence: TimeInterval = 0.25
            if continuousScrollActive, now - lastContinuousScrollTime > resetAfterSilence {
                continuousScrollActive = false
                continuousScrollConsume = false
            }
            lastContinuousScrollTime = now

            // New gesture start hint.
            let beganMask = 1 | 16 // began | mayBegin
            if (scrollPhase & beganMask) != 0 {
                continuousScrollActive = false
                continuousScrollConsume = false
            }

            // Ignore momentum-only sequences when we didn't start consuming.
            if !continuousScrollActive, momentumPhase != 0 {
                return false
            }

            if continuousScrollActive {
                return continuousScrollConsume
            }
        }
        
        // Require a small threshold so accidental micro-movements are ignored, but single notches still count.
        let threshold = 0.2
        if abs(delta) < threshold {
            Logger.debug("DockClickEventTap: Scroll delta below threshold (\(delta)); ignoring")
            return isContinuous ? continuousScrollConsume : false
        }
        
        // Treat "up" / "down" as physical gesture direction.
        // CGEvent already reflects the user's configured scrolling behavior,
        // so avoid applying an additional inversion based on system preferences.
        let direction: ScrollDirection = delta > 0 ? .up : .down

        Logger.debug("DockClickEventTap: Raw scroll at \(location.x), \(location.y) (delta: \(delta), dir: \(direction == .up ? "up" : "down"), continuous: \(isContinuous))")
        let shouldConsume = scrollHandler?(location, direction, flags) ?? false
        Logger.debug("DockClickEventTap: Scroll consume=\(shouldConsume)")

        if isContinuous {
            continuousScrollActive = true
            continuousScrollConsume = shouldConsume
        }
        return shouldConsume
    }
}
