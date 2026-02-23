import AppKit
import Combine
import ApplicationServices

@MainActor
final class DockExposeCoordinator: ObservableObject {
    static let shared = DockExposeCoordinator()

    private let eventTap = DockClickEventTap()
    private let invoker = AppExposeInvoker()
    private let preferences = Preferences.shared
    private var permissionPollTimer: Timer?
    private var lastTriggeredBundle: String? // Track which app we last triggered Exposé for - ignore clicks on same app until different app is clicked
    private var currentExposeApp: String? // Track which app's windows are currently being shown in App Exposé (can differ from lastTriggeredBundle)
    private var appsWithoutWindowsInExpose: Set<String> = [] // Track apps clicked in App Exposé that have no windows
    private var lastScrollBundle: String?
    private var lastScrollDirection: ScrollDirection?
    private var lastScrollTime: TimeInterval?
    private var lastMinimizeToggleTime: [String: TimeInterval] = [:]
    private let minimizeToggleCooldown: TimeInterval = 1.0
    private var pendingClickContext: PendingClickContext?
    private var pendingClickWasDragged = false
    private var appExposeInvocationToken: UUID?
    private var clickRecoveryTokenCounter: UInt64 = 0
    private var clickSequenceCounter: UInt64 = 0

    @Published private(set) var isRunning = false
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var inputMonitoringGranted = CGPreflightListenEventAccess()
    @Published private(set) var secureEventInputEnabled = SecureEventInput.isEnabled()

    // Diagnostics
    @Published private(set) var lastStartError: String?
    @Published private(set) var tapEventsSeen: Int = 0
    @Published private(set) var tapClicksSeen: Int = 0
    @Published private(set) var tapScrollsSeen: Int = 0
    @Published private(set) var lastTapEventAt: Date?
    @Published private(set) var lastTapEventType: String?
    @Published private(set) var lastDockBundleHit: String?
    @Published private(set) var lastDockBundleHitAt: Date?
    @Published var diagnosticsCaptureActive: Bool = false

    @Published private(set) var lastActionExecuted: DockAction?
    @Published private(set) var lastActionExecutedBundle: String?
    @Published private(set) var lastActionExecutedSource: String?
    @Published private(set) var lastActionExecutedAt: Date?

    private struct PendingClickContext {
        let clickSequence: UInt64
        let location: CGPoint
        let buttonNumber: Int
        let flags: CGEventFlags
        let frontmostBefore: String?
        let clickedBundle: String
        let windowCountAtMouseDown: Int?
        let consumeClick: Bool
        let forceFirstClickActivateFallback: Bool
    }

    var isAppExposeShortcutConfigured: Bool {
        invoker.isApplicationWindowsHotKeyConfigured()
    }

    var isEnabled: Bool {
        isRunning && accessibilityGranted && inputMonitoringGranted
    }

    // Backwards compatibility for callers expecting this name.
    var hasAccessibilityPermission: Bool {
        accessibilityGranted
    }

    func refreshPermissionsAndSecurityState() {
        accessibilityGranted = AXIsProcessTrusted()
        inputMonitoringGranted = CGPreflightListenEventAccess()
        secureEventInputEnabled = SecureEventInput.isEnabled()
    }

    func startIfPossible() {
        refreshPermissionsAndSecurityState()
        guard accessibilityGranted else {
            Logger.log("startIfPossible: denied (no accessibility).")
            return
        }
        guard inputMonitoringGranted else {
            Logger.log("startIfPossible: denied (no input monitoring).")
            return
        }
        if secureEventInputEnabled {
            Logger.log("startIfPossible: Secure Event Input is enabled; synthetic hotkeys may be ignored.")
        }
        guard !isRunning else {
            Logger.log("startIfPossible: already running.")
            return
        }
        lastStartError = nil
        isRunning = eventTap.start(
            clickHandler: { [weak self] point, button, flags, phase in
                return self?.handleClick(at: point, buttonNumber: button, flags: flags, phase: phase) ?? false
            },
            scrollHandler: { [weak self] point, direction, flags in
                return self?.handleScroll(at: point, direction: direction, flags: flags) ?? false
            },
            anyEventHandler: { [weak self] type in
                self?.recordTapEvent(type)
            }
        )
        if !isRunning {
            lastStartError = eventTap.lastStartError
            Logger.log("Failed to start event tap. error=\(lastStartError ?? "unknown")")
        } else {
            Logger.log("Event tap started.")
        }
    }

    func stop() {
        eventTap.stop()
        isRunning = false
        Logger.log("Event tap stopped.")
    }

    private enum Edge { case bottom, left, right }

    private func bundleIdentifierNearPoint(_ point: CGPoint) -> String? {
        if let b = DockHitTest.bundleIdentifierAtPoint(point) {
            return b
        }
        // AX hit-testing can be quite sensitive to being exactly on top of the icon; sample a small grid.
        let offsets: [CGFloat] = [-10, 0, 10]
        for dy in offsets {
            for dx in offsets {
                if dx == 0 && dy == 0 { continue }
                let p = CGPoint(x: point.x + dx, y: point.y + dy)
                if let b = DockHitTest.bundleIdentifierAtPoint(p) {
                    return b
                }
            }
        }
        return nil
    }

    private func probeEdgeForBundle(bounds: CGRect,
                                    edge: Edge,
                                    bundleIdentifier: String,
                                    deadline: Date? = nil) -> CGPoint? {
        let margin: CGFloat = 10
        let step: CGFloat = 16
        let startInset: CGFloat = 40
        let depth: CGFloat = 240
        let depthStep: CGFloat = 8

        switch edge {
        case .bottom:
            var y = bounds.maxY - margin
            while y > bounds.maxY - depth {
                if let deadline, Date() > deadline { return nil }
                var x = bounds.minX + startInset
                while x < bounds.maxX - startInset {
                    if let deadline, Date() > deadline { return nil }
                    let p = CGPoint(x: x, y: y)
                    if let bundle = bundleIdentifierNearPoint(p), bundle == bundleIdentifier {
                        return p
                    }
                    x += step
                }
                y -= depthStep
            }
        case .left:
            var x = bounds.minX + margin
            while x < bounds.minX + depth {
                if let deadline, Date() > deadline { return nil }
                var y = bounds.minY + startInset
                while y < bounds.maxY - startInset {
                    if let deadline, Date() > deadline { return nil }
                    let p = CGPoint(x: x, y: y)
                    if let bundle = bundleIdentifierNearPoint(p), bundle == bundleIdentifier {
                        return p
                    }
                    y += step
                }
                x += depthStep
            }
        case .right:
            var x = bounds.maxX - margin
            while x > bounds.maxX - depth {
                if let deadline, Date() > deadline { return nil }
                var y = bounds.minY + startInset
                while y < bounds.maxY - startInset {
                    if let deadline, Date() > deadline { return nil }
                    let p = CGPoint(x: x, y: y)
                    if let bundle = bundleIdentifierNearPoint(p), bundle == bundleIdentifier {
                        return p
                    }
                    y += step
                }
                x -= depthStep
            }
        }
        return nil
    }

    func postSyntheticClick(at point: CGPoint) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        if let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            down.flags = []
            down.setIntegerValueField(.eventSourceUserData, value: DockClickEventTap.syntheticClickUserData)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            up.flags = []
            up.setIntegerValueField(.eventSourceUserData, value: DockClickEventTap.syntheticClickUserData)
            up.post(tap: .cghidEventTap)
        }
    }

    func postSyntheticMouseUpPassthrough(at point: CGPoint, flags: CGEventFlags = []) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        guard let up = CGEvent(mouseEventSource: source,
                               mouseType: .leftMouseUp,
                               mouseCursorPosition: point,
                               mouseButton: .left) else { return }
        up.flags = flags
        up.setIntegerValueField(.eventSourceUserData, value: DockClickEventTap.syntheticReleasePassthroughUserData)
        up.post(tap: .cghidEventTap)
    }

    func postSyntheticScroll(at point: CGPoint, deltaY: Int32) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        guard let ev = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0) else { return }
        ev.location = point
        ev.flags = []
        ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        ev.setIntegerValueField(.eventSourceUserData, value: DockClickEventTap.syntheticClickUserData)
        ev.post(tap: .cghidEventTap)
    }

    private func recordTapEvent(_ type: CGEventType) {
        guard diagnosticsCaptureActive else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            tapEventsSeen += 1
            lastTapEventAt = Date()
            lastTapEventType = String(describing: type)
            switch type {
            case .leftMouseDown:
                tapClicksSeen += 1
            case .scrollWheel:
                tapScrollsSeen += 1
            default:
                break
            }
        }
    }

    func runDiagnosticsCapture(seconds: TimeInterval = 5.0) {
        tapEventsSeen = 0
        tapClicksSeen = 0
        tapScrollsSeen = 0
        lastTapEventAt = nil
        lastTapEventType = nil
        lastDockBundleHit = nil
        lastDockBundleHitAt = nil
        diagnosticsCaptureActive = true

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.diagnosticsCaptureActive = false
        }
    }

    func restart() {
        stop()
        refreshPermissionsAndSecurityState()

        if accessibilityGranted && inputMonitoringGranted {
            startIfPossible()
        } else {
            if !accessibilityGranted {
                requestAccessibilityPermission()
            }
            if !inputMonitoringGranted {
                requestInputMonitoringPermission()
            }
            startWhenPermissionAvailable()
        }
        Logger.log("Restart requested. Accessibility granted: \(accessibilityGranted)")
    }

    func toggle() {
        if isEnabled {
            stop()
        } else {
            refreshPermissionsAndSecurityState()

            if !accessibilityGranted {
                requestAccessibilityPermission()
            }
            if !inputMonitoringGranted {
                requestInputMonitoringPermission()
            }

            if accessibilityGranted && inputMonitoringGranted {
                startIfPossible()
            } else {
                startWhenPermissionAvailable()
            }
        }
        Logger.log("Toggle invoked. isEnabled now: \(isEnabled)")
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        Logger.log("Requested accessibility permission prompt.")
    }

    func requestInputMonitoringPermission() {
        let granted = CGRequestListenEventAccess()
        refreshPermissionsAndSecurityState()
        Logger.log("Requested input monitoring permission prompt. grantedNow=\(granted), preflight=\(inputMonitoringGranted)")
    }

    func startWhenPermissionAvailable(pollInterval: TimeInterval = 1.5) {
        permissionPollTimer?.invalidate()
        permissionPollTimer = Timer.scheduledTimer(timeInterval: pollInterval,
                                                   target: self,
                                                   selector: #selector(handlePermissionPoll(_:)),
                                                   userInfo: nil,
                                                   repeats: true)
    }

    @objc private func handlePermissionPoll(_ timer: Timer) {
        let trusted = AXIsProcessTrusted()
        let input = CGPreflightListenEventAccess()
        accessibilityGranted = trusted
        inputMonitoringGranted = input
        secureEventInputEnabled = SecureEventInput.isEnabled()
        if trusted && input {
            timer.invalidate()
            permissionPollTimer = nil
            startIfPossible()
            Logger.log("Accessibility granted detected via polling; started tap.")
        } else {
            Logger.log("Permissions still not granted (accessibility=\(trusted), input=\(input)); polling continues.")
        }
    }

    private func handleClick(at location: CGPoint, buttonNumber: Int, flags: CGEventFlags, phase: ClickPhase) -> Bool {
        guard buttonNumber == 0 else {
            if phase == .up {
                pendingClickContext = nil
                pendingClickWasDragged = false
            }
            Logger.debug("WORKFLOW: Non-primary mouse button \(buttonNumber) - allowing through")
            return false
        }

        switch phase {
        case .down:
            Logger.debug("WORKFLOW: Click down at \(location.x), \(location.y) button \(buttonNumber)")
            let hitBundle = bundleIdentifierNearPoint(location)
            guard let clickedBundle = hitBundle else {
                if isAppExposeInteractionActive(frontmostBefore: FrontmostAppTracker.frontmostBundleIdentifier()) {
                    Logger.debug("WORKFLOW: Non-Dock click while App Exposé tracking active; clearing tracking state")
                    resetExposeTracking()
                } else if lastTriggeredBundle != nil || currentExposeApp != nil {
                    Logger.debug("WORKFLOW: Non-Dock click while App Exposé tracking active; resetting tracking state")
                    resetExposeTracking()
                }
                pendingClickContext = nil
                pendingClickWasDragged = false
                return false
            }

            if diagnosticsCaptureActive {
                lastDockBundleHit = clickedBundle
                lastDockBundleHitAt = Date()
            }

            clickSequenceCounter += 1
            let clickSequence = clickSequenceCounter
            let frontmostBefore = FrontmostAppTracker.frontmostBundleIdentifier()
            let isRunningAtDown = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == clickedBundle }
            let windowCountAtMouseDown = isRunningAtDown ? WindowManager.totalWindowCount(bundleIdentifier: clickedBundle) : nil
            let context = PendingClickContext(clickSequence: clickSequence,
                                              location: location,
                                              buttonNumber: buttonNumber,
                                              flags: flags,
                                              frontmostBefore: frontmostBefore,
                                              clickedBundle: clickedBundle,
                                              windowCountAtMouseDown: windowCountAtMouseDown,
                                              consumeClick: false,
                                              forceFirstClickActivateFallback: false)
            let consumeClick = shouldConsumeClick(for: context)
            let forceFirstClickActivateFallback = shouldForceFirstClickActivateFallback(for: context)
            pendingClickContext = PendingClickContext(clickSequence: context.clickSequence,
                                                     location: context.location,
                                                     buttonNumber: context.buttonNumber,
                                                     flags: context.flags,
                                                     frontmostBefore: context.frontmostBefore,
                                                     clickedBundle: context.clickedBundle,
                                                     windowCountAtMouseDown: context.windowCountAtMouseDown,
                                                     consumeClick: consumeClick,
                                                     forceFirstClickActivateFallback: forceFirstClickActivateFallback)
            Logger.debug("APP_EXPOSE_TRACE: click=\(clickSequence) phase=down bundle=\(clickedBundle) frontmostBefore=\(frontmostBefore ?? "nil") runningAtDown=\(isRunningAtDown) windowsAtDown=\(windowCountAtMouseDown.map(String.init) ?? "nil") modifier=\(modifierCombination(from: flags).rawValue) firstClickBehavior=\(preferences.firstClickBehavior.rawValue) consumePlanned=\(consumeClick) fallbackLatched=\(forceFirstClickActivateFallback)")
            pendingClickWasDragged = false
            // Never consume mouse-down. Dock needs it to begin drag-reorder interactions.
            return false

        case .dragged:
            if let context = pendingClickContext {
                pendingClickWasDragged = true
                Logger.debug("WORKFLOW: Click became drag; suppressing click action")
                return context.consumeClick
            }
            return false

        case .up:
            guard let context = pendingClickContext else {
                if isAppExposeInteractionActive(frontmostBefore: FrontmostAppTracker.frontmostBundleIdentifier()),
                   let recoveredBundle = bundleIdentifierNearPoint(location) {
                    Logger.debug("WORKFLOW: Recovered App Exposé dock click on mouse-up for \(recoveredBundle)")
                    let recoveredContext = PendingClickContext(clickSequence: 0,
                                                              location: location,
                                                              buttonNumber: buttonNumber,
                                                              flags: flags,
                                                              frontmostBefore: FrontmostAppTracker.frontmostBundleIdentifier(),
                                                              clickedBundle: recoveredBundle,
                                                              windowCountAtMouseDown: nil,
                                                              consumeClick: false,
                                                              forceFirstClickActivateFallback: false)
                    let consumeRecovered = executeClickAction(recoveredContext)
                    return consumeRecovered
                }
                return false
            }

            defer {
                pendingClickContext = nil
                pendingClickWasDragged = false
            }

            if pendingClickWasDragged {
                Logger.debug("WORKFLOW: Drag completed; allowing Dock drop behavior")
                return false
            }

            let windowsAtMouseUp = WindowManager.totalWindowCount(bundleIdentifier: context.clickedBundle)
            Logger.debug("APP_EXPOSE_TRACE: click=\(context.clickSequence) phase=up bundle=\(context.clickedBundle) frontmostBefore=\(context.frontmostBefore ?? "nil") windowsAtDown=\(context.windowCountAtMouseDown.map(String.init) ?? "nil") windowsAtUp=\(windowsAtMouseUp) consumePlanned=\(context.consumeClick) fallbackLatched=\(context.forceFirstClickActivateFallback)")
            let consumeNow = executeClickAction(context)
            if consumeNow != context.consumeClick {
                Logger.debug("WORKFLOW: Click consume mismatch click=\(context.clickSequence) planned=\(context.consumeClick) actual=\(consumeNow)")
            }
            // Only recover Dock pressed state when we actually consumed the click-up.
            // If execution resolved to pass-through, synthetic release can interfere with Dock state.
            let shouldRecoverDockPressedState = consumeNow
            if shouldRecoverDockPressedState {
                clickRecoveryTokenCounter += 1
                let recoveryToken = clickRecoveryTokenCounter
                scheduleDockPressedStateRecovery(at: context.location,
                                                flags: context.flags,
                                                expectedBundle: context.clickedBundle,
                                                clickToken: recoveryToken)
            }
            return consumeNow
        }
    }

    private func scheduleDockPressedStateRecovery(at location: CGPoint,
                                                  flags: CGEventFlags,
                                                  expectedBundle: String,
                                                  clickToken: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { [weak self] in
            guard let self else { return }
            let releasePoint = location
            postSyntheticMouseUpPassthrough(at: releasePoint, flags: flags)
            Logger.debug("WORKFLOW: Posted neutral mouse-up recovery token=\(clickToken) bundle=\(expectedBundle) point=(\(Int(releasePoint.x)),\(Int(releasePoint.y)))")
        }
    }

    private func executeClickAction(_ context: PendingClickContext) -> Bool {
        let location = context.location
        let buttonNumber = context.buttonNumber
        let flags = context.flags
        let frontmostBefore = context.frontmostBefore
        let clickedBundle = context.clickedBundle
        let appExposeActive = isAppExposeInteractionActive(frontmostBefore: frontmostBefore)
        let windowCountNow = WindowManager.totalWindowCount(bundleIdentifier: clickedBundle)

        Logger.debug("WORKFLOW: click=\(context.clickSequence) frontmost=\(frontmostBefore ?? "nil"), clicked=\(clickedBundle), windowsNow=\(windowCountNow), windowsDown=\(context.windowCountAtMouseDown.map(String.init) ?? "nil"), fallbackLatched=\(context.forceFirstClickActivateFallback), lastTriggered=\(lastTriggeredBundle ?? "nil"), currentExpose=\(currentExposeApp ?? "nil")")

        if appExposeActive {
            Logger.debug("WORKFLOW: App Exposé active - standing down and allowing macOS Dock behavior")
            return false
        }

        if let currentApp = currentExposeApp,
           currentApp == clickedBundle,
           lastTriggeredBundle != nil,
           frontmostBefore != clickedBundle {
            if appsWithoutWindowsInExpose.contains(clickedBundle) {
                Logger.debug("WORKFLOW: Second click on app without windows (\(clickedBundle)) - activating and showing main window")
                appsWithoutWindowsInExpose.remove(clickedBundle)
                resetExposeTracking()
                _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: clickedBundle)
                recordActionExecution(action: .activateApp, bundle: clickedBundle, source: "clickTransitionActivate")
                return true
            }

            Logger.debug("WORKFLOW: Deactivate click on currentExposeApp (\(clickedBundle)); exiting App Exposé and activating app")
            exitAppExpose()
            _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: clickedBundle)
            recordActionExecution(action: .activateApp, bundle: clickedBundle, source: "clickTransitionDeactivate")
            return true
        }

        if frontmostBefore != clickedBundle {
            if lastTriggeredBundle != nil {
                Logger.debug("WORKFLOW: App Exposé active - user clicked different app (\(clickedBundle)) to show its windows")

                if !WindowManager.hasVisibleWindows(bundleIdentifier: clickedBundle) {
                    Logger.debug("WORKFLOW: App \(clickedBundle) has no visible windows - tracking for potential second click")
                    appsWithoutWindowsInExpose.insert(clickedBundle)
                } else {
                    appsWithoutWindowsInExpose.remove(clickedBundle)
                }
                currentExposeApp = clickedBundle
                Logger.debug("WORKFLOW: Updated currentExposeApp=\(clickedBundle)")
                return false
            } else {
                Logger.debug("WORKFLOW: Different app clicked; evaluating first-click behavior")
                currentExposeApp = nil
                appsWithoutWindowsInExpose.removeAll()
                return executeFirstClickAction(for: clickedBundle,
                                               flags: flags,
                                               frontmostBefore: frontmostBefore,
                                               forceActivateFallback: context.forceFirstClickActivateFallback)
            }
        }

        if let lastBundle = lastTriggeredBundle, lastBundle == clickedBundle {
            if frontmostBefore == clickedBundle {
                Logger.debug("WORKFLOW: App Exposé already closed for \(clickedBundle); clearing state")
                resetExposeTracking()
            } else {
                Logger.debug("WORKFLOW: Deactivate click on original trigger app (\(clickedBundle)), staying on this app")
                resetExposeTracking()
                recordActionExecution(action: .none, bundle: clickedBundle, source: "clickPassThroughDeactivate")
                return false
            }
        }

        if shouldPromotePostExposeDismissClickToFirstClick(bundleIdentifier: clickedBundle,
                                                           flags: flags,
                                                           frontmostBefore: frontmostBefore) {
            Logger.debug("WORKFLOW: Promoting immediate post-dismiss click to first-click behavior for \(clickedBundle)")
            return executeFirstClickAction(for: clickedBundle,
                                           flags: flags,
                                           frontmostBefore: frontmostBefore,
                                           forceActivateFallback: context.forceFirstClickActivateFallback)
        }

        let action = configuredAction(for: .click, flags: flags)
        lastActionExecuted = action
        lastActionExecutedBundle = clickedBundle
        lastActionExecutedSource = "click"
        lastActionExecutedAt = Date()
        Logger.log("WORKFLOW: Executing click action (button \(buttonNumber)) at \(location.x), \(location.y): \(action.rawValue) for \(clickedBundle) (modifiers=\(modifierCombination(from: flags).rawValue), flags=\(flags.rawValue))")

        switch action {
        case .none:
            return false
        case .activateApp:
            return performActivateAppAction(bundleIdentifier: clickedBundle)
        case .hideApp:
            if WindowManager.isAppHidden(bundleIdentifier: clickedBundle) {
                _ = WindowManager.unhideApp(bundleIdentifier: clickedBundle)
                _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: clickedBundle)
            } else {
                _ = WindowManager.hideAllWindows(bundleIdentifier: clickedBundle)
            }
            resetExposeTracking()
            return true
        case .hideOthers:
            if WindowManager.anyHiddenOthers(excluding: clickedBundle) {
                _ = WindowManager.showAllApplications()
            } else {
                _ = WindowManager.hideOthers(bundleIdentifier: clickedBundle)
            }
            resetExposeTracking()
            return true
        case .bringAllToFront:
            if WindowManager.isAppHidden(bundleIdentifier: clickedBundle) {
                _ = WindowManager.unhideApp(bundleIdentifier: clickedBundle)
            }
            _ = WindowManager.bringAllToFront(bundleIdentifier: clickedBundle)
            resetExposeTracking()
            return true
        case .appExpose:
            let windowCountNow = WindowManager.totalWindowCount(bundleIdentifier: clickedBundle)
            if windowCountNow == 0 {
                Logger.debug("APP_EXPOSE_DECISION: click appExpose skipped for \(clickedBundle) because windowsNow=0")
                // Let Dock handle the click (e.g. create/show a window) without immediately opening App Exposé.
                return false
            }
            if preferences.firstClickAppExposeRequiresMultipleWindows, windowCountNow < 2 {
                Logger.debug("APP_EXPOSE_DECISION: click appExpose skipped for \(clickedBundle): fewer than two windows")
                // Respect the >1 window App Exposé preference for click-after-activation too.
                return false
            }
            Logger.debug("WORKFLOW: App Exposé trigger from click")
            triggerAppExpose(for: clickedBundle)
            // Never consume App Exposé clicks; let Dock see the full click lifecycle.
            return false
        case .singleAppMode:
            performSingleAppMode(targetBundleIdentifier: clickedBundle, frontmostBefore: frontmostBefore)
            return true
        case .minimizeAll:
            if shouldThrottleMinimize(bundleIdentifier: clickedBundle) {
                Logger.debug("WORKFLOW: Minimize throttle active for \(clickedBundle); ignoring click")
                return true
            }
            markMinimize(bundleIdentifier: clickedBundle)
            if WindowManager.allWindowsMinimized(bundleIdentifier: clickedBundle) {
                if WindowManager.restoreAllWindows(bundleIdentifier: clickedBundle) {
                    _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: clickedBundle)
                }
            } else {
                _ = WindowManager.minimizeAllWindows(bundleIdentifier: clickedBundle)
            }
            return true
        case .quitApp:
            _ = WindowManager.quitApp(bundleIdentifier: clickedBundle)
            return true
        @unknown default:
            return false
        }
    }

    private func recordActionExecution(action: DockAction, bundle: String, source: String) {
        lastActionExecuted = action
        lastActionExecutedBundle = bundle
        lastActionExecutedSource = source
        lastActionExecutedAt = Date()
    }

    private func handleScroll(at location: CGPoint, direction: ScrollDirection, flags: CGEventFlags) -> Bool {
        Logger.debug("WORKFLOW: Scroll \(direction == .up ? "up" : "down") received at \(location.x), \(location.y)")
        guard let clickedBundle = DockHitTest.bundleIdentifierAtPoint(location) else {
            return false
        }

        let frontmostBefore = FrontmostAppTracker.frontmostBundleIdentifier()

        if diagnosticsCaptureActive {
            lastDockBundleHit = clickedBundle
            lastDockBundleHitAt = Date()
        }
        
        let now = Date().timeIntervalSinceReferenceDate
        let debounceWindow: TimeInterval = 0.35
        if let lastTime = lastScrollTime,
           let lastBundle = lastScrollBundle,
           let lastDir = lastScrollDirection,
           lastBundle == clickedBundle,
           lastDir == direction,
           now - lastTime < debounceWindow {
            Logger.debug("WORKFLOW: Scroll debounced for \(clickedBundle) direction \(direction == .up ? "up" : "down") (Δ \(now - lastTime))")
            return true
        }
        lastScrollTime = now
        lastScrollBundle = clickedBundle
        lastScrollDirection = direction

        if isAppExposeInteractionActive(frontmostBefore: frontmostBefore) {
            Logger.debug("WORKFLOW: App Exposé active - ignoring scroll action and allowing system behavior")
            return false
        }

        let source: ActionSource = direction == .up ? .scrollUp : .scrollDown
        let action = configuredAction(for: source, flags: flags)
        lastActionExecuted = action
        lastActionExecutedBundle = clickedBundle
        lastActionExecutedSource = source.rawValue
        lastActionExecutedAt = Date()
        Logger.log("WORKFLOW: Executing scroll \(direction == .up ? "up" : "down") action: \(action.rawValue) for \(clickedBundle) (modifiers=\(modifierCombination(from: flags).rawValue), flags=\(flags.rawValue))")

        switch action {
        case .none:
            return false
        case .activateApp:
            return performActivateAppAction(bundleIdentifier: clickedBundle)
        case .hideApp:
            if WindowManager.isAppHidden(bundleIdentifier: clickedBundle) {
                _ = WindowManager.unhideApp(bundleIdentifier: clickedBundle)
                _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: clickedBundle)
            } else {
                _ = WindowManager.hideAllWindows(bundleIdentifier: clickedBundle)
            }
            resetExposeTracking()
            return true
        case .hideOthers:
            if WindowManager.anyHiddenOthers(excluding: clickedBundle) {
                _ = WindowManager.showAllApplications()
            } else {
                _ = WindowManager.hideOthers(bundleIdentifier: clickedBundle)
            }
            resetExposeTracking()
            return true
        case .bringAllToFront:
            if WindowManager.isAppHidden(bundleIdentifier: clickedBundle) {
                _ = WindowManager.unhideApp(bundleIdentifier: clickedBundle)
            }
            _ = WindowManager.bringAllToFront(bundleIdentifier: clickedBundle)
            resetExposeTracking()
            return true
        case .appExpose:
            triggerAppExpose(for: clickedBundle)
            // Keep scroll pass-through for App Exposé trigger path.
            return false
        case .singleAppMode:
            performSingleAppMode(targetBundleIdentifier: clickedBundle, frontmostBefore: frontmostBefore)
            return true
        case .minimizeAll:
            if shouldThrottleMinimize(bundleIdentifier: clickedBundle) {
                Logger.debug("WORKFLOW: Minimize throttle active for \(clickedBundle); ignoring scroll")
                return true
            }
            markMinimize(bundleIdentifier: clickedBundle)
            if WindowManager.allWindowsMinimized(bundleIdentifier: clickedBundle) {
                if WindowManager.restoreAllWindows(bundleIdentifier: clickedBundle) {
                    _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: clickedBundle)
                }
            } else {
                _ = WindowManager.minimizeAllWindows(bundleIdentifier: clickedBundle)
            }
            return true
        case .quitApp:
            _ = WindowManager.quitApp(bundleIdentifier: clickedBundle)
            return true
        @unknown default:
            return false
        }
    }

    private enum ActionSource: String {
        case click
        case scrollUp
        case scrollDown
    }

    private enum ModifierCombination: String {
        case none
        case shift
        case option
        case shiftOption
    }

    private func modifierCombination(from flags: CGEventFlags) -> ModifierCombination {
        let hasShift = flags.contains(.maskShift)
        let hasOption = flags.contains(.maskAlternate)
        switch (hasShift, hasOption) {
        case (true, true):
            return .shiftOption
        case (true, false):
            return .shift
        case (false, true):
            return .option
        case (false, false):
            return .none
        }
    }

    private func configuredAction(for source: ActionSource, flags: CGEventFlags) -> DockAction {
        switch source {
        case .click:
            switch modifierCombination(from: flags) {
            case .none:
                return preferences.clickAction
            case .shift:
                return preferences.shiftClickAction
            case .option:
                return preferences.optionClickAction
            case .shiftOption:
                return preferences.shiftOptionClickAction
            }
        case .scrollUp:
            switch modifierCombination(from: flags) {
            case .none:
                return preferences.scrollUpAction
            case .shift:
                return preferences.shiftScrollUpAction
            case .option:
                return preferences.optionScrollUpAction
            case .shiftOption:
                return preferences.shiftOptionScrollUpAction
            }
        case .scrollDown:
            switch modifierCombination(from: flags) {
            case .none:
                return preferences.scrollDownAction
            case .shift:
                return preferences.shiftScrollDownAction
            case .option:
                return preferences.optionScrollDownAction
            case .shiftOption:
                return preferences.shiftOptionScrollDownAction
            }
        }
    }

    private func executeFirstClickBehavior(for bundleIdentifier: String,
                                           forceActivateFallback: Bool = false) -> Bool {
        switch preferences.firstClickBehavior {
        case .activateApp:
            Logger.debug("WORKFLOW: First click behavior=activateApp; allowing Dock activation")
            return false
        case .bringAllToFront:
            guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else {
                Logger.debug("WORKFLOW: First click behavior=bringAllToFront but app not running; allowing Dock launch")
                return false
            }
            if WindowManager.isAppHidden(bundleIdentifier: bundleIdentifier) {
                _ = WindowManager.unhideApp(bundleIdentifier: bundleIdentifier)
            }
            if !WindowManager.bringAllToFront(bundleIdentifier: bundleIdentifier) {
                _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: bundleIdentifier)
            }
            Logger.debug("WORKFLOW: First click behavior=bringAllToFront executed for \(bundleIdentifier)")
            return true
        case .appExpose:
            guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else {
                Logger.debug("WORKFLOW: First click behavior=appExpose but app not running; allowing Dock launch")
                return false
            }
            let windowCountNow = WindowManager.totalWindowCount(bundleIdentifier: bundleIdentifier)
            Logger.debug("APP_EXPOSE_DECISION: firstClick appExpose bundle=\(bundleIdentifier) forceFallback=\(forceActivateFallback) windowsNow=\(windowCountNow)")
            if forceActivateFallback {
                Logger.debug("APP_EXPOSE_DECISION: firstClick forced activate fallback for \(bundleIdentifier)")
                recordActionExecution(action: .activateApp,
                                      bundle: bundleIdentifier,
                                      source: "firstClickFallbackNoWindows")
                return performActivateAppAction(bundleIdentifier: bundleIdentifier)
            }
            if windowCountNow == 0 {
                Logger.debug("APP_EXPOSE_DECISION: firstClick activate fallback for \(bundleIdentifier) because windowsNow=0")
                recordActionExecution(action: .activateApp,
                                      bundle: bundleIdentifier,
                                      source: "firstClickFallbackNoWindows")
                return performActivateAppAction(bundleIdentifier: bundleIdentifier)
            }
            guard shouldRunFirstClickAppExpose(for: bundleIdentifier) else {
                Logger.debug("APP_EXPOSE_DECISION: firstClick appExpose skipped by shouldRunFirstClickAppExpose for \(bundleIdentifier)")
                return false
            }
            lastActionExecuted = .appExpose
            lastActionExecutedBundle = bundleIdentifier
            lastActionExecutedSource = "firstClick"
            lastActionExecutedAt = Date()
            Logger.debug("APP_EXPOSE_DECISION: firstClick appExpose executing for \(bundleIdentifier)")
            triggerAppExpose(for: bundleIdentifier)
            // Keep Dock's press/release lifecycle untouched for App Exposé.
            return false
        }
    }

    private func executeFirstClickAction(for bundleIdentifier: String,
                                         flags: CGEventFlags,
                                         frontmostBefore: String?,
                                         forceActivateFallback: Bool = false) -> Bool {
        let modifier = modifierCombination(from: flags)

        if modifier == .none {
            return executeFirstClickBehavior(for: bundleIdentifier,
                                             forceActivateFallback: forceActivateFallback)
        }

        let isRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleIdentifier }
        if !isRunning {
            Logger.debug("WORKFLOW: First click modifier action requested but app not running; allowing Dock launch")
            return false
        }

        let action: DockAction
        switch modifier {
        case .shift:
            action = preferences.firstClickShiftAction
        case .option:
            action = preferences.firstClickOptionAction
        case .shiftOption:
            action = preferences.firstClickShiftOptionAction
        case .none:
            action = .none
        }

        if action == .appExpose,
           !shouldRunFirstClickAppExpose(for: bundleIdentifier) {
            return false
        }

        if action == .none {
            Logger.debug("WORKFLOW: First click modifier action is none; allowing Dock activation")
            return false
        }

        lastActionExecuted = action
        lastActionExecutedBundle = bundleIdentifier
        lastActionExecutedSource = "firstClick"
        lastActionExecutedAt = Date()
        Logger.log("WORKFLOW: Executing first-click modifier action: \(action.rawValue) for \(bundleIdentifier) (modifier=\(modifier.rawValue), flags=\(flags.rawValue))")

        switch action {
        case .none:
            return false
        case .activateApp:
            return performActivateAppAction(bundleIdentifier: bundleIdentifier)
        case .hideApp:
            if WindowManager.isAppHidden(bundleIdentifier: bundleIdentifier) {
                _ = WindowManager.unhideApp(bundleIdentifier: bundleIdentifier)
                _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: bundleIdentifier)
            } else {
                _ = WindowManager.hideAllWindows(bundleIdentifier: bundleIdentifier)
            }
            resetExposeTracking()
            return true
        case .hideOthers:
            if WindowManager.anyHiddenOthers(excluding: bundleIdentifier) {
                _ = WindowManager.showAllApplications()
            } else {
                _ = WindowManager.hideOthers(bundleIdentifier: bundleIdentifier)
            }
            resetExposeTracking()
            return true
        case .bringAllToFront:
            if WindowManager.isAppHidden(bundleIdentifier: bundleIdentifier) {
                _ = WindowManager.unhideApp(bundleIdentifier: bundleIdentifier)
            }
            _ = WindowManager.bringAllToFront(bundleIdentifier: bundleIdentifier)
            resetExposeTracking()
            return true
        case .appExpose:
            Logger.debug("WORKFLOW: App Exposé trigger from first-click modifier")
            triggerAppExpose(for: bundleIdentifier)
            // Keep Dock's click lifecycle untouched for App Exposé.
            return false
        case .singleAppMode:
            performSingleAppMode(targetBundleIdentifier: bundleIdentifier, frontmostBefore: frontmostBefore)
            return true
        case .minimizeAll:
            if shouldThrottleMinimize(bundleIdentifier: bundleIdentifier) {
                Logger.debug("WORKFLOW: Minimize throttle active for \(bundleIdentifier); ignoring first-click modifier")
                return true
            }
            markMinimize(bundleIdentifier: bundleIdentifier)
            if WindowManager.allWindowsMinimized(bundleIdentifier: bundleIdentifier) {
                if WindowManager.restoreAllWindows(bundleIdentifier: bundleIdentifier) {
                    _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: bundleIdentifier)
                }
            } else {
                _ = WindowManager.minimizeAllWindows(bundleIdentifier: bundleIdentifier)
            }
            return true
        case .quitApp:
            _ = WindowManager.quitApp(bundleIdentifier: bundleIdentifier)
            return true
        @unknown default:
            return false
        }
    }

    private func resetExposeTracking() {
        appExposeInvocationToken = nil
        lastTriggeredBundle = nil
        currentExposeApp = nil
        appsWithoutWindowsInExpose.removeAll()
    }

    private func completeAppExposeInvocation(token: UUID,
                                             bundleIdentifier: String,
                                             startedAt: Date) {
        guard appExposeInvocationToken == token else { return }

        let previousLastTriggeredBundle = lastTriggeredBundle
        let previousCurrentExposeApp = currentExposeApp
        let previousAppsWithoutWindows = appsWithoutWindowsInExpose

        appExposeInvocationToken = nil

        let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let currentFrontmost = FrontmostAppTracker.frontmostBundleIdentifier()
        Logger.debug("WORKFLOW: App Exposé invoke target=\(bundleIdentifier) frontmost=\(currentFrontmost ?? "nil") latencyMs=\(latencyMs)")

        if currentFrontmost != bundleIdentifier {
            _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: bundleIdentifier)
        }

        let result = invoker.invokeApplicationWindows(for: bundleIdentifier, requireEvidence: true)
        Logger.debug("WORKFLOW: App Exposé invoke result target=\(bundleIdentifier) dispatched=\(result.dispatched) evidence=\(result.evidence) strategy=\(result.strategy?.rawValue ?? "none") frontmostAfter=\(result.frontmostAfter)")

        if result.dispatched {
            lastTriggeredBundle = bundleIdentifier
            currentExposeApp = bundleIdentifier
            appsWithoutWindowsInExpose.remove(bundleIdentifier)
            return
        }

        if previousLastTriggeredBundle != nil || previousCurrentExposeApp != nil {
            lastTriggeredBundle = previousLastTriggeredBundle
            currentExposeApp = previousCurrentExposeApp
            appsWithoutWindowsInExpose = previousAppsWithoutWindows
        } else {
            resetExposeTracking()
        }
    }

    private func shouldConsumeClick(for context: PendingClickContext) -> Bool {
        let frontmostBefore = context.frontmostBefore
        let clickedBundle = context.clickedBundle
        let flags = context.flags
        let appExposeActive = isAppExposeInteractionActive(frontmostBefore: frontmostBefore)

        if appExposeActive {
            return false
        }

        if frontmostBefore != clickedBundle {
            if lastTriggeredBundle != nil, appExposeInvocationToken != nil {
                return false
            }
            return shouldConsumeFirstClickAction(for: clickedBundle, flags: flags)
        }

        if let lastBundle = lastTriggeredBundle, lastBundle == clickedBundle {
            if frontmostBefore != clickedBundle {
                return false
            }
            let action = configuredAction(for: .click, flags: flags)
            return action != .none && action != .appExpose
        }

        if shouldPromotePostExposeDismissClickToFirstClick(bundleIdentifier: clickedBundle,
                                                           flags: flags,
                                                           frontmostBefore: frontmostBefore) {
            return shouldConsumeFirstClickAction(for: clickedBundle, flags: flags)
        }

        let action = configuredAction(for: .click, flags: flags)
        return action != .none && action != .appExpose
    }

    private func shouldForceFirstClickActivateFallback(for context: PendingClickContext) -> Bool {
        guard context.frontmostBefore != context.clickedBundle else {
            Logger.debug("APP_EXPOSE_DECISION: click=\(context.clickSequence) fallbackLatch=false reason=alreadyFrontmost")
            return false
        }
        guard modifierCombination(from: context.flags) == .none else {
            Logger.debug("APP_EXPOSE_DECISION: click=\(context.clickSequence) fallbackLatch=false reason=modifier")
            return false
        }
        guard preferences.firstClickBehavior == .appExpose else {
            Logger.debug("APP_EXPOSE_DECISION: click=\(context.clickSequence) fallbackLatch=false reason=firstClickBehavior(\(preferences.firstClickBehavior.rawValue))")
            return false
        }
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == context.clickedBundle }) else {
            Logger.debug("APP_EXPOSE_DECISION: click=\(context.clickSequence) fallbackLatch=false reason=notRunning")
            return false
        }
        let windows = context.windowCountAtMouseDown ?? WindowManager.totalWindowCount(bundleIdentifier: context.clickedBundle)
        let shouldLatch = windows == 0
        Logger.debug("APP_EXPOSE_DECISION: click=\(context.clickSequence) fallbackLatch=\(shouldLatch) windowsAtDown=\(windows)")
        return shouldLatch
    }

    private func isAppExposeInteractionActive(frontmostBefore: String?) -> Bool {
        // Treat only an in-flight invocation or Dock-frontmost state as "active".
        // `lastTriggeredBundle`/`currentExposeApp` are tracking context used for
        // post-dismiss transition logic and should not block immediate re-entry.
        if appExposeInvocationToken != nil {
            return true
        }

        // App Exposé can be visible even when evidence heuristics are inconclusive.
        // In that state the Dock is frontmost, so treat Dock-icon clicks as Exposé switches.
        return frontmostBefore == "com.apple.dock"
    }

    private func shouldPromotePostExposeDismissClickToFirstClick(bundleIdentifier: String,
                                                                 flags: CGEventFlags,
                                                                 frontmostBefore: String?) -> Bool {
        guard frontmostBefore == bundleIdentifier else { return false }
        guard configuredAction(for: .click, flags: flags) == .none else { return false }
        guard preferences.firstClickBehavior == .appExpose else { return false }
        guard preferences.firstClickAppExposeRequiresMultipleWindows == false
                || WindowManager.hasMultipleWindowsOpen(bundleIdentifier: bundleIdentifier) else { return false }
        guard lastActionExecuted == .activateApp,
              lastActionExecutedBundle == bundleIdentifier,
              lastActionExecutedSource == "clickTransitionDeactivate",
              let lastAt = lastActionExecutedAt else { return false }
        return Date().timeIntervalSince(lastAt) <= 1.0
    }

    private func shouldConsumeFirstClickAction(for bundleIdentifier: String, flags: CGEventFlags) -> Bool {
        let modifier = modifierCombination(from: flags)
        let isRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleIdentifier }

        if modifier == .none {
            switch preferences.firstClickBehavior {
            case .activateApp:
                return false
            case .bringAllToFront:
                return isRunning
            case .appExpose:
                guard isRunning else { return false }
                if WindowManager.totalWindowCount(bundleIdentifier: bundleIdentifier) == 0 {
                    // This path falls back to activateApp and consumes click-up.
                    return true
                }
                // Do not consume App Exposé first-click; keep Dock click semantics intact.
                return false
            }
        }

        guard isRunning else { return false }

        let action: DockAction
        switch modifier {
        case .shift:
            action = preferences.firstClickShiftAction
        case .option:
            action = preferences.firstClickOptionAction
        case .shiftOption:
            action = preferences.firstClickShiftOptionAction
        case .none:
            action = .none
        }

        if action == .appExpose,
           !shouldRunFirstClickAppExpose(for: bundleIdentifier) {
            return false
        }

        return action != .none && action != .appExpose
    }

    private func shouldRunFirstClickAppExpose(for bundleIdentifier: String) -> Bool {
        let windowCount = WindowManager.totalWindowCount(bundleIdentifier: bundleIdentifier)
        if windowCount == 0 {
            Logger.debug("WORKFLOW: First click appExpose skipped for \(bundleIdentifier): no windows")
            return false
        }
        if preferences.firstClickAppExposeRequiresMultipleWindows, windowCount < 2 {
            Logger.debug("WORKFLOW: First click appExpose skipped for \(bundleIdentifier): fewer than two windows")
            return false
        }
        return true
    }

    private func performActivateAppAction(bundleIdentifier: String) -> Bool {
        let isRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleIdentifier }
        if !isRunning {
            Logger.debug("WORKFLOW: activateApp requested for non-running app \(bundleIdentifier); delegating launch to Dock")
            resetExposeTracking()
            return false
        }

        if WindowManager.isAppHidden(bundleIdentifier: bundleIdentifier) {
            _ = WindowManager.unhideApp(bundleIdentifier: bundleIdentifier)
        }

        _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: bundleIdentifier)
        resetExposeTracking()
        return true
    }

    private func performSingleAppMode(targetBundleIdentifier: String, frontmostBefore: String?) {
        let frontmostNow = FrontmostAppTracker.frontmostBundleIdentifier()
        let sourceBundleToHide = [frontmostBefore, frontmostNow]
            .compactMap { $0 }
            .first(where: { $0 != targetBundleIdentifier })

        Logger.debug("WORKFLOW: Single app mode target=\(targetBundleIdentifier), frontmostBefore=\(frontmostBefore ?? "nil"), frontmostNow=\(frontmostNow ?? "nil"), sourceToHide=\(sourceBundleToHide ?? "nil")")

        if let sourceBundleToHide {
            _ = WindowManager.hideAllWindows(bundleIdentifier: sourceBundleToHide)
        } else if frontmostBefore == targetBundleIdentifier || frontmostNow == targetBundleIdentifier {
            // Toggle-off behavior when the user targets the current app.
            _ = WindowManager.hideAllWindows(bundleIdentifier: targetBundleIdentifier)
            resetExposeTracking()
            return
        }

        let targetRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == targetBundleIdentifier }
        if targetRunning {
            if WindowManager.isAppHidden(bundleIdentifier: targetBundleIdentifier) {
                _ = WindowManager.unhideApp(bundleIdentifier: targetBundleIdentifier)
            }
            _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: targetBundleIdentifier)
        } else {
            launchApp(bundleIdentifier: targetBundleIdentifier)
        }

        resetExposeTracking()
    }
    
    private func shouldThrottleMinimize(bundleIdentifier: String) -> Bool {
        let now = Date().timeIntervalSinceReferenceDate
        if let last = lastMinimizeToggleTime[bundleIdentifier], now - last < minimizeToggleCooldown {
            return true
        }
        return false
    }
    
    private func markMinimize(bundleIdentifier: String) {
        lastMinimizeToggleTime[bundleIdentifier] = Date().timeIntervalSinceReferenceDate
    }

    private func triggerAppExpose(for bundleIdentifier: String) {
        Logger.debug("WORKFLOW: Triggering App Exposé for \(bundleIdentifier)")

        let invocationToken = UUID()
        appExposeInvocationToken = invocationToken
        let startedAt = Date()

        let frontmost = FrontmostAppTracker.frontmostBundleIdentifier()
        if frontmost != bundleIdentifier {
            if !WindowManager.activateAndShowMainWindow(bundleIdentifier: bundleIdentifier),
               let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
                _ = app.activate(options: [.activateIgnoringOtherApps])
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.completeAppExposeInvocation(token: invocationToken,
                                             bundleIdentifier: bundleIdentifier,
                                             startedAt: startedAt)
        }
    }
    
    private func exitAppExpose() {
        Logger.debug("WORKFLOW: Exiting App Exposé via Escape")
        appExposeInvocationToken = nil
        // Send Escape key to close App Exposé
        if let source = CGEventSource(stateID: .combinedSessionState) {
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
        lastTriggeredBundle = nil
        currentExposeApp = nil
        appsWithoutWindowsInExpose.removeAll()
    }

    private func launchApp(bundleIdentifier: String) {
        Logger.debug("WORKFLOW: Launching app \(bundleIdentifier)")
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        if let url = url {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, error in
                if let error = error {
                    Logger.debug("WORKFLOW: Failed to launch app \(bundleIdentifier): \(error.localizedDescription)")
                } else {
                    Logger.debug("WORKFLOW: Successfully launched app \(bundleIdentifier)")
                }
            }
        } else {
            Logger.debug("WORKFLOW: Could not find app URL for \(bundleIdentifier)")
        }
    }
}
