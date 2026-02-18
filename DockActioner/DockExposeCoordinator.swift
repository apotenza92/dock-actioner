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
    private let appExposeImageDiffThreshold: Double = 0.035
    private var pendingClickContext: PendingClickContext?
    private var pendingClickWasDragged = false
    private var appExposeInvocationToken: UUID?
    private var appExposeActivationObserver: NSObjectProtocol?

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

    @Published private(set) var selfTestStatus: String?
    private var selfTestActive: Bool = false

    @Published private(set) var functionalTestStatus: String?
    @Published private(set) var appExposeHotkeyTestStatus: String?
    @Published private(set) var firstClickAppExposeTestStatus: String?
    @Published private(set) var appExposeReentryTestStatus: String?

    @Published private(set) var lastActionExecuted: DockAction?
    @Published private(set) var lastActionExecutedBundle: String?
    @Published private(set) var lastActionExecutedSource: String?
    @Published private(set) var lastActionExecutedAt: Date?

    @Published private(set) var fullTestStatus: String?

    private struct PendingClickContext {
        let location: CGPoint
        let buttonNumber: Int
        let flags: CGEventFlags
        let frontmostBefore: String?
        let clickedBundle: String
        let consumeClick: Bool
    }

    private struct FirstClickAppExposeIterationResult {
        let passed: Bool
        let detail: String
    }

    private struct AppExposeReentryIterationResult {
        let passed: Bool
        let detail: String
    }

    private struct AppExposeEvidenceResult {
        let frontmost: String
        let changedPixelRatio: Double?
        let meanAbsDelta: Double?
        let sampledPixels: Int
        let dockSignatureDelta: Int
        let evidence: Bool
        let beforePath: String
        let afterPath: String
    }

    var isAppExposeShortcutConfigured: Bool {
        invoker.isDockNotificationAvailable()
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

    func runSelfTest() {
        selfTestStatus = nil

        refreshPermissionsAndSecurityState()

        guard accessibilityGranted else {
            selfTestStatus = "Self-test failed: Accessibility not granted"
            return
        }
        guard inputMonitoringGranted else {
            selfTestStatus = "Self-test failed: Input Monitoring not granted"
            return
        }

        if !isRunning {
            startIfPossible()
        }
        guard isRunning else {
            selfTestStatus = "Self-test failed: event tap not running (\(lastStartError ?? "unknown error"))"
            return
        }

        // Find an actual Dock icon location by probing along display edges.
        guard let (point, bundle) = findAnyDockIconPoint() else {
            selfTestStatus = "Self-test failed: couldn't find any Dock icon point"
            return
        }

        selfTestStatus = "Self-test: found Dock icon \(bundle) at (\(Int(point.x)), \(Int(point.y)))"

        runDiagnosticsCapture(seconds: 2.0)
        selfTestActive = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.selfTestActive = false
        }

        postSyntheticScroll(at: point, deltaY: 4)
        postSyntheticScroll(at: point, deltaY: -4)
        postSyntheticClick(at: point)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let hit = self.lastDockBundleHit ?? "nil"
            self.selfTestStatus = "Self-test: eventsSeen=\(tapEventsSeen) clicks=\(tapClicksSeen) scrolls=\(tapScrollsSeen) lastDockHit=\(hit)"
        }
    }

    func runFunctionalTest() {
        functionalTestStatus = nil

        refreshPermissionsAndSecurityState()

        guard accessibilityGranted else {
            functionalTestStatus = "Functional test failed: Accessibility not granted"
            return
        }
        guard inputMonitoringGranted else {
            functionalTestStatus = "Functional test failed: Input Monitoring not granted"
            return
        }
        if !isRunning {
            startIfPossible()
        }
        guard isRunning else {
            functionalTestStatus = "Functional test failed: event tap not running (\(lastStartError ?? "unknown error"))"
            return
        }

        // Best-effort: try to ensure there is at least one other regular app to hide.
        // Do not activate any apps here (it can look like we "clicked" them).
        let regularApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
        if regularApps.count <= 1 {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.calculator") {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = false
                cfg.addsToRecentItems = false
                NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            guard let (point, bundle) = self.findAnyDockIconPoint() else {
                self.functionalTestStatus = "Functional test failed: couldn't find a Dock icon point"
                return
            }

            // Force known mappings for the run.
            self.preferences.scrollUpAction = .hideOthers
            self.preferences.scrollDownAction = .appExpose
            self.preferences.clickAction = .hideApp

            self.functionalTestStatus = "Functional test: targeting \(bundle) at (\(Int(point.x)), \(Int(point.y)))"

            // Trigger scroll-up (hide others) then verify at least one other app became hidden.
            self.postSyntheticScroll(at: point, deltaY: -6)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                let hiddenRegularApps = NSWorkspace.shared.runningApplications
                    .filter { $0.activationPolicy == .regular }
                    .filter { $0.isHidden }
                    .map { $0.bundleIdentifier ?? "?" }

                Logger.log("Functional test: hidden regular apps after hideOthers: \(hiddenRegularApps)")

                // Cleanup: show all apps back.
                _ = WindowManager.showAllApplications()

                self.functionalTestStatus = "Functional test: hideOthers hiddenCount=\(hiddenRegularApps.count). (App Expose test logs only.)"

                // Trigger scroll-down (app expose). We can't reliably assert Mission Control UI state,
                // but we can at least exercise the code path.
                self.postSyntheticScroll(at: point, deltaY: 6)
            }
        }
    }

    func runFullTestSuite() {
        fullTestStatus = "Running full test suite..."
        Task { [weak self] in
            guard let self else { return }
            refreshPermissionsAndSecurityState()
            let suite = ActionTestSuite(coordinator: self)
            let target = ProcessInfo.processInfo.environment["DOCKACTIONER_TEST_TARGET"] ?? "com.apple.calculator"
            let results = await suite.runAll(targetBundleIdentifier: target)

            let passed = results.filter { $0.passed }.count
            let total = results.count
            let failed = results.filter { !$0.passed }

            Logger.log("Full test suite: passed \(passed)/\(total)")
            for f in failed.prefix(12) {
                Logger.log("Test FAIL \(f.trigger.rawValue) \(f.action.rawValue): \(f.detail)")
            }
            if failed.count > 12 {
                Logger.log("... plus \(failed.count - 12) more failures")
            }

            fullTestStatus = "Full test suite: passed \(passed)/\(total). (See log for details.)"

            if ProcessInfo.processInfo.environment["DOCKACTIONER_TEST_SUITE"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func runFirstClickAppExposeTestSuite() {
        firstClickAppExposeTestStatus = "Running first-click App Expose test..."

        Task { [weak self] in
            guard let self else { return }

            refreshPermissionsAndSecurityState()
            guard accessibilityGranted else {
                firstClickAppExposeTestStatus = "First-click App Expose test failed: Accessibility not granted"
                return
            }
            guard inputMonitoringGranted else {
                firstClickAppExposeTestStatus = "First-click App Expose test failed: Input Monitoring not granted"
                return
            }

            if !isRunning {
                startIfPossible()
            }
            guard isRunning else {
                firstClickAppExposeTestStatus = "First-click App Expose test failed: event tap not running (\(lastStartError ?? "unknown error"))"
                return
            }

            let env = ProcessInfo.processInfo.environment
            let iterations = max(1, Int(env["DOCKACTIONER_FIRSTCLICK_APPEXPOSE_ITERATIONS"] ?? "12") ?? 12)
            let preferredTarget = env["DOCKACTIONER_FIRSTCLICK_APPEXPOSE_TARGET"]

            guard let targetBundle = await selectFirstClickAppExposeTargetBundle(preferred: preferredTarget) else {
                firstClickAppExposeTestStatus = "First-click App Expose test failed: could not find a testable Dock icon target"
                return
            }

            let savedFirstClickBehavior = preferences.firstClickBehavior
            let savedFirstClickRequiresMulti = preferences.firstClickAppExposeRequiresMultipleWindows
            defer {
                preferences.firstClickBehavior = savedFirstClickBehavior
                preferences.firstClickAppExposeRequiresMultipleWindows = savedFirstClickRequiresMulti
            }

            preferences.firstClickBehavior = .appExpose
            preferences.firstClickAppExposeRequiresMultipleWindows = false

            Logger.log("First-click App Expose test: target=\(targetBundle) iterations=\(iterations)")

            var passes = 0
            var failures: [String] = []

            for index in 1...iterations {
                let result = await runSingleFirstClickAppExposeIteration(index: index,
                                                                         total: iterations,
                                                                         targetBundle: targetBundle)
                if result.passed {
                    passes += 1
                } else {
                    failures.append("#\(index): \(result.detail)")
                }
            }

            let summary = "First-click App Expose test: passed \(passes)/\(iterations) target=\(targetBundle)"
            if failures.isEmpty {
                firstClickAppExposeTestStatus = summary
            } else {
                firstClickAppExposeTestStatus = summary + ". Failures: " + failures.joined(separator: " | ")
            }
            Logger.log(firstClickAppExposeTestStatus ?? summary)

            if env["DOCKACTIONER_FIRSTCLICK_APPEXPOSE_TEST"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func runAppExposeReentryRegressionTest() {
        appExposeReentryTestStatus = "Running App Expose re-entry regression test..."

        Task { [weak self] in
            guard let self else { return }

            refreshPermissionsAndSecurityState()
            guard accessibilityGranted else {
                appExposeReentryTestStatus = "App Expose re-entry test failed: Accessibility not granted"
                return
            }
            guard inputMonitoringGranted else {
                appExposeReentryTestStatus = "App Expose re-entry test failed: Input Monitoring not granted"
                return
            }

            if !isRunning {
                startIfPossible()
            }
            guard isRunning else {
                appExposeReentryTestStatus = "App Expose re-entry test failed: event tap not running (\(lastStartError ?? "unknown error"))"
                return
            }

            let env = ProcessInfo.processInfo.environment
            let iterations = max(1, Int(env["DOCKACTIONER_APPEXPOSE_REENTRY_ITERATIONS"] ?? "8") ?? 8)
            let preferredTarget = env["DOCKACTIONER_APPEXPOSE_REENTRY_TARGET"]

            guard let targetBundle = await selectFirstClickAppExposeTargetBundle(preferred: preferredTarget) else {
                appExposeReentryTestStatus = "App Expose re-entry test failed: could not find a testable Dock icon target"
                return
            }

            let savedFirstClickBehavior = preferences.firstClickBehavior
            let savedFirstClickRequiresMulti = preferences.firstClickAppExposeRequiresMultipleWindows
            let savedClickAction = preferences.clickAction
            defer {
                preferences.firstClickBehavior = savedFirstClickBehavior
                preferences.firstClickAppExposeRequiresMultipleWindows = savedFirstClickRequiresMulti
                preferences.clickAction = savedClickAction
            }

            preferences.firstClickBehavior = .appExpose
            preferences.firstClickAppExposeRequiresMultipleWindows = false
            preferences.clickAction = .appExpose

            Logger.log("App Expose re-entry test: target=\(targetBundle) iterations=\(iterations)")

            var passes = 0
            var failures: [String] = []

            for index in 1...iterations {
                let result = await runSingleAppExposeReentryIteration(index: index,
                                                                      total: iterations,
                                                                      targetBundle: targetBundle)
                if result.passed {
                    passes += 1
                } else {
                    failures.append("#\(index): \(result.detail)")
                }
            }

            let summary = "App Expose re-entry test: passed \(passes)/\(iterations) target=\(targetBundle)"
            if failures.isEmpty {
                appExposeReentryTestStatus = summary
            } else {
                appExposeReentryTestStatus = summary + ". Failures: " + failures.joined(separator: " | ")
            }
            Logger.log(appExposeReentryTestStatus ?? summary)

            if env["DOCKACTIONER_APPEXPOSE_REENTRY_TEST"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func runSingleAppExposeReentryIteration(index: Int,
                                                    total: Int,
                                                    targetBundle: String) async -> AppExposeReentryIterationResult {
        await ensureAppRunningForFirstClickTest(bundleIdentifier: targetBundle)
        exitAppExpose()
        try? await Task.sleep(nanoseconds: 120_000_000)
        makeNonTargetAppFrontmost(targetBundle: targetBundle)
        try? await Task.sleep(nanoseconds: 220_000_000)

        guard let initialPoint = findDockIconPoint(bundleIdentifier: targetBundle) else {
            return AppExposeReentryIterationResult(passed: false,
                                                   detail: "could not locate Dock icon")
        }

        let points = firstClickAppExposeCandidatePoints(seed: initialPoint, bundleIdentifier: targetBundle)
        if points.isEmpty {
            return AppExposeReentryIterationResult(passed: false,
                                                   detail: "no candidate click points")
        }

        var attemptFailures: [String] = []

        for (attemptIndex, point) in points.enumerated() {
            postSyntheticMouseMove(to: point)
            try? await Task.sleep(nanoseconds: 90_000_000)

            let hitBundle = DockHitTest.bundleIdentifierAtPoint(point) ?? "nil"
            let firstBaseline = lastActionExecutedAt ?? Date.distantPast
            postSyntheticClick(at: point)

            let firstDispatch = await waitForActionDispatch(expectedAction: .appExpose,
                                                            expectedBundle: targetBundle,
                                                            expectedSource: "firstClick",
                                                            baseline: firstBaseline,
                                                            timeout: 1.2)
            if !firstDispatch {
                attemptFailures.append("attempt \(attemptIndex + 1): firstClick dispatch=false hit=\(hitBundle)")
                exitAppExpose()
                try? await Task.sleep(nanoseconds: 120_000_000)
                makeNonTargetAppFrontmost(targetBundle: targetBundle)
                try? await Task.sleep(nanoseconds: 150_000_000)
                continue
            }

            // Simulate selecting an app window from the App Exposé picker: app becomes frontmost
            // while Exposé tracking state may still indicate an active Exposé session.
            _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: targetBundle)
            try? await Task.sleep(nanoseconds: 220_000_000)
            let frontmostAfterPickerSelection = FrontmostAppTracker.frontmostBundleIdentifier() ?? "nil"

            let secondBaseline = lastActionExecutedAt ?? Date.distantPast
            postSyntheticMouseMove(to: point)
            try? await Task.sleep(nanoseconds: 90_000_000)
            postSyntheticClick(at: point)

            let secondDispatch = await waitForActionDispatch(expectedAction: .appExpose,
                                                             expectedBundle: targetBundle,
                                                             expectedSource: "click",
                                                             baseline: secondBaseline,
                                                             timeout: 1.2)

            let pointText = "(\(Int(point.x)),\(Int(point.y)))"
            Logger.log("App Expose re-entry iteration \(index)/\(total) attempt \(attemptIndex + 1)/\(points.count): firstDispatch=\(firstDispatch) secondDispatch=\(secondDispatch) hit=\(hitBundle) frontmostAfterPickerSelection=\(frontmostAfterPickerSelection) point=\(pointText)")

            exitAppExpose()
            try? await Task.sleep(nanoseconds: 120_000_000)

            if secondDispatch {
                return AppExposeReentryIterationResult(passed: true, detail: "ok")
            }

            attemptFailures.append("attempt \(attemptIndex + 1): clickAfterActivation dispatch=false frontmostAfterPickerSelection=\(frontmostAfterPickerSelection)")
            makeNonTargetAppFrontmost(targetBundle: targetBundle)
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        return AppExposeReentryIterationResult(passed: false,
                                               detail: attemptFailures.joined(separator: ", "))
    }

    private func runSingleFirstClickAppExposeIteration(index: Int,
                                                       total: Int,
                                                       targetBundle: String) async -> FirstClickAppExposeIterationResult {
        await ensureAppRunningForFirstClickTest(bundleIdentifier: targetBundle)
        exitAppExpose()
        try? await Task.sleep(nanoseconds: 120_000_000)
        makeNonTargetAppFrontmost(targetBundle: targetBundle)
        try? await Task.sleep(nanoseconds: 220_000_000)

        guard let initialPoint = findDockIconPoint(bundleIdentifier: targetBundle) else {
            return FirstClickAppExposeIterationResult(passed: false,
                                                      detail: "could not locate Dock icon")
        }

        let points = firstClickAppExposeCandidatePoints(seed: initialPoint, bundleIdentifier: targetBundle)
        if points.isEmpty {
            return FirstClickAppExposeIterationResult(passed: false,
                                                      detail: "no candidate click points")
        }

        let frontmostBefore = FrontmostAppTracker.frontmostBundleIdentifier() ?? "nil"
        var dispatched = false
        var evidence = AppExposeEvidenceResult(frontmost: "nil",
                                               changedPixelRatio: nil,
                                               meanAbsDelta: nil,
                                               sampledPixels: 0,
                                               dockSignatureDelta: 0,
                                               evidence: false,
                                               beforePath: "nil",
                                               afterPath: "nil")
        var selectedPoint: CGPoint?

        for (attemptIndex, point) in points.enumerated() {
            postSyntheticMouseMove(to: point)
            try? await Task.sleep(nanoseconds: 90_000_000)

            let hitBundle = DockHitTest.bundleIdentifierAtPoint(point) ?? "nil"
            let baseline = lastActionExecutedAt ?? Date.distantPast
            let beforeSnapshot = captureMainDisplaySnapshot(tag: "first-click-app-expose-before-\(index)-\(attemptIndex + 1)")
            let dockBefore = dockWindowSignatureSnapshot()

            Logger.log("First-click App Expose iteration \(index)/\(total) attempt \(attemptIndex + 1)/\(points.count): point=(\(Int(point.x)),\(Int(point.y))) hit=\(hitBundle) frontmostBefore=\(frontmostBefore)")

            postSyntheticClick(at: point)

            let attemptDispatched = await waitForActionDispatch(expectedAction: .appExpose,
                                                                expectedBundle: targetBundle,
                                                                expectedSource: "firstClick",
                                                                baseline: baseline,
                                                                timeout: 1.2)

            let attemptEvidence = await collectAppExposeEvidence(before: beforeSnapshot,
                                                                 dockBefore: dockBefore,
                                                                 tagPrefix: "first-click-app-expose-\(index)-\(attemptIndex + 1)")

            if attemptDispatched && attemptEvidence.evidence {
                dispatched = true
                evidence = attemptEvidence
                selectedPoint = point
                break
            }

            if attemptDispatched && !dispatched {
                dispatched = true
                evidence = attemptEvidence
                selectedPoint = point
            }

            exitAppExpose()
            try? await Task.sleep(nanoseconds: 120_000_000)
            makeNonTargetAppFrontmost(targetBundle: targetBundle)
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        let passed = dispatched && evidence.evidence

        let ratioText = evidence.changedPixelRatio.map { String(format: "%.4f", $0) } ?? "unknown"
        let meanText = evidence.meanAbsDelta.map { String(format: "%.4f", $0) } ?? "unknown"
        let selectedPointText: String
        if let selectedPoint {
            selectedPointText = "(\(Int(selectedPoint.x)),\(Int(selectedPoint.y)))"
        } else {
            selectedPointText = "nil"
        }
        Logger.log("First-click App Expose iteration \(index)/\(total): dispatched=\(dispatched) evidence=\(evidence.evidence) frontmostBefore=\(frontmostBefore) frontmostAfter=\(evidence.frontmost) selectedPoint=\(selectedPointText) ratio=\(ratioText) mean=\(meanText) pixels=\(evidence.sampledPixels) dockSignatureDelta=\(evidence.dockSignatureDelta) before=\(evidence.beforePath) after=\(evidence.afterPath)")

        exitAppExpose()
        try? await Task.sleep(nanoseconds: 120_000_000)

        if passed {
            return FirstClickAppExposeIterationResult(passed: true, detail: "ok")
        }

        var failureParts: [String] = []
        if !dispatched { failureParts.append("dispatch=false") }
        if !evidence.evidence { failureParts.append("evidence=false") }
        failureParts.append("frontmostAfter=\(evidence.frontmost)")
        failureParts.append("dockSignatureDelta=\(evidence.dockSignatureDelta)")
        return FirstClickAppExposeIterationResult(passed: false,
                                                  detail: failureParts.joined(separator: ", "))
    }

    private func firstClickAppExposeCandidatePoints(seed: CGPoint, bundleIdentifier: String) -> [CGPoint] {
        var points: [CGPoint] = []
        if let live = firstClickAppExposeLiveDockPoint(for: bundleIdentifier, around: seed) {
            points.append(live)
        }

        let offsets: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: -6, y: 0), CGPoint(x: 6, y: 0),
            CGPoint(x: 0, y: -6), CGPoint(x: 0, y: 6),
            CGPoint(x: -12, y: -4), CGPoint(x: 12, y: -4),
            CGPoint(x: -18, y: 0), CGPoint(x: 18, y: 0)
        ]

        for offset in offsets {
            let point = CGPoint(x: seed.x + offset.x, y: seed.y + offset.y)
            if points.contains(where: { $0 == point }) {
                continue
            }

            if let hit = DockHitTest.bundleIdentifierAtPoint(point), hit == bundleIdentifier {
                points.append(point)
            }
        }

        if points.isEmpty {
            points.append(seed)
        }

        return points
    }

    private func firstClickAppExposeLiveDockPoint(for bundleIdentifier: String, around seed: CGPoint) -> CGPoint? {
        if let hit = DockHitTest.bundleIdentifierAtPoint(seed), hit == bundleIdentifier {
            return seed
        }

        let deltas: [CGFloat] = [0, -8, 8, -16, 16, -24, 24]
        for dy in deltas {
            for dx in deltas {
                let point = CGPoint(x: seed.x + dx, y: seed.y + dy)
                if let hit = DockHitTest.bundleIdentifierAtPoint(point), hit == bundleIdentifier {
                    return point
                }
            }
        }

        return nil
    }

    private func collectAppExposeEvidence(before: DisplaySnapshot?,
                                          dockBefore: Set<DockWindowSignature>,
                                          tagPrefix: String) async -> AppExposeEvidenceResult {
        var bestMetrics: ImageDiffMetrics?
        var bestSnapshot: DisplaySnapshot?
        var maxDockSignatureDelta = 0

        let sampleDelays: [UInt64] = [220_000_000, 420_000_000, 680_000_000]
        for (index, delay) in sampleDelays.enumerated() {
            try? await Task.sleep(nanoseconds: delay)
            let after = captureMainDisplaySnapshot(tag: "\(tagPrefix)-after-\(index + 1)")
            if let after,
               let before,
               let metrics = imageDiffMetrics(before: before.image, after: after.image) {
                if bestMetrics == nil || metrics.changedPixelRatio > (bestMetrics?.changedPixelRatio ?? 0) {
                    bestMetrics = metrics
                    bestSnapshot = after
                }
            }

            let dockAfter = dockWindowSignatureSnapshot()
            let delta = dockBefore.symmetricDifference(dockAfter).count
            if delta > maxDockSignatureDelta {
                maxDockSignatureDelta = delta
            }
        }

        let frontmost = FrontmostAppTracker.frontmostBundleIdentifier() ?? "nil"
        let evidence = maxDockSignatureDelta > 0 || frontmost == "com.apple.dock"

        return AppExposeEvidenceResult(frontmost: frontmost,
                                       changedPixelRatio: bestMetrics?.changedPixelRatio,
                                       meanAbsDelta: bestMetrics?.meanAbsDelta,
                                       sampledPixels: bestMetrics?.sampledPixels ?? 0,
                                       dockSignatureDelta: maxDockSignatureDelta,
                                       evidence: evidence,
                                       beforePath: before?.url?.path ?? "nil",
                                       afterPath: bestSnapshot?.url?.path ?? "nil")
    }

    private func waitForActionDispatch(expectedAction: DockAction,
                                       expectedBundle: String,
                                       expectedSource: String,
                                       baseline: Date,
                                       timeout: TimeInterval) async -> Bool {
        let started = Date()
        while Date().timeIntervalSince(started) < timeout {
            if let at = lastActionExecutedAt,
               at > baseline,
               lastActionExecuted == expectedAction,
               lastActionExecutedBundle == expectedBundle,
               lastActionExecutedSource == expectedSource {
                return true
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return false
    }

    private func selectFirstClickAppExposeTargetBundle(preferred: String?) async -> String? {
        var candidates: [String] = []
        if let preferred, !preferred.isEmpty {
            candidates.append(preferred)
        }
        candidates.append(contentsOf: [
            "com.apple.calculator",
            "com.apple.TextEdit",
            "com.apple.Preview",
            "com.apple.Notes"
        ])

        var seen = Set<String>()
        let ordered = candidates.filter { seen.insert($0).inserted }

        for bundle in ordered {
            await ensureAppRunningForFirstClickTest(bundleIdentifier: bundle)
            if findDockIconPoint(bundleIdentifier: bundle) != nil {
                return bundle
            }
        }

        return nil
    }

    private func ensureAppRunningForFirstClickTest(bundleIdentifier: String) async {
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return
        }
        launchApp(bundleIdentifier: bundleIdentifier)
        try? await Task.sleep(nanoseconds: 650_000_000)
    }

    private func makeNonTargetAppFrontmost(targetBundle: String) {
        let selfBundle = Bundle.main.bundleIdentifier

        if let finder = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.finder" }) {
            _ = finder.activate(options: [.activateIgnoringOtherApps])
            return
        }

        if let fallback = NSWorkspace.shared.runningApplications.first(where: {
            $0.activationPolicy == .regular
                && $0.bundleIdentifier != targetBundle
                && $0.bundleIdentifier != selfBundle
        }) {
            _ = fallback.activate(options: [.activateIgnoringOtherApps])
        }
    }

    func findDockIconPoint(bundleIdentifier: String) -> CGPoint? {
        var count: UInt32 = 0
        if CGGetActiveDisplayList(0, nil, &count) != .success || count == 0 {
            return nil
        }
        var displays = Array(repeating: CGDirectDisplayID(0), count: Int(count))
        if CGGetActiveDisplayList(count, &displays, &count) != .success {
            return nil
        }

        for id in displays {
            let b = CGDisplayBounds(id)

            // If the Dock is set to auto-hide, it may not be hittable unless the cursor is near the edge.
            postSyntheticMouseMove(to: CGPoint(x: b.midX, y: b.maxY - 1))
            postSyntheticMouseMove(to: CGPoint(x: b.minX + 1, y: b.midY))
            postSyntheticMouseMove(to: CGPoint(x: b.maxX - 1, y: b.midY))
            usleep(60_000)

            if let p = probeEdgeForBundle(bounds: b, edge: .bottom, bundleIdentifier: bundleIdentifier) { return p }
            if let p = probeEdgeForBundle(bounds: b, edge: .left, bundleIdentifier: bundleIdentifier) { return p }
            if let p = probeEdgeForBundle(bounds: b, edge: .right, bundleIdentifier: bundleIdentifier) { return p }
        }
        return nil
    }

    func postSyntheticMouseMove(to point: CGPoint) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        if let ev = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            ev.flags = []
            ev.setIntegerValueField(.eventSourceUserData, value: 0xD0C0A11)
            ev.post(tap: .cghidEventTap)
        }
    }

    private struct DisplaySnapshot {
        let image: CGImage
        let url: URL?
    }

    private struct ImageDiffMetrics {
        let meanAbsDelta: Double
        let changedPixelRatio: Double
        let sampledPixels: Int
    }

    private struct DockWindowSignature: Hashable {
        let layer: Int
        let widthBucket: Int
        let heightBucket: Int
        let alphaBucket: Int
        let title: String
    }

    private func captureMainDisplaySnapshot(tag: String) -> DisplaySnapshot? {
        guard let cgImage = CGDisplayCreateImage(CGMainDisplayID()) else { return nil }

        var writtenURL: URL?
        let rep = NSBitmapImageRep(cgImage: cgImage)
        if let png = rep.representation(using: .png, properties: [:]) {
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("DockActioner-\(tag)-\(stamp).png")
            do {
                try png.write(to: url)
                writtenURL = url
            } catch {
                Logger.log("Failed to write snapshot \(tag): \(error.localizedDescription)")
            }
        }

        return DisplaySnapshot(image: cgImage, url: writtenURL)
    }

    private func downsampledRGBA(_ image: CGImage, width: Int = 320, height: Int = 180) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private func imageDiffMetrics(before: CGImage, after: CGImage) -> ImageDiffMetrics? {
        guard let lhs = downsampledRGBA(before), let rhs = downsampledRGBA(after), lhs.count == rhs.count else {
            return nil
        }

        let pixelCount = lhs.count / 4
        if pixelCount == 0 { return nil }

        var totalDelta: UInt64 = 0
        var changedPixels = 0
        let channelThreshold = 24

        var i = 0
        while i + 3 < lhs.count {
            let dr = abs(Int(lhs[i]) - Int(rhs[i]))
            let dg = abs(Int(lhs[i + 1]) - Int(rhs[i + 1]))
            let db = abs(Int(lhs[i + 2]) - Int(rhs[i + 2]))
            let delta = dr + dg + db
            totalDelta += UInt64(delta)
            if delta >= channelThreshold {
                changedPixels += 1
            }
            i += 4
        }

        let meanAbsDelta = Double(totalDelta) / Double(pixelCount * 3 * 255)
        let changedPixelRatio = Double(changedPixels) / Double(pixelCount)
        return ImageDiffMetrics(meanAbsDelta: meanAbsDelta,
                                changedPixelRatio: changedPixelRatio,
                                sampledPixels: pixelCount)
    }

    private func dockWindowSignatureSnapshot() -> Set<DockWindowSignature> {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var signatures = Set<DockWindowSignature>()
        for window in raw {
            guard let owner = window[kCGWindowOwnerName as String] as? String, owner == "Dock" else {
                continue
            }

            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 1.0
            let title = (window[kCGWindowName as String] as? String) ?? ""
            let bounds = window[kCGWindowBounds as String] as? [String: Any]
            let width = Int((bounds?["Width"] as? Double) ?? 0)
            let height = Int((bounds?["Height"] as? Double) ?? 0)

            let signature = DockWindowSignature(layer: layer,
                                                widthBucket: width / 10,
                                                heightBucket: height / 10,
                                                alphaBucket: Int(alpha * 10.0),
                                                title: title)
            signatures.insert(signature)
        }
        return signatures
    }

    func testAppExposeHotkey() {
        appExposeHotkeyTestStatus = nil
        refreshPermissionsAndSecurityState()

        guard accessibilityGranted else {
            appExposeHotkeyTestStatus = "App Expose test: Accessibility not granted"
            return
        }
        guard inputMonitoringGranted else {
            appExposeHotkeyTestStatus = "App Expose test: Input Monitoring not granted"
            return
        }
        if secureEventInputEnabled {
            appExposeHotkeyTestStatus = "App Expose test: Secure Event Input is enabled (some apps block synthetic shortcuts)"
        }

        let selfBundle = Bundle.main.bundleIdentifier
        let forcedBundle = ProcessInfo.processInfo.environment["DOCKACTIONER_APPEXPOSE_TARGET"]

        var bundle = forcedBundle
        if bundle == nil {
            let front = FrontmostAppTracker.frontmostBundleIdentifier()
            if let front, front != selfBundle {
                bundle = front
            }
        }
        if bundle == nil {
            bundle = NSWorkspace.shared.runningApplications
                .first(where: { $0.activationPolicy == .regular && $0.bundleIdentifier != selfBundle })?
                .bundleIdentifier
        }
        let targetBundle = bundle ?? "unknown"

        Task { @MainActor [weak self] in
            guard let self else { return }

            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == targetBundle }) {
                _ = app.activate(options: [.activateIgnoringOtherApps])
                try? await Task.sleep(nanoseconds: 180_000_000)
            }

            let before = captureMainDisplaySnapshot(tag: "before")
            let dockBefore = dockWindowSignatureSnapshot()
            let baseline = Date()
            invoker.invokeApplicationWindows(for: targetBundle)

            let resolved = invoker.lastResolvedHotKey
                .map { "keyCode=\($0.keyCode) flags=\($0.flags.rawValue)" }
                ?? "nil"
            let resolveError = invoker.lastResolveError ?? "none"
            let strategy = invoker.lastInvokeStrategy?.rawValue ?? "none"
            let forced = invoker.lastForcedStrategy ?? (ProcessInfo.processInfo.environment["DOCKACTIONER_APPEXPOSE_STRATEGY"] ?? "none")
            let attempts = invoker.lastInvokeAttempts.joined(separator: ",")

            var bestMetrics: ImageDiffMetrics?
            var bestSnapshot: DisplaySnapshot?
            var maxDockSignatureDelta = 0

            let sampleDelays: [UInt64] = [220_000_000, 420_000_000, 680_000_000]
            for (index, delay) in sampleDelays.enumerated() {
                try? await Task.sleep(nanoseconds: delay)
                let after = captureMainDisplaySnapshot(tag: "after-\(index + 1)")
                if let after {
                    if let before, let metrics = imageDiffMetrics(before: before.image, after: after.image) {
                        if bestMetrics == nil || metrics.changedPixelRatio > (bestMetrics?.changedPixelRatio ?? 0) {
                            bestMetrics = metrics
                            bestSnapshot = after
                        }
                    }
                }

                let dockAfter = dockWindowSignatureSnapshot()
                let delta = dockBefore.symmetricDifference(dockAfter).count
                if delta > maxDockSignatureDelta {
                    maxDockSignatureDelta = delta
                }
            }

            let front = FrontmostAppTracker.frontmostBundleIdentifier() ?? "nil"
            let beforePath = before?.url?.path ?? "nil"
            let afterPath = bestSnapshot?.url?.path ?? "nil"
            let ratioText = bestMetrics.map { String(format: "%.4f", $0.changedPixelRatio) } ?? "unknown"
            let meanText = bestMetrics.map { String(format: "%.4f", $0.meanAbsDelta) } ?? "unknown"
            let sampleCount = bestMetrics?.sampledPixels ?? 0

            let visualEvidenceStrong = (bestMetrics?.changedPixelRatio ?? 0) >= appExposeImageDiffThreshold
            let dockEvidencePresent = maxDockSignatureDelta > 0
            let evidence = visualEvidenceStrong || dockEvidencePresent || front == "com.apple.dock"

            let base = "App Expose test: triggered for \(targetBundle) at \(baseline). strategy=\(strategy) forced=\(forced) attempts=\(attempts). resolved=\(resolved) resolveError=\(resolveError). frontmost=\(front). diffChangedRatio=\(ratioText) diffMean=\(meanText) pixels=\(sampleCount) dockSignatureDelta=\(maxDockSignatureDelta) evidence=\(evidence). before=\(beforePath). after=\(afterPath)"

            if let prior = appExposeHotkeyTestStatus, !prior.isEmpty {
                appExposeHotkeyTestStatus = "\(prior)\n\(base)"
            } else {
                appExposeHotkeyTestStatus = base
            }
            Logger.log(appExposeHotkeyTestStatus ?? base)
        }
    }

    private func findAnyDockIconPoint() -> (CGPoint, String)? {
        var count: UInt32 = 0
        if CGGetActiveDisplayList(0, nil, &count) != .success || count == 0 {
            return nil
        }
        var displays = Array(repeating: CGDirectDisplayID(0), count: Int(count))
        if CGGetActiveDisplayList(count, &displays, &count) != .success {
            return nil
        }

        for id in displays {
            let b = CGDisplayBounds(id)

            // Bottom edge probe (most common).
            if let match = probeEdge(bounds: b, edge: .bottom) { return match }
            if let match = probeEdge(bounds: b, edge: .left) { return match }
            if let match = probeEdge(bounds: b, edge: .right) { return match }
        }
        return nil
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

    private func probeEdge(bounds: CGRect, edge: Edge) -> (CGPoint, String)? {
        let margin: CGFloat = 16
        let step: CGFloat = 18
        let startInset: CGFloat = 60

        switch edge {
        case .bottom:
            let y = bounds.maxY - margin
            var x = bounds.minX + startInset
            while x < bounds.maxX - startInset {
                let p = CGPoint(x: x, y: y)
                if let bundle = bundleIdentifierNearPoint(p) {
                    return (p, bundle)
                }
                x += step
            }
        case .left:
            let x = bounds.minX + margin
            var y = bounds.minY + startInset
            while y < bounds.maxY - startInset {
                let p = CGPoint(x: x, y: y)
                if let bundle = bundleIdentifierNearPoint(p) {
                    return (p, bundle)
                }
                y += step
            }
        case .right:
            let x = bounds.maxX - margin
            var y = bounds.minY + startInset
            while y < bounds.maxY - startInset {
                let p = CGPoint(x: x, y: y)
                if let bundle = bundleIdentifierNearPoint(p) {
                    return (p, bundle)
                }
                y += step
            }
        }
        return nil
    }

    private func probeEdgeForBundle(bounds: CGRect, edge: Edge, bundleIdentifier: String) -> CGPoint? {
        let margin: CGFloat = 10
        let step: CGFloat = 16
        let startInset: CGFloat = 40
        let depth: CGFloat = 240
        let depthStep: CGFloat = 8

        switch edge {
        case .bottom:
            var y = bounds.maxY - margin
            while y > bounds.maxY - depth {
                var x = bounds.minX + startInset
                while x < bounds.maxX - startInset {
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
                var y = bounds.minY + startInset
                while y < bounds.maxY - startInset {
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
                var y = bounds.minY + startInset
                while y < bounds.maxY - startInset {
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
            down.setIntegerValueField(.eventSourceUserData, value: 0xD0C0A11)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            up.flags = []
            up.setIntegerValueField(.eventSourceUserData, value: 0xD0C0A11)
            up.post(tap: .cghidEventTap)
        }
    }

    func postSyntheticScroll(at point: CGPoint, deltaY: Int32) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        guard let ev = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0) else { return }
        ev.location = point
        ev.flags = []
        ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        ev.setIntegerValueField(.eventSourceUserData, value: 0xD0C0A11)
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
        if selfTestActive {
            if let bundle = DockHitTest.bundleIdentifierAtPoint(location) {
                lastDockBundleHit = bundle
                lastDockBundleHitAt = Date()
            }
            return phase != .dragged
        }

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
            guard let clickedBundle = DockHitTest.bundleIdentifierAtPoint(location) else {
                pendingClickContext = nil
                pendingClickWasDragged = false
                return false
            }

            if diagnosticsCaptureActive {
                lastDockBundleHit = clickedBundle
                lastDockBundleHitAt = Date()
            }

            let context = PendingClickContext(location: location,
                                              buttonNumber: buttonNumber,
                                              flags: flags,
                                              frontmostBefore: FrontmostAppTracker.frontmostBundleIdentifier(),
                                              clickedBundle: clickedBundle,
                                              consumeClick: false)
            let consumeClick = shouldConsumeClick(for: context)
            pendingClickContext = PendingClickContext(location: context.location,
                                                     buttonNumber: context.buttonNumber,
                                                     flags: context.flags,
                                                     frontmostBefore: context.frontmostBefore,
                                                     clickedBundle: context.clickedBundle,
                                                     consumeClick: consumeClick)
            pendingClickWasDragged = false
            return consumeClick

        case .dragged:
            if let context = pendingClickContext {
                pendingClickWasDragged = true
                Logger.debug("WORKFLOW: Click became drag; suppressing click action")
                return context.consumeClick
            }
            return false

        case .up:
            guard let context = pendingClickContext else {
                return false
            }

            defer {
                pendingClickContext = nil
                pendingClickWasDragged = false
            }

            if pendingClickWasDragged {
                Logger.debug("WORKFLOW: Drag completed; allowing Dock drop behavior")
                return context.consumeClick
            }

            let consumeNow = executeClickAction(context)
            if consumeNow != context.consumeClick {
                Logger.debug("WORKFLOW: Click consume mismatch planned=\(context.consumeClick) actual=\(consumeNow)")
            }
            return context.consumeClick
        }
    }

    private func executeClickAction(_ context: PendingClickContext) -> Bool {
        let location = context.location
        let buttonNumber = context.buttonNumber
        let flags = context.flags
        let frontmostBefore = context.frontmostBefore
        let clickedBundle = context.clickedBundle

        Logger.debug("WORKFLOW: frontmost=\(frontmostBefore ?? "nil"), clicked=\(clickedBundle), lastTriggered=\(lastTriggeredBundle ?? "nil"), currentExpose=\(currentExposeApp ?? "nil")")

        let isRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == clickedBundle }
        if !isRunning && lastTriggeredBundle != nil {
            Logger.debug("WORKFLOW: App Exposé active, clicked app \(clickedBundle) is not running - launching and deactivating App Exposé")
            resetExposeTracking()
            launchApp(bundleIdentifier: clickedBundle)
            return true
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
                return true
            }

            Logger.debug("WORKFLOW: Deactivate click on currentExposeApp (\(clickedBundle)); exiting App Exposé and activating app")
            exitAppExpose()
            _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: clickedBundle)
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
                return executeFirstClickAction(for: clickedBundle, flags: flags, frontmostBefore: frontmostBefore)
            }
        }

        if let lastBundle = lastTriggeredBundle, lastBundle == clickedBundle {
            if frontmostBefore == clickedBundle {
                Logger.debug("WORKFLOW: App Exposé already closed for \(clickedBundle); clearing state")
                resetExposeTracking()
            } else {
                Logger.debug("WORKFLOW: Deactivate click on original trigger app (\(clickedBundle)), staying on this app")
                resetExposeTracking()
                return false
            }
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
            Logger.debug("WORKFLOW: App Exposé trigger from click")
            triggerAppExpose(for: clickedBundle)
            return true
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

    private func handleScroll(at location: CGPoint, direction: ScrollDirection, flags: CGEventFlags) -> Bool {
        if selfTestActive {
            if let bundle = DockHitTest.bundleIdentifierAtPoint(location) {
                lastDockBundleHit = bundle
                lastDockBundleHitAt = Date()
                return true
            }
            return true
        }

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

        if direction == .up, let current = currentExposeApp, current == clickedBundle, lastTriggeredBundle != nil {
            Logger.debug("WORKFLOW: Scroll up detected while App Exposé active for \(clickedBundle) - exiting")
            exitAppExpose()
            return true
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
            return true
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

    private func executeFirstClickBehavior(for bundleIdentifier: String) -> Bool {
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
            if preferences.firstClickAppExposeRequiresMultipleWindows,
               !WindowManager.hasMultipleWindowsOpen(bundleIdentifier: bundleIdentifier) {
                Logger.debug("WORKFLOW: First click appExpose skipped for \(bundleIdentifier): fewer than two windows")
                return false
            }
            lastActionExecuted = .appExpose
            lastActionExecutedBundle = bundleIdentifier
            lastActionExecutedSource = "firstClick"
            lastActionExecutedAt = Date()
            Logger.debug("WORKFLOW: First click behavior=appExpose executed for \(bundleIdentifier)")
            triggerAppExpose(for: bundleIdentifier)
            return true
        }
    }

    private func executeFirstClickAction(for bundleIdentifier: String,
                                         flags: CGEventFlags,
                                         frontmostBefore: String?) -> Bool {
        let modifier = modifierCombination(from: flags)

        if modifier == .none {
            return executeFirstClickBehavior(for: bundleIdentifier)
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
           preferences.firstClickAppExposeRequiresMultipleWindows,
           !WindowManager.hasMultipleWindowsOpen(bundleIdentifier: bundleIdentifier) {
            Logger.debug("WORKFLOW: First click modifier appExpose skipped for \(bundleIdentifier): fewer than two windows")
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
            return true
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
        clearAppExposeActivationObserver()
        appExposeInvocationToken = nil
        lastTriggeredBundle = nil
        currentExposeApp = nil
        appsWithoutWindowsInExpose.removeAll()
    }

    private func clearAppExposeActivationObserver() {
        if let observer = appExposeActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appExposeActivationObserver = nil
        }
    }

    private func completeAppExposeInvocation(token: UUID,
                                             bundleIdentifier: String,
                                             reason: String,
                                             frontmost: String?,
                                             startedAt: Date) {
        guard appExposeInvocationToken == token else { return }

        appExposeInvocationToken = nil
        clearAppExposeActivationObserver()

        invoker.invokeApplicationWindows(for: bundleIdentifier)
        lastTriggeredBundle = bundleIdentifier
        currentExposeApp = bundleIdentifier

        let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let frontmostText = frontmost ?? "nil"
        Logger.debug("WORKFLOW: App Exposé trigger reason=\(reason) target=\(bundleIdentifier) frontmost=\(frontmostText) latencyMs=\(latencyMs)")
    }

    private func shouldConsumeClick(for context: PendingClickContext) -> Bool {
        let frontmostBefore = context.frontmostBefore
        let clickedBundle = context.clickedBundle
        let flags = context.flags

        let isRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == clickedBundle }
        if !isRunning && lastTriggeredBundle != nil {
            return true
        }

        if let currentApp = currentExposeApp,
           currentApp == clickedBundle,
           lastTriggeredBundle != nil,
           frontmostBefore != clickedBundle {
            return true
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
            return configuredAction(for: .click, flags: flags) != .none
        }

        return configuredAction(for: .click, flags: flags) != .none
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
                if preferences.firstClickAppExposeRequiresMultipleWindows,
                   !WindowManager.hasMultipleWindowsOpen(bundleIdentifier: bundleIdentifier) {
                    return false
                }
                return true
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
           preferences.firstClickAppExposeRequiresMultipleWindows,
           !WindowManager.hasMultipleWindowsOpen(bundleIdentifier: bundleIdentifier) {
            return false
        }

        return action != .none
    }

    private func performActivateAppAction(bundleIdentifier: String) -> Bool {
        let isRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleIdentifier }
        if !isRunning {
            launchApp(bundleIdentifier: bundleIdentifier)
            resetExposeTracking()
            return true
        }

        if WindowManager.isAppHidden(bundleIdentifier: bundleIdentifier) {
            _ = WindowManager.unhideApp(bundleIdentifier: bundleIdentifier)
        }

        _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: bundleIdentifier)
        resetExposeTracking()
        return true
    }

    private func performSingleAppMode(targetBundleIdentifier: String, frontmostBefore: String?) {
        Logger.debug("WORKFLOW: Single app mode target=\(targetBundleIdentifier), frontmostBefore=\(frontmostBefore ?? "nil")")

        if frontmostBefore == targetBundleIdentifier {
            _ = WindowManager.hideAllWindows(bundleIdentifier: targetBundleIdentifier)
            resetExposeTracking()
            return
        }

        if let frontmostBefore {
            _ = WindowManager.hideAllWindows(bundleIdentifier: frontmostBefore)
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

        clearAppExposeActivationObserver()
        let invocationToken = UUID()
        appExposeInvocationToken = invocationToken
        let startedAt = Date()

        let frontmost = FrontmostAppTracker.frontmostBundleIdentifier()
        let needsActivation = frontmost != bundleIdentifier
        if !needsActivation {
            completeAppExposeInvocation(token: invocationToken,
                                        bundleIdentifier: bundleIdentifier,
                                        reason: "already-frontmost",
                                        frontmost: frontmost,
                                        startedAt: startedAt)
            return
        }

        appExposeActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let activatedBundle = app?.bundleIdentifier
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.appExposeInvocationToken == invocationToken else { return }

                if activatedBundle == bundleIdentifier {
                    self.completeAppExposeInvocation(token: invocationToken,
                                                    bundleIdentifier: bundleIdentifier,
                                                    reason: "activation-notification",
                                                    frontmost: FrontmostAppTracker.frontmostBundleIdentifier(),
                                                    startedAt: startedAt)
                }
            }
        }

        if !WindowManager.activateAndShowMainWindow(bundleIdentifier: bundleIdentifier),
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            _ = app.activate(options: [])
        }

        let maxChecks = 20
        let checkDelay: TimeInterval = 0.025
        for attempt in 1...maxChecks {
            let delay = checkDelay * Double(attempt)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                guard self.appExposeInvocationToken == invocationToken else { return }

                let currentFrontmost = FrontmostAppTracker.frontmostBundleIdentifier()
                if currentFrontmost == bundleIdentifier {
                    self.completeAppExposeInvocation(token: invocationToken,
                                                    bundleIdentifier: bundleIdentifier,
                                                    reason: "poll-ready-\(attempt)",
                                                    frontmost: currentFrontmost,
                                                    startedAt: startedAt)
                    return
                }

                if attempt == maxChecks {
                    self.completeAppExposeInvocation(token: invocationToken,
                                                    bundleIdentifier: bundleIdentifier,
                                                    reason: "poll-timeout",
                                                    frontmost: currentFrontmost,
                                                    startedAt: startedAt)
                }
            }
        }
    }
    
    private func exitAppExpose() {
        Logger.debug("WORKFLOW: Exiting App Exposé via Escape")
        clearAppExposeActivationObserver()
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
    
    private func activateApp(bundleIdentifier: String) {
        let beforeActivate = FrontmostAppTracker.frontmostBundleIdentifier()
        Logger.debug("WORKFLOW: Activating app \(bundleIdentifier) after App Exposé closed")
        Logger.debug("WORKFLOW: Frontmost before activation: \(beforeActivate ?? "nil")")
        
        // Try multiple activation methods for reliability
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            Logger.debug("WORKFLOW: Found running app \(bundleIdentifier), attempting activation")
            
            // Method 1: Try NSRunningApplication.activate()
            let success1 = app.activate(options: [.activateIgnoringOtherApps])
            Logger.debug("WORKFLOW: NSRunningApplication.activate() returned: \(success1)")
            
            // Check frontmost app after a brief moment to see if activation worked
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let afterActivate = FrontmostAppTracker.frontmostBundleIdentifier()
                Logger.debug("WORKFLOW: Frontmost after activation (0.1s): \(afterActivate ?? "nil")")
                if afterActivate != bundleIdentifier {
                    Logger.debug("WORKFLOW: WARNING - Expected \(bundleIdentifier) but got \(afterActivate ?? "nil")")
                } else {
                    Logger.debug("WORKFLOW: SUCCESS - App \(bundleIdentifier) is now frontmost")
                }
            }
        } else {
            Logger.debug("WORKFLOW: App \(bundleIdentifier) is not running, cannot activate")
        }
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
