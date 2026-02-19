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
    private var cartesianDockPointCache: [String: CGPoint] = [:]
    private var cartesianClickProbe: CartesianClickProbe?

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
    @Published private(set) var appExposeCartesianTestStatus: String?

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

    private enum ScenarioWindowState: String, CaseIterable, Codable {
        case zeroWindows = "0_windows"
        case oneWindow = "1_window"
        case twoPlusWindows = "2plus_windows"
        case twoPlusHiddenWindows = "2plus_hidden_windows"
        case twoPlusMinimizedWindows = "2plus_minimized_windows"
    }

    private enum ScenarioFocusState: String, CaseIterable, Codable {
        case targetFrontmost = "target_frontmost"
        case otherAppFrontmost = "other_app_frontmost"
        case targetHidden = "target_hidden"
    }

    private enum ScenarioInExposeAction: String, CaseIterable, Codable {
        case selectTargetWindow = "select_target_window"
        case clickNegativeSpace = "click_negative_space"
        case pressEscape = "press_escape"
        case clickSameAppDockIcon = "click_same_app_dock_icon"
        case clickOtherAppDockIcon = "click_other_app_dock_icon"
        case cmdTabOtherApp = "cmd_tab_other_app"
        case noInputTimeout3s = "no_input_timeout_3s"
    }

    private enum ScenarioPostExitAction: String, CaseIterable, Codable {
        case clickSameAppIcon = "click_same_app_icon"
        case clickOtherAppIcon = "click_other_app_icon"
        case clickTargetWindow = "click_target_window"
        case reenterAppExposeSameApp = "reenter_app_expose_same_app"
        case reenterAppExposeAfterSwitch = "reenter_app_expose_after_switch"
    }

    private enum ScenarioReentryDepth: String, CaseIterable, Codable {
        case single = "single"
        case doubleImmediate = "double_immediate"
        case tripleAlternating = "triple_alternating"
    }

    private enum ScenarioStep: String, Codable {
        case prepareWindowState = "prepare_window_state"
        case primeFocusState = "prime_focus_state"
        case triggerFirstClick = "trigger_first_click"
        case performInExposeAction = "perform_in_expose_action"
        case performPostExitAction = "perform_post_exit_action"
        case validateReentry = "validate_reentry"
        case probeDockResponsiveness = "probe_dock_responsiveness"
        case validateStateConsistency = "validate_state_consistency"
        case finalize = "finalize"
    }

    private enum ScenarioFailureBucket: String, Codable {
        case triggerMissed = "trigger_missed"
        case exitStuck = "exit_stuck"
        case dockUnresponsive = "dock_unresponsive"
        case reentryBroken = "reentry_broken"
        case wrongTargetWindow = "wrong_target_window"
    }

    private struct ScenarioOracle: Codable {
        let expectedTrigger: Bool
        let responsivenessWarnMs: Double
        let responsivenessHardFailMs: Double
        let requiresStateResetAfterCancel: Bool
    }

    private struct AppExposeScenario: Codable {
        let id: String
        let family: String
        let targetBundle: String
        let requiresMultipleWindows: Bool
        let windowState: ScenarioWindowState
        let focusState: ScenarioFocusState
        let inExposeAction: ScenarioInExposeAction
        let postExitAction: ScenarioPostExitAction
        let reentryDepth: ScenarioReentryDepth
    }

    private struct ScenarioWindowPreparation: Codable {
        let requested: ScenarioWindowState
        let observedTotalWindows: Int
        let observedHidden: Bool
        let observedAllMinimized: Bool
        let achieved: Bool
        let detail: String
    }

    private struct AppExposeScenarioResult: Codable {
        let scenario: AppExposeScenario
        let phase: String
        let runIndex: Int
        let startedAt: String
        let finishedAt: String
        let passed: Bool
        let failureBucket: ScenarioFailureBucket?
        let oracle: ScenarioOracle
        let triggered: Bool
        let inExposeExitOK: Bool
        let reentryOK: Bool
        let stateConsistencyOK: Bool
        let setupOK: Bool
        let dockResponseLatencyMs: Double?
        let frontmostBefore: String
        let frontmostAfter: String
        let stepTrace: [ScenarioStep]
        let setup: ScenarioWindowPreparation
        let details: String
    }

    private struct AppExposeFailureRecord: Codable {
        let scenarioID: String
        let targetBundle: String
        let phase: String
        let runIndex: Int
        let tuple: String
        let family: String
        let bucket: String
        let details: String
    }

    private struct ScenarioHistory {
        let scenario: AppExposeScenario
        var runs: Int
        var failures: Int
        var failureSamples: [String]
    }

    private struct ScenarioActionOutcome {
        let ok: Bool
        let detail: String
    }

    private struct CartesianClickProbe {
        let token: UUID
        let expectedBundle: String
        let startedAt: Date
        var observedDownBundle: String?
        var observedDownAt: Date?
        var observedUpBundle: String?
        var observedUpAt: Date?
    }

    private struct CartesianClickDispatchResult {
        let sent: Bool
        let expectedBundle: String
        let clickPoint: CGPoint?
        let observedDownBundle: String?
        let observedUpBundle: String?
        let observedDownMs: Double?
        let observedUpMs: Double?
        let mode: String

        var summary: String {
            let pointText: String
            if let clickPoint {
                pointText = "(\(Int(clickPoint.x)),\(Int(clickPoint.y)))"
            } else {
                pointText = "nil"
            }

            let downText = observedDownBundle ?? "nil"
            let upText = observedUpBundle ?? "nil"
            let downMsText = observedDownMs.map { String(format: "%.1f", $0) } ?? "nil"
            let upMsText = observedUpMs.map { String(format: "%.1f", $0) } ?? "nil"

            return "sent=\(sent),mode=\(mode),expected=\(expectedBundle),point=\(pointText),down=\(downText),downMs=\(downMsText),up=\(upText),upMs=\(upMsText)"
        }
    }

    private struct AppExposeCartesianArtifacts {
        let rootDirectory: URL
        let scenariosJSONL: URL
        let failuresJSONL: URL
        let timelineLog: URL
        let summaryJSON: URL
        let reproMarkdown: URL
    }

    private struct AppExposeCartesianSummary: Codable {
        struct PhaseCount: Codable {
            let total: Int
            let passed: Int
            let failed: Int
        }

        struct FamilyCoverage: Codable {
            let total: Int
            let failed: Int
        }

        let profile: String
        let generatedAt: String
        let artifactDirectory: String
        let targets: [String]
        let scenarioDefinitions: Int
        let totalRuns: Int
        let passedRuns: Int
        let failedRuns: Int
        let passRate: Double
        let p95DockResponseLatencyMs: Double?
        let failureBuckets: [String: Int]
        let phaseCounts: [String: PhaseCount]
        let familyCoverage: [String: FamilyCoverage]
        let isolatedRerunTotal: Int
        let isolatedRerunPassed: Int
        let isolatedRerunFailed: Int
    }

    private enum AppExposeCartesianProfile: String {
        case bootstrap = "bootstrap"
        case focused = "focused"
        case compact = "compact"
        case full = "full"
    }

    private struct CompactScenarioTemplate {
        let family: String
        let focusState: ScenarioFocusState
        let inExposeAction: ScenarioInExposeAction
        let postExitAction: ScenarioPostExitAction
        let reentryDepth: ScenarioReentryDepth
        let windowStates: [ScenarioWindowState]
        let requiresMultipleValues: [Bool]
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

    func runAppExposeCartesianTestSuite() {
        appExposeCartesianTestStatus = "Running App Expose cartesian regression test..."

        Task { [weak self] in
            guard let self else { return }
            let env = ProcessInfo.processInfo.environment

            func failAndTerminate(_ message: String) async {
                await MainActor.run {
                    self.appExposeCartesianTestStatus = message
                    Logger.log(message)
                    if env["DOCKACTIONER_APPEXPOSE_CARTESIAN_TEST"] == "1" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            NSApp.terminate(nil)
                        }
                    }
                }
            }

            refreshPermissionsAndSecurityState()

            if !isRunning {
                startIfPossible()
            }
            guard isRunning else {
                await failAndTerminate("App Expose cartesian test failed: event tap not running (\(lastStartError ?? "unknown error"))")
                return
            }

            if !accessibilityGranted {
                Logger.log("App Expose cartesian test warning: Accessibility not granted flag; continuing because event tap is running")
            }
            if !inputMonitoringGranted {
                Logger.log("App Expose cartesian test warning: Input Monitoring not granted flag; continuing because event tap is running")
            }

            let profile = resolveAppExposeCartesianProfile(from: env)
            let targets = resolveAppExposeCartesianTargets(from: env, profile: profile)
            let maxScenarios = max(0, Int(env["DOCKACTIONER_APPEXPOSE_CARTESIAN_MAX_SCENARIOS"] ?? "0") ?? 0)
            let defaultStressRepeat: Int
            let defaultIsolatedReruns: Int
            switch profile {
            case .bootstrap:
                defaultStressRepeat = 1
                defaultIsolatedReruns = 0
            case .focused:
                defaultStressRepeat = 0
                defaultIsolatedReruns = 0
            case .compact:
                defaultStressRepeat = 1
                defaultIsolatedReruns = 5
            case .full:
                defaultStressRepeat = 3
                defaultIsolatedReruns = 10
            }
            let stressRepeat = max(0, Int(env["DOCKACTIONER_APPEXPOSE_CARTESIAN_REPEAT"] ?? "\(defaultStressRepeat)") ?? defaultStressRepeat)
            let isolatedReruns = max(0, Int(env["DOCKACTIONER_APPEXPOSE_CARTESIAN_RERUNS"] ?? "\(defaultIsolatedReruns)") ?? defaultIsolatedReruns)
            let specificScenarioID = env["DOCKACTIONER_APPEXPOSE_CARTESIAN_SCENARIO_ID"]

            guard let artifacts = createAppExposeCartesianArtifacts() else {
                await failAndTerminate("App Expose cartesian test failed: unable to create artifacts directory")
                return
            }

            var scenarios = buildAppExposeCartesianScenarios(targets: targets, profile: profile)
            if let specificScenarioID, !specificScenarioID.isEmpty {
                scenarios = scenarios.filter { $0.id == specificScenarioID }
            }
            if maxScenarios > 0 {
                scenarios = Array(scenarios.prefix(maxScenarios))
            }

            guard !scenarios.isEmpty else {
                await failAndTerminate("App Expose cartesian test failed: no scenarios selected")
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
            preferences.clickAction = .appExpose
            cartesianDockPointCache.removeAll()

            let phases: [(name: String, runs: Int)]
            switch profile {
            case .focused:
                phases = [
                    ("cold", 1),
                    ("warm", 1)
                ]
            default:
                phases = [
                    ("cold", 1),
                    ("warm", 1),
                    ("stress", stressRepeat)
                ]
            }
            let totalPlannedRuns = scenarios.count * phases.reduce(0) { $0 + $1.runs }

            var totalRuns = 0
            var passedRuns = 0
            var failedRuns = 0
            var latencySamples: [Double] = []
            var failureBuckets: [ScenarioFailureBucket: Int] = [:]
            var phaseCounts: [String: AppExposeCartesianSummary.PhaseCount] = [:]
            var familyCoverage: [String: AppExposeCartesianSummary.FamilyCoverage] = [:]
            var histories: [String: ScenarioHistory] = [:]

            for family in requiredScenarioFamilies() {
                familyCoverage[family] = .init(total: 0, failed: 0)
            }

            appendLine("App Expose cartesian run started at \(iso8601String(Date()))", to: artifacts.timelineLog)
            appendLine("profile=\(profile.rawValue) targets=\(targets.joined(separator: ",")) scenarios=\(scenarios.count) stressRepeat=\(stressRepeat)", to: artifacts.timelineLog)

            var globalRunIndex = 0
            for target in targets {
                let perTarget = scenarios.filter { $0.targetBundle == target }
                if perTarget.isEmpty {
                    continue
                }

                appendLine("[\(iso8601String(Date()))] target-start \(target) scenarios=\(perTarget.count)", to: artifacts.timelineLog)
                for phase in phases {
                    var phaseTotal = phaseCounts[phase.name]?.total ?? 0
                    var phasePassed = phaseCounts[phase.name]?.passed ?? 0
                    var phaseFailed = phaseCounts[phase.name]?.failed ?? 0

                    for run in 1...phase.runs {
                        for scenario in perTarget {
                            globalRunIndex += 1
                            appExposeCartesianTestStatus = "App Expose cartesian test: run \(globalRunIndex)/\(totalPlannedRuns) target=\(scenario.targetBundle) phase=\(phase.name)"

                            appendLine("[\(iso8601String(Date()))] scenario-start id=\(scenario.id) phase=\(phase.name) run=\(run)", to: artifacts.timelineLog)
                            let result = await executeAppExposeCartesianScenario(scenario,
                                                                                 phase: phase.name,
                                                                                 runIndex: run,
                                                                                 targetPool: targets)
                            appendLine("[\(iso8601String(Date()))] scenario-end id=\(scenario.id) passed=\(result.passed) bucket=\(result.failureBucket?.rawValue ?? "none") latencyMs=\(result.dockResponseLatencyMs.map { String(format: "%.1f", $0) } ?? "nil")", to: artifacts.timelineLog)

                            if let json = jsonLine(result) {
                                appendLine(json, to: artifacts.scenariosJSONL)
                            }
                            if !result.passed {
                                let failure = AppExposeFailureRecord(
                                    scenarioID: result.scenario.id,
                                    targetBundle: result.scenario.targetBundle,
                                    phase: result.phase,
                                    runIndex: result.runIndex,
                                    tuple: scenarioTuple(result.scenario),
                                    family: result.scenario.family,
                                    bucket: result.failureBucket?.rawValue ?? "unknown",
                                    details: result.details
                                )
                                if let json = jsonLine(failure) {
                                    appendLine(json, to: artifacts.failuresJSONL)
                                }
                            }

                            totalRuns += 1
                            phaseTotal += 1
                            if result.passed {
                                passedRuns += 1
                                phasePassed += 1
                            } else {
                                failedRuns += 1
                                phaseFailed += 1
                            }

                            if let latency = result.dockResponseLatencyMs {
                                latencySamples.append(latency)
                            }
                            if let bucket = result.failureBucket {
                                failureBuckets[bucket, default: 0] += 1
                            }

                            var coverage = familyCoverage[result.scenario.family] ?? .init(total: 0, failed: 0)
                            coverage = .init(total: coverage.total + 1,
                                             failed: coverage.failed + (result.passed ? 0 : 1))
                            familyCoverage[result.scenario.family] = coverage

                            var history = histories[result.scenario.id] ?? ScenarioHistory(scenario: result.scenario,
                                                                                            runs: 0,
                                                                                            failures: 0,
                                                                                            failureSamples: [])
                            history.runs += 1
                            if !result.passed {
                                history.failures += 1
                                if history.failureSamples.count < 5 {
                                    history.failureSamples.append(result.details)
                                }
                            }
                            histories[result.scenario.id] = history
                        }
                    }

                    phaseCounts[phase.name] = .init(total: phaseTotal, passed: phasePassed, failed: phaseFailed)
                }
                appendLine("[\(iso8601String(Date()))] target-end \(target)", to: artifacts.timelineLog)
            }

            let failedScenarioDefinitions = histories.values.filter { $0.failures > 0 }.map { $0.scenario }
            var isolatedRerunTotal = 0
            var isolatedRerunPassed = 0
            var isolatedRerunFailed = 0
            var isolatedOutcomes: [String: [Bool]] = [:]

            if isolatedReruns > 0 && !failedScenarioDefinitions.isEmpty {
                appendLine("[\(iso8601String(Date()))] isolated-reruns-start count=\(failedScenarioDefinitions.count) iterations=\(isolatedReruns)", to: artifacts.timelineLog)
                for scenario in failedScenarioDefinitions {
                    for iteration in 1...isolatedReruns {
                        let rerun = await executeAppExposeCartesianScenario(scenario,
                                                                            phase: "isolated-rerun",
                                                                            runIndex: iteration,
                                                                            targetPool: targets)
                        isolatedRerunTotal += 1
                        if rerun.passed {
                            isolatedRerunPassed += 1
                        } else {
                            isolatedRerunFailed += 1
                        }
                        isolatedOutcomes[scenario.id, default: []].append(rerun.passed)

                        if let json = jsonLine(rerun) {
                            appendLine(json, to: artifacts.scenariosJSONL)
                        }
                        if !rerun.passed {
                            let failure = AppExposeFailureRecord(
                                scenarioID: rerun.scenario.id,
                                targetBundle: rerun.scenario.targetBundle,
                                phase: rerun.phase,
                                runIndex: rerun.runIndex,
                                tuple: scenarioTuple(rerun.scenario),
                                family: rerun.scenario.family,
                                bucket: rerun.failureBucket?.rawValue ?? "unknown",
                                details: rerun.details
                            )
                            if let json = jsonLine(failure) {
                                appendLine(json, to: artifacts.failuresJSONL)
                            }
                        }
                    }
                }
                appendLine("[\(iso8601String(Date()))] isolated-reruns-end total=\(isolatedRerunTotal) passed=\(isolatedRerunPassed) failed=\(isolatedRerunFailed)", to: artifacts.timelineLog)
            }

            let passRate = totalRuns > 0 ? Double(passedRuns) / Double(totalRuns) : 0.0
            let p95Latency = percentile95(values: latencySamples)

            var bucketSummary: [String: Int] = [:]
            for bucket in [
                ScenarioFailureBucket.triggerMissed,
                ScenarioFailureBucket.exitStuck,
                ScenarioFailureBucket.dockUnresponsive,
                ScenarioFailureBucket.reentryBroken,
                ScenarioFailureBucket.wrongTargetWindow
            ] {
                bucketSummary[bucket.rawValue] = 0
            }
            for (bucket, count) in failureBuckets {
                bucketSummary[bucket.rawValue] = count
            }
            let summary = AppExposeCartesianSummary(
                profile: profile.rawValue,
                generatedAt: iso8601String(Date()),
                artifactDirectory: artifacts.rootDirectory.path,
                targets: targets,
                scenarioDefinitions: scenarios.count,
                totalRuns: totalRuns,
                passedRuns: passedRuns,
                failedRuns: failedRuns,
                passRate: passRate,
                p95DockResponseLatencyMs: p95Latency,
                failureBuckets: bucketSummary,
                phaseCounts: phaseCounts,
                familyCoverage: familyCoverage,
                isolatedRerunTotal: isolatedRerunTotal,
                isolatedRerunPassed: isolatedRerunPassed,
                isolatedRerunFailed: isolatedRerunFailed
            )
            writeJSONObject(summary, to: artifacts.summaryJSON)

            let deterministic = histories.values
                .filter { history in
                    guard history.failures > 0 else { return false }
                    if history.failures == history.runs {
                        return true
                    }
                    if let reruns = isolatedOutcomes[history.scenario.id], !reruns.isEmpty {
                        return reruns.allSatisfy { !$0 }
                    }
                    return false
                }
                .sorted { lhs, rhs in
                    if lhs.failures == rhs.failures {
                        return lhs.scenario.id < rhs.scenario.id
                    }
                    return lhs.failures > rhs.failures
                }

            writeAppExposeReproMarkdown(histories: deterministic, artifacts: artifacts, rerunIterations: isolatedReruns)

            let percentText = String(format: "%.2f", passRate * 100.0)
            let latencyText = p95Latency.map { String(format: "%.1fms", $0) } ?? "n/a"
            let summaryText = "App Expose cartesian test (\(profile.rawValue)): passed \(passedRuns)/\(totalRuns) (\(percentText)%) p95Latency=\(latencyText) artifacts=\(artifacts.rootDirectory.path)"
            appExposeCartesianTestStatus = summaryText
            Logger.log(summaryText)

            if env["DOCKACTIONER_APPEXPOSE_CARTESIAN_TEST"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func executeAppExposeCartesianScenario(_ scenario: AppExposeScenario,
                                                   phase: String,
                                                   runIndex: Int,
                                                   targetPool: [String]) async -> AppExposeScenarioResult {
        var stepTrace: [ScenarioStep] = []
        var detailParts: [String] = []

        let startedAt = Date()
        let oracle = scenarioOracle(for: scenario)
        let frontmostBefore = FrontmostAppTracker.frontmostBundleIdentifier() ?? "nil"

        stepTrace.append(.prepareWindowState)
        await ensureAppRunningForFirstClickTest(bundleIdentifier: scenario.targetBundle)
        let setup = await prepareScenarioWindowState(scenario.windowState, targetBundle: scenario.targetBundle)
        detailParts.append("setup=\(setup.detail)")

        stepTrace.append(.primeFocusState)
        let alternateBundle = await resolveAlternateBundle(for: scenario.targetBundle, targetPool: targetPool)
        await primeScenarioFocusState(scenario.focusState,
                                      targetBundle: scenario.targetBundle,
                                      alternateBundle: alternateBundle)

        guard let targetPoint = resolveCartesianDockIconPoint(bundleIdentifier: scenario.targetBundle) else {
            let finished = Date()
            return AppExposeScenarioResult(
                scenario: scenario,
                phase: phase,
                runIndex: runIndex,
                startedAt: iso8601String(startedAt),
                finishedAt: iso8601String(finished),
                passed: false,
                failureBucket: .wrongTargetWindow,
                oracle: oracle,
                triggered: false,
                inExposeExitOK: false,
                reentryOK: false,
                stateConsistencyOK: false,
                setupOK: false,
                dockResponseLatencyMs: nil,
                frontmostBefore: frontmostBefore,
                frontmostAfter: FrontmostAppTracker.frontmostBundleIdentifier() ?? "nil",
                stepTrace: stepTrace,
                setup: setup,
                details: "failed to locate Dock icon for \(scenario.targetBundle)"
            )
        }

        let alternatePoint = alternateBundle.flatMap { resolveCartesianDockIconPoint(bundleIdentifier: $0) }

        preferences.firstClickBehavior = .appExpose
        preferences.clickAction = .appExpose
        preferences.firstClickAppExposeRequiresMultipleWindows = scenario.requiresMultipleWindows

        exitAppExpose()
        try? await Task.sleep(nanoseconds: 120_000_000)

        stepTrace.append(.triggerFirstClick)
        let triggerBaseline = lastActionExecutedAt ?? Date.distantPast
        let triggerClick = await performCartesianDockClick(bundleIdentifier: scenario.targetBundle, at: targetPoint)
        detailParts.append("triggerClick=\(triggerClick.summary)")
        let triggered = await waitForAppExposeTrigger(expectedBundle: scenario.targetBundle,
                                                      baseline: triggerBaseline,
                                                      timeout: 1.4)
        detailParts.append("triggered=\(triggered) expected=\(oracle.expectedTrigger)")

        let triggerMatchesOracle = (triggered == oracle.expectedTrigger)

        var inExposeActionResult = ScenarioActionOutcome(ok: true, detail: "skipped")
        var inExposeExitOK = true
        var postActionResult = ScenarioActionOutcome(ok: true, detail: "skipped")
        var reentryOK = true
        var stateConsistencyOK = true

        if oracle.expectedTrigger && triggered {
            stepTrace.append(.performInExposeAction)
            inExposeActionResult = await performScenarioInExposeAction(scenario.inExposeAction,
                                                                       targetBundle: scenario.targetBundle,
                                                                       targetPoint: targetPoint,
                                                                       alternateBundle: alternateBundle,
                                                                       alternatePoint: alternatePoint)
            detailParts.append("inExposeAction=\(inExposeActionResult.detail)")
            let exposeTrackingActiveAfterInAction = isExposeTrackingActive()
            let expectedTrackingAfterInAction = expectedTrackingStateAfterInExposeAction(scenario.inExposeAction)
            inExposeExitOK = inExposeActionResult.ok && exposeTrackingActiveAfterInAction == expectedTrackingAfterInAction
            if scenario.family.hasPrefix("BOOTSTRAP_") {
                inExposeExitOK = inExposeActionResult.ok
            }

            // Validate cancel/reset semantics immediately after the in-expose action, before any follow-up click.
            stepTrace.append(.validateStateConsistency)
            if oracle.requiresStateResetAfterCancel {
                stateConsistencyOK = !isExposeTrackingActive()
            } else {
                stateConsistencyOK = true
            }
            detailParts.append("stateConsistencyOK=\(stateConsistencyOK)")

            stepTrace.append(.performPostExitAction)
            postActionResult = await performScenarioPostExitAction(action: scenario.postExitAction,
                                                                   depth: scenario.reentryDepth,
                                                                   targetBundle: scenario.targetBundle,
                                                                   targetPoint: targetPoint,
                                                                   alternateBundle: alternateBundle,
                                                                   alternatePoint: alternatePoint)
            detailParts.append("postExitAction=\(postActionResult.detail)")

            stepTrace.append(.validateReentry)
            if scenario.family.hasPrefix("BOOTSTRAP_") {
                reentryOK = true
                detailParts.append("reentryOK=skipped_bootstrap")
            } else if scenario.family.hasPrefix("FOCUSED_") {
                reentryOK = true
                detailParts.append("reentryOK=skipped_focused")
            } else {
                reentryOK = await validateScenarioReentry(depth: scenario.reentryDepth,
                                                          targetBundle: scenario.targetBundle,
                                                          targetPoint: targetPoint,
                                                          alternateBundle: alternateBundle,
                                                          alternatePoint: alternatePoint)
                detailParts.append("reentryOK=\(reentryOK)")
            }
        } else {
            stepTrace.append(.performInExposeAction)
            if triggerMatchesOracle && !oracle.expectedTrigger {
                inExposeActionResult = ScenarioActionOutcome(ok: true, detail: "skipped (expected no App Expose)")
            } else {
                inExposeActionResult = ScenarioActionOutcome(ok: false, detail: "skipped (trigger mismatch)")
            }
            detailParts.append("inExposeAction=\(inExposeActionResult.detail)")
            inExposeExitOK = triggerMatchesOracle

            stepTrace.append(.validateStateConsistency)
            stateConsistencyOK = !isExposeTrackingActive()
            detailParts.append("stateConsistencyOK=\(stateConsistencyOK)")

            if triggerMatchesOracle && !oracle.expectedTrigger {
                stepTrace.append(.performPostExitAction)
                postActionResult = await performScenarioPostExitAction(action: scenario.postExitAction,
                                                                       depth: scenario.reentryDepth,
                                                                       targetBundle: scenario.targetBundle,
                                                                       targetPoint: targetPoint,
                                                                       alternateBundle: alternateBundle,
                                                                       alternatePoint: alternatePoint)
                detailParts.append("postExitAction=\(postActionResult.detail)")

                stepTrace.append(.validateReentry)
                reentryOK = true
                detailParts.append("reentryOK=not_applicable")
            } else {
                stepTrace.append(.performPostExitAction)
                postActionResult = ScenarioActionOutcome(ok: true, detail: "skipped (trigger mismatch)")
                detailParts.append("postExitAction=\(postActionResult.detail)")

                stepTrace.append(.validateReentry)
                reentryOK = true
                detailParts.append("reentryOK=skipped")
            }
        }

        stepTrace.append(.probeDockResponsiveness)
        let dockLatency = await probeScenarioDockResponsiveness(targetBundle: scenario.targetBundle,
                                                                targetPoint: targetPoint,
                                                                alternateBundle: alternateBundle,
                                                                alternatePoint: alternatePoint)
        if let dockLatency {
            detailParts.append(String(format: "dockLatencyMs=%.1f", dockLatency))
        } else {
            detailParts.append("dockLatencyMs=nil")
        }

        stepTrace.append(.finalize)
        exitAppExpose()
        try? await Task.sleep(nanoseconds: 90_000_000)

        let setupOK = setup.achieved
        let postExitOK = postActionResult.ok
        let reentryAndPostOK = reentryOK && postExitOK
        let dockResponsive = dockLatency.map { $0 <= oracle.responsivenessHardFailMs } ?? (!oracle.expectedTrigger || !triggerMatchesOracle)

        let failureBucket: ScenarioFailureBucket?
        if !setupOK {
            failureBucket = .wrongTargetWindow
        } else if !triggerMatchesOracle {
            failureBucket = .triggerMissed
        } else if !inExposeExitOK {
            failureBucket = .exitStuck
        } else if !postExitOK {
            failureBucket = .exitStuck
        } else if !reentryOK {
            failureBucket = .reentryBroken
        } else if !dockResponsive {
            failureBucket = .dockUnresponsive
        } else if !stateConsistencyOK {
            failureBucket = .exitStuck
        } else {
            failureBucket = nil
        }

        let passed = failureBucket == nil
        let finishedAt = Date()

        return AppExposeScenarioResult(
            scenario: scenario,
            phase: phase,
            runIndex: runIndex,
            startedAt: iso8601String(startedAt),
            finishedAt: iso8601String(finishedAt),
            passed: passed,
            failureBucket: failureBucket,
            oracle: oracle,
            triggered: triggered,
            inExposeExitOK: inExposeExitOK,
            reentryOK: reentryAndPostOK,
            stateConsistencyOK: stateConsistencyOK,
            setupOK: setupOK,
            dockResponseLatencyMs: dockLatency,
            frontmostBefore: frontmostBefore,
            frontmostAfter: FrontmostAppTracker.frontmostBundleIdentifier() ?? "nil",
            stepTrace: stepTrace,
            setup: setup,
            details: detailParts.joined(separator: " | ")
        )
    }

    private func scenarioOracle(for scenario: AppExposeScenario) -> ScenarioOracle {
        let suppressedByWindowGate = scenario.requiresMultipleWindows
            && (scenario.windowState == .zeroWindows || scenario.windowState == .oneWindow)
        let requiresStateReset = scenario.inExposeAction == .clickNegativeSpace || scenario.inExposeAction == .pressEscape
        return ScenarioOracle(expectedTrigger: !suppressedByWindowGate,
                              responsivenessWarnMs: 1000.0,
                              responsivenessHardFailMs: 2000.0,
                              requiresStateResetAfterCancel: requiresStateReset)
    }

    private func buildAppExposeCartesianScenarios(targets: [String],
                                                  profile: AppExposeCartesianProfile) -> [AppExposeScenario] {
        switch profile {
        case .bootstrap:
            return buildBootstrapAppExposeScenarios(targets: targets)
        case .focused:
            return buildFocusedAppExposeScenarios(targets: targets)
        case .compact:
            return buildCompactAppExposeScenarios(targets: targets)
        case .full:
            return buildFullAppExposeScenarios(targets: targets)
        }
    }

    private func buildBootstrapAppExposeScenarios(targets: [String]) -> [AppExposeScenario] {
        var scenarios: [AppExposeScenario] = []
        for target in targets {
            let gateOff = AppExposeScenario(
                id: "\(target)|BOOTSTRAP_TRIGGER_GATE_OFF",
                family: "BOOTSTRAP_TRIGGER_GATE_OFF",
                targetBundle: target,
                requiresMultipleWindows: true,
                windowState: .oneWindow,
                focusState: .otherAppFrontmost,
                inExposeAction: .selectTargetWindow,
                postExitAction: .clickTargetWindow,
                reentryDepth: .single
            )
            let gateOn = AppExposeScenario(
                id: "\(target)|BOOTSTRAP_TRIGGER_GATE_ON",
                family: "BOOTSTRAP_TRIGGER_GATE_ON",
                targetBundle: target,
                requiresMultipleWindows: false,
                windowState: .oneWindow,
                focusState: .otherAppFrontmost,
                inExposeAction: .selectTargetWindow,
                postExitAction: .clickTargetWindow,
                reentryDepth: .single
            )
            scenarios.append(gateOff)
            scenarios.append(gateOn)
        }
        return scenarios
    }

    private func buildFocusedAppExposeScenarios(targets: [String]) -> [AppExposeScenario] {
        var scenarios: [AppExposeScenario] = []
        for target in targets {
            scenarios.append(AppExposeScenario(
                id: "\(target)|FOCUSED_GATE_SUPPRESS",
                family: "FOCUSED_GATE_SUPPRESS",
                targetBundle: target,
                requiresMultipleWindows: true,
                windowState: .oneWindow,
                focusState: .otherAppFrontmost,
                inExposeAction: .selectTargetWindow,
                postExitAction: .clickTargetWindow,
                reentryDepth: .single
            ))
            scenarios.append(AppExposeScenario(
                id: "\(target)|FOCUSED_GATE_ALLOW_MULTI",
                family: "FOCUSED_GATE_ALLOW_MULTI",
                targetBundle: target,
                requiresMultipleWindows: true,
                windowState: .twoPlusWindows,
                focusState: .otherAppFrontmost,
                inExposeAction: .selectTargetWindow,
                postExitAction: .clickTargetWindow,
                reentryDepth: .single
            ))
            scenarios.append(AppExposeScenario(
                id: "\(target)|FOCUSED_GATE_ALLOW_SINGLE",
                family: "FOCUSED_GATE_ALLOW_SINGLE",
                targetBundle: target,
                requiresMultipleWindows: false,
                windowState: .oneWindow,
                focusState: .otherAppFrontmost,
                inExposeAction: .selectTargetWindow,
                postExitAction: .clickTargetWindow,
                reentryDepth: .single
            ))
            scenarios.append(AppExposeScenario(
                id: "\(target)|FOCUSED_NEGSPACE_SAME_MULTI",
                family: "FOCUSED_NEGSPACE_SAME_MULTI",
                targetBundle: target,
                requiresMultipleWindows: true,
                windowState: .twoPlusWindows,
                focusState: .otherAppFrontmost,
                inExposeAction: .clickNegativeSpace,
                postExitAction: .clickSameAppIcon,
                reentryDepth: .single
            ))
            scenarios.append(AppExposeScenario(
                id: "\(target)|FOCUSED_NEGSPACE_OTHER_MULTI",
                family: "FOCUSED_NEGSPACE_OTHER_MULTI",
                targetBundle: target,
                requiresMultipleWindows: true,
                windowState: .twoPlusWindows,
                focusState: .otherAppFrontmost,
                inExposeAction: .clickNegativeSpace,
                postExitAction: .clickOtherAppIcon,
                reentryDepth: .single
            ))
            scenarios.append(AppExposeScenario(
                id: "\(target)|FOCUSED_NEGSPACE_SAME_SINGLE",
                family: "FOCUSED_NEGSPACE_SAME_SINGLE",
                targetBundle: target,
                requiresMultipleWindows: false,
                windowState: .oneWindow,
                focusState: .otherAppFrontmost,
                inExposeAction: .clickNegativeSpace,
                postExitAction: .clickSameAppIcon,
                reentryDepth: .single
            ))
            scenarios.append(AppExposeScenario(
                id: "\(target)|FOCUSED_NEGSPACE_OTHER_SINGLE",
                family: "FOCUSED_NEGSPACE_OTHER_SINGLE",
                targetBundle: target,
                requiresMultipleWindows: false,
                windowState: .oneWindow,
                focusState: .otherAppFrontmost,
                inExposeAction: .clickNegativeSpace,
                postExitAction: .clickOtherAppIcon,
                reentryDepth: .single
            ))
        }
        return scenarios
    }

    private func buildFullAppExposeScenarios(targets: [String]) -> [AppExposeScenario] {
        var scenarios: [AppExposeScenario] = []
        for target in targets {
            for requiresMultipleWindows in [true, false] {
                for windowState in ScenarioWindowState.allCases {
                    for focusState in ScenarioFocusState.allCases {
                        for inExposeAction in ScenarioInExposeAction.allCases {
                            for postExitAction in ScenarioPostExitAction.allCases {
                                for reentryDepth in ScenarioReentryDepth.allCases {
                                    let prototype = AppExposeScenario(
                                        id: "",
                                        family: "",
                                        targetBundle: target,
                                        requiresMultipleWindows: requiresMultipleWindows,
                                        windowState: windowState,
                                        focusState: focusState,
                                        inExposeAction: inExposeAction,
                                        postExitAction: postExitAction,
                                        reentryDepth: reentryDepth
                                    )
                                    let family = appExposeScenarioFamily(for: prototype)
                                    let id = "\(target)|P\(requiresMultipleWindows ? 1 : 0)|W\(windowState.rawValue)|F\(focusState.rawValue)|E\(inExposeAction.rawValue)|A\(postExitAction.rawValue)|R\(reentryDepth.rawValue)"
                                    let scenario = AppExposeScenario(
                                        id: id,
                                        family: family,
                                        targetBundle: target,
                                        requiresMultipleWindows: requiresMultipleWindows,
                                        windowState: windowState,
                                        focusState: focusState,
                                        inExposeAction: inExposeAction,
                                        postExitAction: postExitAction,
                                        reentryDepth: reentryDepth
                                    )
                                    scenarios.append(scenario)
                                }
                            }
                        }
                    }
                }
            }
        }
        return scenarios
    }

    private func buildCompactAppExposeScenarios(targets: [String]) -> [AppExposeScenario] {
        var scenarios: [AppExposeScenario] = []
        for target in targets {
            for template in compactScenarioTemplates() {
                for requiresMultipleWindows in template.requiresMultipleValues {
                    for windowState in template.windowStates {
                        let id = "\(target)|\(template.family)|P\(requiresMultipleWindows ? 1 : 0)|W\(windowState.rawValue)"
                        let scenario = AppExposeScenario(
                            id: id,
                            family: template.family,
                            targetBundle: target,
                            requiresMultipleWindows: requiresMultipleWindows,
                            windowState: windowState,
                            focusState: template.focusState,
                            inExposeAction: template.inExposeAction,
                            postExitAction: template.postExitAction,
                            reentryDepth: template.reentryDepth
                        )
                        scenarios.append(scenario)
                    }
                }
            }
        }
        return scenarios
    }

    private func compactScenarioTemplates() -> [CompactScenarioTemplate] {
        let standardWindows: [ScenarioWindowState] = [.oneWindow, .twoPlusWindows]
        let bothPreferenceModes = [true, false]
        return [
            .init(family: "NEGSPACE_CANCEL_THEN_SAME_ICON",
                  focusState: .otherAppFrontmost,
                  inExposeAction: .clickNegativeSpace,
                  postExitAction: .clickSameAppIcon,
                  reentryDepth: .single,
                  windowStates: standardWindows,
                  requiresMultipleValues: bothPreferenceModes),
            .init(family: "NEGSPACE_CANCEL_THEN_OTHER_ICON",
                  focusState: .otherAppFrontmost,
                  inExposeAction: .clickNegativeSpace,
                  postExitAction: .clickOtherAppIcon,
                  reentryDepth: .single,
                  windowStates: standardWindows,
                  requiresMultipleValues: bothPreferenceModes),
            .init(family: "SELECT_WINDOW_THEN_OTHER_ICON",
                  focusState: .otherAppFrontmost,
                  inExposeAction: .selectTargetWindow,
                  postExitAction: .clickOtherAppIcon,
                  reentryDepth: .single,
                  windowStates: standardWindows,
                  requiresMultipleValues: bothPreferenceModes),
            .init(family: "SELECT_WINDOW_THEN_SAME_ICON",
                  focusState: .otherAppFrontmost,
                  inExposeAction: .selectTargetWindow,
                  postExitAction: .clickSameAppIcon,
                  reentryDepth: .single,
                  windowStates: standardWindows,
                  requiresMultipleValues: bothPreferenceModes),
            .init(family: "ESCAPE_EXIT_THEN_OTHER_ICON",
                  focusState: .otherAppFrontmost,
                  inExposeAction: .pressEscape,
                  postExitAction: .clickOtherAppIcon,
                  reentryDepth: .single,
                  windowStates: standardWindows,
                  requiresMultipleValues: bothPreferenceModes),
            .init(family: "ESCAPE_EXIT_THEN_SAME_ICON",
                  focusState: .otherAppFrontmost,
                  inExposeAction: .pressEscape,
                  postExitAction: .clickSameAppIcon,
                  reentryDepth: .single,
                  windowStates: standardWindows,
                  requiresMultipleValues: bothPreferenceModes),
            .init(family: "SAME_ICON_TOGGLE_LOOP",
                  focusState: .otherAppFrontmost,
                  inExposeAction: .clickSameAppDockIcon,
                  postExitAction: .clickSameAppIcon,
                  reentryDepth: .doubleImmediate,
                  windowStates: standardWindows,
                  requiresMultipleValues: bothPreferenceModes),
            .init(family: "OTHER_ICON_SWITCH_DURING_EXPOSE",
                  focusState: .otherAppFrontmost,
                  inExposeAction: .clickOtherAppDockIcon,
                  postExitAction: .clickOtherAppIcon,
                  reentryDepth: .single,
                  windowStates: standardWindows,
                  requiresMultipleValues: bothPreferenceModes),
            .init(family: "CMDTAB_SWITCH_DURING_EXPOSE",
                  focusState: .otherAppFrontmost,
                  inExposeAction: .cmdTabOtherApp,
                  postExitAction: .clickOtherAppIcon,
                  reentryDepth: .single,
                  windowStates: standardWindows,
                  requiresMultipleValues: bothPreferenceModes),
            .init(family: "REENTRY_AFTER_SWITCH",
                  focusState: .otherAppFrontmost,
                  inExposeAction: .selectTargetWindow,
                  postExitAction: .reenterAppExposeAfterSwitch,
                  reentryDepth: .doubleImmediate,
                  windowStates: standardWindows,
                  requiresMultipleValues: bothPreferenceModes),
            .init(family: "REENTRY_WITH_REQUIRES_MULTI_ON_AND_ONE_WINDOW",
                  focusState: .otherAppFrontmost,
                  inExposeAction: .selectTargetWindow,
                  postExitAction: .reenterAppExposeSameApp,
                  reentryDepth: .single,
                  windowStates: [.oneWindow],
                  requiresMultipleValues: [true]),
            .init(family: "REENTRY_WITH_REQUIRES_MULTI_OFF_AND_ONE_WINDOW",
                  focusState: .otherAppFrontmost,
                  inExposeAction: .selectTargetWindow,
                  postExitAction: .reenterAppExposeSameApp,
                  reentryDepth: .single,
                  windowStates: [.oneWindow],
                  requiresMultipleValues: [false]),
        ]
    }

    private func appExposeScenarioFamily(for scenario: AppExposeScenario) -> String {
        if scenario.inExposeAction == .clickNegativeSpace, scenario.postExitAction == .clickSameAppIcon {
            return "NEGSPACE_CANCEL_THEN_SAME_ICON"
        }
        if scenario.inExposeAction == .clickNegativeSpace, scenario.postExitAction == .clickOtherAppIcon {
            return "NEGSPACE_CANCEL_THEN_OTHER_ICON"
        }
        if scenario.inExposeAction == .selectTargetWindow, scenario.postExitAction == .clickOtherAppIcon {
            return "SELECT_WINDOW_THEN_OTHER_ICON"
        }
        if scenario.inExposeAction == .selectTargetWindow, scenario.postExitAction == .clickSameAppIcon {
            return "SELECT_WINDOW_THEN_SAME_ICON"
        }
        if scenario.inExposeAction == .pressEscape, scenario.postExitAction == .clickOtherAppIcon {
            return "ESCAPE_EXIT_THEN_OTHER_ICON"
        }
        if scenario.inExposeAction == .pressEscape, scenario.postExitAction == .clickSameAppIcon {
            return "ESCAPE_EXIT_THEN_SAME_ICON"
        }
        if scenario.inExposeAction == .clickSameAppDockIcon {
            return "SAME_ICON_TOGGLE_LOOP"
        }
        if scenario.inExposeAction == .clickOtherAppDockIcon {
            return "OTHER_ICON_SWITCH_DURING_EXPOSE"
        }
        if scenario.inExposeAction == .cmdTabOtherApp {
            return "CMDTAB_SWITCH_DURING_EXPOSE"
        }
        if scenario.requiresMultipleWindows && scenario.windowState == .oneWindow
            && (scenario.postExitAction == .reenterAppExposeAfterSwitch || scenario.postExitAction == .reenterAppExposeSameApp) {
            return "REENTRY_WITH_REQUIRES_MULTI_ON_AND_ONE_WINDOW"
        }
        if !scenario.requiresMultipleWindows && scenario.windowState == .oneWindow
            && (scenario.postExitAction == .reenterAppExposeAfterSwitch || scenario.postExitAction == .reenterAppExposeSameApp) {
            return "REENTRY_WITH_REQUIRES_MULTI_OFF_AND_ONE_WINDOW"
        }
        if scenario.postExitAction == .reenterAppExposeAfterSwitch {
            return "REENTRY_AFTER_SWITCH"
        }
        return "GENERAL"
    }

    private func requiredScenarioFamilies() -> [String] {
        [
            "NEGSPACE_CANCEL_THEN_SAME_ICON",
            "NEGSPACE_CANCEL_THEN_OTHER_ICON",
            "SELECT_WINDOW_THEN_OTHER_ICON",
            "SELECT_WINDOW_THEN_SAME_ICON",
            "ESCAPE_EXIT_THEN_OTHER_ICON",
            "ESCAPE_EXIT_THEN_SAME_ICON",
            "SAME_ICON_TOGGLE_LOOP",
            "OTHER_ICON_SWITCH_DURING_EXPOSE",
            "CMDTAB_SWITCH_DURING_EXPOSE",
            "REENTRY_AFTER_SWITCH",
            "REENTRY_WITH_REQUIRES_MULTI_ON_AND_ONE_WINDOW",
            "REENTRY_WITH_REQUIRES_MULTI_OFF_AND_ONE_WINDOW",
            "BOOTSTRAP_TRIGGER_GATE_OFF",
            "BOOTSTRAP_TRIGGER_GATE_ON",
            "FOCUSED_GATE_SUPPRESS",
            "FOCUSED_GATE_ALLOW_MULTI",
            "FOCUSED_GATE_ALLOW_SINGLE",
            "FOCUSED_NEGSPACE_SAME_MULTI",
            "FOCUSED_NEGSPACE_OTHER_MULTI",
            "FOCUSED_NEGSPACE_SAME_SINGLE",
            "FOCUSED_NEGSPACE_OTHER_SINGLE"
        ]
    }

    private func scenarioTuple(_ scenario: AppExposeScenario) -> String {
        "P=\(scenario.requiresMultipleWindows ? 1 : 0),W=\(scenario.windowState.rawValue),F=\(scenario.focusState.rawValue),E=\(scenario.inExposeAction.rawValue),A=\(scenario.postExitAction.rawValue),R=\(scenario.reentryDepth.rawValue)"
    }

    private func resolveAppExposeCartesianProfile(from env: [String: String]) -> AppExposeCartesianProfile {
        if env["DOCKACTIONER_APPEXPOSE_CARTESIAN_FULL"] == "1" {
            return .full
        }
        let raw = env["DOCKACTIONER_APPEXPOSE_CARTESIAN_PROFILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if raw == "bootstrap" {
            return .bootstrap
        }
        if raw == "focused" {
            return .focused
        }
        if raw == "full" {
            return .full
        }
        if raw == "compact" {
            return .compact
        }
        return .compact
    }

    private func resolveAppExposeCartesianTargets(from env: [String: String],
                                                  profile: AppExposeCartesianProfile) -> [String] {
        let defaults: [String]
        switch profile {
        case .bootstrap:
            defaults = [
                "com.apple.finder",
                "com.apple.TextEdit"
            ]
        case .focused:
            defaults = [
                "com.apple.finder",
                "com.apple.TextEdit"
            ]
        case .compact:
            defaults = [
                "com.apple.finder",
                "com.microsoft.VSCode"
            ]
        case .full:
            defaults = [
                "com.apple.finder",
                "com.apple.TextEdit",
                "com.apple.Safari",
                "com.apple.Terminal",
                "com.microsoft.VSCode",
                "com.apple.dt.Xcode"
            ]
        }

        guard let raw = env["DOCKACTIONER_APPEXPOSE_CARTESIAN_TARGETS"], !raw.isEmpty else {
            return defaults
        }

        let parsed = raw
            .split { $0 == "," || $0 == ";" || $0 == " " || $0 == "\n" || $0 == "\t" }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        let unique = parsed.filter { seen.insert($0).inserted }
        return unique.isEmpty ? defaults : unique
    }

    private func createAppExposeCartesianArtifacts() -> AppExposeCartesianArtifacts? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tools/artifacts/app_expose-cartesian-\(stamp)")

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let scenarios = root.appendingPathComponent("scenarios.jsonl")
            let failures = root.appendingPathComponent("failures.jsonl")
            let timeline = root.appendingPathComponent("timeline.log")
            let summary = root.appendingPathComponent("summary.json")
            let repro = root.appendingPathComponent("repro.md")

            FileManager.default.createFile(atPath: scenarios.path, contents: nil)
            FileManager.default.createFile(atPath: failures.path, contents: nil)
            FileManager.default.createFile(atPath: timeline.path, contents: nil)

            return AppExposeCartesianArtifacts(rootDirectory: root,
                                               scenariosJSONL: scenarios,
                                               failuresJSONL: failures,
                                               timelineLog: timeline,
                                               summaryJSON: summary,
                                               reproMarkdown: repro)
        } catch {
            Logger.log("Failed to create cartesian artifacts: \(error.localizedDescription)")
            return nil
        }
    }

    private func appendLine(_ line: String, to url: URL) {
        let data = (line + "\n").data(using: .utf8) ?? Data()
        if let handle = try? FileHandle(forWritingTo: url) {
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
                return
            } catch {
                try? handle.close()
            }
        }

        if FileManager.default.fileExists(atPath: url.path),
           let existing = try? Data(contentsOf: url) {
            var merged = existing
            merged.append(data)
            try? merged.write(to: url, options: .atomic)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func jsonLine<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    private func writeJSONObject<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func writeAppExposeReproMarkdown(histories: [ScenarioHistory],
                                             artifacts: AppExposeCartesianArtifacts,
                                             rerunIterations: Int) {
        var lines: [String] = []
        lines.append("# App Expose Cartesian Repro Report")
        lines.append("")
        lines.append("- Generated: \(iso8601String(Date()))")
        lines.append("- Artifact directory: \(artifacts.rootDirectory.path)")
        lines.append("- Isolated reruns per failed scenario: \(rerunIterations)")
        lines.append("")
        lines.append("## Top deterministic repros")
        lines.append("")

        if histories.isEmpty {
            lines.append("No deterministic failures identified.")
        } else {
            for (index, history) in histories.prefix(20).enumerated() {
                lines.append("\(index + 1). `\(history.scenario.id)`")
                lines.append("   - Tuple: `\(scenarioTuple(history.scenario))`")
                lines.append("   - Family: `\(history.scenario.family)`")
                lines.append("   - Failures: \(history.failures)/\(history.runs)")
                let sample = history.failureSamples.first ?? "no detail"
                lines.append("   - Sample failure: \(sample)")
                lines.append("   - Repro command: `DOCKACTIONER_APPEXPOSE_CARTESIAN_TEST=1 DOCKACTIONER_APPEXPOSE_CARTESIAN_SCENARIO_ID=\"\(history.scenario.id)\" \".build/Build/Products/Debug/DockActioner.app/Contents/MacOS/DockActioner\"`")
                lines.append("")
            }
        }

        let text = lines.joined(separator: "\n")
        try? text.data(using: .utf8)?.write(to: artifacts.reproMarkdown, options: .atomic)
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func percentile95(values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * 0.95).rounded())
        return sorted[max(0, min(index, sorted.count - 1))]
    }

    private func isExposeTrackingActive() -> Bool {
        appExposeInvocationToken != nil || lastTriggeredBundle != nil || currentExposeApp != nil
    }

    private func expectedTrackingStateAfterInExposeAction(_ action: ScenarioInExposeAction) -> Bool {
        switch action {
        case .clickOtherAppDockIcon, .noInputTimeout3s:
            return true
        case .selectTargetWindow, .clickNegativeSpace, .pressEscape, .clickSameAppDockIcon, .cmdTabOtherApp:
            return false
        }
    }

    private func prepareScenarioWindowState(_ state: ScenarioWindowState,
                                            targetBundle: String) async -> ScenarioWindowPreparation {
        await ensureAppRunningForFirstClickTest(bundleIdentifier: targetBundle)
        _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: targetBundle)
        try? await Task.sleep(nanoseconds: 180_000_000)

        switch state {
        case .zeroWindows:
            await closeFrontWindows(for: targetBundle, maxAttempts: 6)
            try? await Task.sleep(nanoseconds: 100_000_000)
        case .oneWindow:
            await ensureAtLeastWindows(for: targetBundle, count: 1)
            await closeExtraWindows(for: targetBundle, keep: 1, maxAttempts: 6)
        case .twoPlusWindows:
            await ensureAtLeastWindows(for: targetBundle, count: 2)
        case .twoPlusHiddenWindows:
            await ensureAtLeastWindows(for: targetBundle, count: 2)
            _ = WindowManager.hideAllWindows(bundleIdentifier: targetBundle)
        case .twoPlusMinimizedWindows:
            await ensureAtLeastWindows(for: targetBundle, count: 2)
            _ = WindowManager.minimizeAllWindows(bundleIdentifier: targetBundle)
        }

        try? await Task.sleep(nanoseconds: 150_000_000)

        let total = WindowManager.totalWindowCount(bundleIdentifier: targetBundle)
        let hidden = WindowManager.isAppHidden(bundleIdentifier: targetBundle)
        let minimizedCount = minimizedWindowCount(bundleIdentifier: targetBundle)
        let allMinimized = total > 0 && minimizedCount == total

        let achieved: Bool
        switch state {
        case .zeroWindows:
            achieved = total == 0
        case .oneWindow:
            achieved = total == 1
        case .twoPlusWindows:
            achieved = total >= 2
        case .twoPlusHiddenWindows:
            achieved = total >= 2 && hidden
        case .twoPlusMinimizedWindows:
            achieved = total >= 2 && allMinimized
        }

        let detail = "requested=\(state.rawValue) total=\(total) hidden=\(hidden) minimized=\(minimizedCount) achieved=\(achieved)"
        return ScenarioWindowPreparation(requested: state,
                                         observedTotalWindows: total,
                                         observedHidden: hidden,
                                         observedAllMinimized: allMinimized,
                                         achieved: achieved,
                                         detail: detail)
    }

    private func minimizedWindowCount(bundleIdentifier: String) -> Int {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return 0
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windows) == .success,
              let windowsArray = windows as? [AXUIElement] else {
            return 0
        }

        var minimized = 0
        for window in windowsArray {
            var minimizedValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
               let isMinimized = minimizedValue as? Bool,
               isMinimized {
                minimized += 1
            }
        }
        return minimized
    }

    private func closeFrontWindows(for bundleIdentifier: String, maxAttempts: Int) async {
        _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: bundleIdentifier)
        try? await Task.sleep(nanoseconds: 120_000_000)
        for _ in 0..<maxAttempts {
            if WindowManager.totalWindowCount(bundleIdentifier: bundleIdentifier) == 0 {
                return
            }
            postKeyboardShortcut(keyCode: 13, flags: [.maskCommand]) // Cmd+W
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    private func closeExtraWindows(for bundleIdentifier: String, keep: Int, maxAttempts: Int) async {
        _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: bundleIdentifier)
        try? await Task.sleep(nanoseconds: 120_000_000)
        for _ in 0..<maxAttempts {
            let total = WindowManager.totalWindowCount(bundleIdentifier: bundleIdentifier)
            if total <= keep {
                return
            }
            postKeyboardShortcut(keyCode: 13, flags: [.maskCommand]) // Cmd+W
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    private func ensureAtLeastWindows(for bundleIdentifier: String, count: Int) async {
        _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: bundleIdentifier)
        try? await Task.sleep(nanoseconds: 120_000_000)
        let needsTextEditWindowShortcut = bundleIdentifier == "com.apple.TextEdit" && count > 1
        var previousTotal = WindowManager.totalWindowCount(bundleIdentifier: bundleIdentifier)
        var stagnantAttempts = 0
        if previousTotal >= count {
            return
        }

        for _ in 0..<8 {
            if needsTextEditWindowShortcut {
                postKeyboardShortcut(keyCode: 45, flags: [.maskCommand, .maskAlternate]) // Cmd+Option+N
            } else {
                postKeyboardShortcut(keyCode: 45, flags: [.maskCommand]) // Cmd+N
            }
            try? await Task.sleep(nanoseconds: 170_000_000)

            let total = WindowManager.totalWindowCount(bundleIdentifier: bundleIdentifier)
            if total >= count {
                return
            }

            if total <= previousTotal {
                stagnantAttempts += 1
            } else {
                stagnantAttempts = 0
            }
            previousTotal = max(previousTotal, total)

            // Prevent keyboard-alert spam when app/window mode cannot satisfy requested count.
            if stagnantAttempts >= 3 {
                return
            }
        }
    }

    private func postKeyboardShortcut(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = flags
        keyUp?.flags = flags
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func postCommandTabSwitch() {
        postKeyboardShortcut(keyCode: 48, flags: [.maskCommand]) // Cmd+Tab
    }

    private func mainDisplayNegativeSpacePoint() -> CGPoint {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private func resolveAlternateBundle(for targetBundle: String, targetPool: [String]) async -> String? {
        for bundle in targetPool where bundle != targetBundle {
            await ensureAppRunningForFirstClickTest(bundleIdentifier: bundle)
            if resolveCartesianDockIconPoint(bundleIdentifier: bundle) != nil {
                return bundle
            }
        }

        let selfBundle = Bundle.main.bundleIdentifier
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.activationPolicy == .regular
                && $0.bundleIdentifier != targetBundle
                && $0.bundleIdentifier != selfBundle
        }),
           let bundle = app.bundleIdentifier {
            await ensureAppRunningForFirstClickTest(bundleIdentifier: bundle)
            if resolveCartesianDockIconPoint(bundleIdentifier: bundle) != nil {
                return bundle
            }
        }

        return nil
    }

    private func resolveCartesianDockIconPoint(bundleIdentifier: String) -> CGPoint? {
        if let cached = cartesianDockPointCache[bundleIdentifier] {
            if bundleIdentifierNearPoint(cached) == bundleIdentifier {
                return cached
            }
            if let refreshed = firstClickAppExposeLiveDockPoint(for: bundleIdentifier, around: cached) {
                cartesianDockPointCache[bundleIdentifier] = refreshed
                return refreshed
            }
            cartesianDockPointCache.removeValue(forKey: bundleIdentifier)
        }

        // Keep cartesian runs moving even if Dock hit-testing is degraded.
        guard let discovered = findDockIconPoint(bundleIdentifier: bundleIdentifier, maxDuration: 4.0) else {
            return nil
        }
        cartesianDockPointCache[bundleIdentifier] = discovered
        return discovered
    }

    private func resolveCartesianClickPoint(bundleIdentifier: String,
                                            requestedPoint: CGPoint) -> CGPoint? {
        if bundleIdentifierNearPoint(requestedPoint) == bundleIdentifier {
            cartesianDockPointCache[bundleIdentifier] = requestedPoint
            return requestedPoint
        }

        if let cached = cartesianDockPointCache[bundleIdentifier] {
            if bundleIdentifierNearPoint(cached) == bundleIdentifier {
                return cached
            }
            if let refreshedFromCache = firstClickAppExposeLiveDockPoint(for: bundleIdentifier, around: cached) {
                cartesianDockPointCache[bundleIdentifier] = refreshedFromCache
                return refreshedFromCache
            }
        }

        if let refreshedFromRequested = firstClickAppExposeLiveDockPoint(for: bundleIdentifier, around: requestedPoint) {
            cartesianDockPointCache[bundleIdentifier] = refreshedFromRequested
            return refreshedFromRequested
        }

        if let discovered = findDockIconPoint(bundleIdentifier: bundleIdentifier, maxDuration: 1.5) {
            cartesianDockPointCache[bundleIdentifier] = discovered
            return discovered
        }

        return nil
    }

    private func robustDockClickPoint(bundleIdentifier: String, around seed: CGPoint) -> CGPoint? {
        let deltas: [CGFloat] = [-16, -12, -8, -4, 0, 4, 8, 12, 16]
        var bestPoint: CGPoint?
        var bestScore = -1

        for dy in deltas {
            for dx in deltas {
                let candidate = CGPoint(x: seed.x + dx, y: seed.y + dy)
                if bundleIdentifierNearPoint(candidate) != bundleIdentifier {
                    continue
                }

                let score = dockBundleMatchScore(bundleIdentifier: bundleIdentifier, at: candidate)
                if score > bestScore {
                    bestScore = score
                    bestPoint = candidate
                }
            }
        }

        return bestPoint
    }

    private func dockBundleMatchScore(bundleIdentifier: String, at point: CGPoint) -> Int {
        let sample: [CGFloat] = [-6, 0, 6]
        var score = 0
        for dy in sample {
            for dx in sample {
                let samplePoint = CGPoint(x: point.x + dx, y: point.y + dy)
                if DockHitTest.bundleIdentifierAtPoint(samplePoint) == bundleIdentifier {
                    score += 1
                }
            }
        }
        return score
    }

    private func primeScenarioFocusState(_ state: ScenarioFocusState,
                                         targetBundle: String,
                                         alternateBundle: String?) async {
        switch state {
        case .targetFrontmost:
            _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: targetBundle)
        case .otherAppFrontmost:
            if let alternateBundle {
                _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: alternateBundle)
            } else {
                makeNonTargetAppFrontmost(targetBundle: targetBundle)
            }
        case .targetHidden:
            _ = WindowManager.hideAllWindows(bundleIdentifier: targetBundle)
            if let alternateBundle {
                _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: alternateBundle)
            } else {
                makeNonTargetAppFrontmost(targetBundle: targetBundle)
            }
        }
        try? await Task.sleep(nanoseconds: 160_000_000)
    }

    private func performScenarioInExposeAction(_ action: ScenarioInExposeAction,
                                               targetBundle: String,
                                               targetPoint: CGPoint,
                                               alternateBundle: String?,
                                               alternatePoint: CGPoint?) async -> ScenarioActionOutcome {
        switch action {
        case .selectTargetWindow:
            _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: targetBundle)
            try? await Task.sleep(nanoseconds: 220_000_000)
            return ScenarioActionOutcome(ok: true, detail: "selected target window")
        case .clickNegativeSpace:
            let point = mainDisplayNegativeSpacePoint()
            postSyntheticMouseMove(to: point)
            try? await Task.sleep(nanoseconds: 80_000_000)
            postSyntheticClick(at: point)
            try? await Task.sleep(nanoseconds: 220_000_000)
            return ScenarioActionOutcome(ok: true, detail: "clicked negative space at (\(Int(point.x)),\(Int(point.y)))")
        case .pressEscape:
            exitAppExpose()
            try? await Task.sleep(nanoseconds: 180_000_000)
            return ScenarioActionOutcome(ok: true, detail: "pressed escape")
        case .clickSameAppDockIcon:
            let click = await performCartesianDockClick(bundleIdentifier: targetBundle, at: targetPoint)
            try? await Task.sleep(nanoseconds: 180_000_000)
            return ScenarioActionOutcome(ok: click.sent, detail: "clicked same app dock icon \(click.summary)")
        case .clickOtherAppDockIcon:
            guard let alternatePoint, let alternateBundle else {
                return ScenarioActionOutcome(ok: false, detail: "alternate dock icon unavailable")
            }
            let click = await performCartesianDockClick(bundleIdentifier: alternateBundle, at: alternatePoint)
            try? await Task.sleep(nanoseconds: 180_000_000)
            return ScenarioActionOutcome(ok: click.sent, detail: "clicked other app dock icon (\(alternateBundle)) \(click.summary)")
        case .cmdTabOtherApp:
            postCommandTabSwitch()
            try? await Task.sleep(nanoseconds: 240_000_000)
            return ScenarioActionOutcome(ok: true, detail: "issued cmd+tab")
        case .noInputTimeout3s:
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return ScenarioActionOutcome(ok: true, detail: "waited 3s without input")
        }
    }

    private func performScenarioPostExitAction(action: ScenarioPostExitAction,
                                               depth: ScenarioReentryDepth,
                                               targetBundle: String,
                                               targetPoint: CGPoint,
                                               alternateBundle: String?,
                                               alternatePoint: CGPoint?) async -> ScenarioActionOutcome {
        let sequence = postExitActionSequence(base: action, depth: depth)
        var details: [String] = []

        for stepAction in sequence {
            let result = await performSingleScenarioPostExitAction(stepAction,
                                                                   targetBundle: targetBundle,
                                                                   targetPoint: targetPoint,
                                                                   alternateBundle: alternateBundle,
                                                                   alternatePoint: alternatePoint)
            details.append(result.detail)
            if !result.ok {
                return ScenarioActionOutcome(ok: false, detail: details.joined(separator: "; "))
            }
        }

        return ScenarioActionOutcome(ok: true, detail: details.joined(separator: "; "))
    }

    private func postExitActionSequence(base: ScenarioPostExitAction,
                                        depth: ScenarioReentryDepth) -> [ScenarioPostExitAction] {
        switch depth {
        case .single:
            return [base]
        case .doubleImmediate:
            return [base, base]
        case .tripleAlternating:
            return [base, alternatePostExitAction(for: base), base]
        }
    }

    private func alternatePostExitAction(for action: ScenarioPostExitAction) -> ScenarioPostExitAction {
        switch action {
        case .clickSameAppIcon:
            return .clickOtherAppIcon
        case .clickOtherAppIcon:
            return .clickSameAppIcon
        case .clickTargetWindow:
            return .clickOtherAppIcon
        case .reenterAppExposeSameApp:
            return .reenterAppExposeAfterSwitch
        case .reenterAppExposeAfterSwitch:
            return .reenterAppExposeSameApp
        }
    }

    private func performSingleScenarioPostExitAction(_ action: ScenarioPostExitAction,
                                                     targetBundle: String,
                                                     targetPoint: CGPoint,
                                                     alternateBundle: String?,
                                                     alternatePoint: CGPoint?) async -> ScenarioActionOutcome {
        switch action {
        case .clickSameAppIcon:
            let latency = await clickDockIconAndMeasureLatency(point: targetPoint,
                                                               expectedBundle: targetBundle)
            return ScenarioActionOutcome(ok: latency != nil,
                                         detail: latency.map { String(format: "click same app latency=%.1fms", $0) } ?? "click same app latency=nil")
        case .clickOtherAppIcon:
            guard let alternateBundle, let alternatePoint else {
                return ScenarioActionOutcome(ok: false, detail: "alternate dock icon unavailable")
            }
            let latency = await clickDockIconAndMeasureLatency(point: alternatePoint,
                                                               expectedBundle: alternateBundle)
            return ScenarioActionOutcome(ok: latency != nil,
                                         detail: latency.map { String(format: "click other app latency=%.1fms", $0) } ?? "click other app latency=nil")
        case .clickTargetWindow:
            let activated = WindowManager.activateAndShowMainWindow(bundleIdentifier: targetBundle)
            try? await Task.sleep(nanoseconds: 180_000_000)
            return ScenarioActionOutcome(ok: activated,
                                         detail: "activate target window \(activated)")
        case .reenterAppExposeSameApp:
            let ok = await attemptReentry(targetBundle: targetBundle,
                                          targetPoint: targetPoint,
                                          alternateBundle: alternateBundle,
                                          alternatePoint: alternatePoint,
                                          switchBeforeReenter: false)
            return ScenarioActionOutcome(ok: ok, detail: "reenter same app \(ok)")
        case .reenterAppExposeAfterSwitch:
            let ok = await attemptReentry(targetBundle: targetBundle,
                                          targetPoint: targetPoint,
                                          alternateBundle: alternateBundle,
                                          alternatePoint: alternatePoint,
                                          switchBeforeReenter: true)
            return ScenarioActionOutcome(ok: ok, detail: "reenter after switch \(ok)")
        }
    }

    private func attemptReentry(targetBundle: String,
                                targetPoint: CGPoint,
                                alternateBundle: String?,
                                alternatePoint: CGPoint?,
                                switchBeforeReenter: Bool) async -> Bool {
        if switchBeforeReenter {
            if let alternatePoint, let alternateBundle {
                let switched = await performCartesianDockClick(bundleIdentifier: alternateBundle, at: alternatePoint)
                if !switched.sent {
                    return false
                }
                try? await Task.sleep(nanoseconds: 160_000_000)
            } else {
                makeNonTargetAppFrontmost(targetBundle: targetBundle)
                try? await Task.sleep(nanoseconds: 140_000_000)
            }
        } else {
            if let alternateBundle {
                _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: alternateBundle)
            } else {
                makeNonTargetAppFrontmost(targetBundle: targetBundle)
            }
            try? await Task.sleep(nanoseconds: 140_000_000)
        }

        let baseline = lastActionExecutedAt ?? Date.distantPast
        let click = await performCartesianDockClick(bundleIdentifier: targetBundle, at: targetPoint)
        guard click.sent else {
            return false
        }
        let dispatched = await waitForAppExposeDispatch(expectedBundle: targetBundle,
                                                        baseline: baseline,
                                                        timeout: 1.3)
        if dispatched {
            exitAppExpose()
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return dispatched
    }

    private func waitForAppExposeDispatch(expectedBundle: String,
                                          baseline: Date,
                                          timeout: TimeInterval) async -> Bool {
        let started = Date()
        while Date().timeIntervalSince(started) < timeout {
            if let at = lastActionExecutedAt,
               at > baseline,
               lastActionExecuted == .appExpose,
               lastActionExecutedBundle == expectedBundle {
                return true
            }
            try? await Task.sleep(nanoseconds: 35_000_000)
        }
        return false
    }

    private func waitForAnyDispatch(expectedBundle: String?,
                                    baseline: Date,
                                    timeout: TimeInterval) async -> Bool {
        let started = Date()
        while Date().timeIntervalSince(started) < timeout {
            if let at = lastActionExecutedAt, at > baseline {
                if let expectedBundle {
                    if lastActionExecutedBundle == expectedBundle {
                        return true
                    }
                } else {
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: 35_000_000)
        }
        return false
    }

    private func waitForAppExposeTrigger(expectedBundle: String,
                                         baseline: Date,
                                         timeout: TimeInterval) async -> Bool {
        let started = Date()
        while Date().timeIntervalSince(started) < timeout {
            if let at = lastActionExecutedAt,
               at > baseline,
               lastActionExecuted == .appExpose,
               lastActionExecutedBundle == expectedBundle {
                return true
            }

            // Fallback state-based signal in case source classification differs from "firstClick".
            if lastTriggeredBundle == expectedBundle || currentExposeApp == expectedBundle {
                return true
            }

            try? await Task.sleep(nanoseconds: 35_000_000)
        }
        return false
    }

    private func cartesianDirectClickModeEnabled() -> Bool {
        let profileRaw = ProcessInfo.processInfo.environment["DOCKACTIONER_APPEXPOSE_CARTESIAN_PROFILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if profileRaw == AppExposeCartesianProfile.focused.rawValue {
            return false
        }

        let raw = ProcessInfo.processInfo.environment["DOCKACTIONER_APPEXPOSE_CARTESIAN_DIRECT_CLICKS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return raw == "1" || raw == "true" || raw == "yes"
    }

    private func performCartesianDockClick(bundleIdentifier: String, at point: CGPoint) async -> CartesianClickDispatchResult {
        var requestedPoint = point
        var clickPoint: CGPoint?
        for _ in 0..<3 {
            guard let resolved = resolveCartesianClickPoint(bundleIdentifier: bundleIdentifier,
                                                            requestedPoint: requestedPoint) else {
                try? await Task.sleep(nanoseconds: 80_000_000)
                continue
            }
            postSyntheticMouseMove(to: resolved)
            try? await Task.sleep(nanoseconds: 60_000_000)
            if let robust = robustDockClickPoint(bundleIdentifier: bundleIdentifier, around: resolved) {
                clickPoint = robust
                break
            }
            requestedPoint = resolved
            try? await Task.sleep(nanoseconds: 60_000_000)
        }

        guard let clickPoint else {
            Logger.debug("CARTESIAN: failed to validate Dock click point for \(bundleIdentifier)")
            return CartesianClickDispatchResult(sent: false,
                                                expectedBundle: bundleIdentifier,
                                                clickPoint: nil,
                                                observedDownBundle: nil,
                                                observedUpBundle: nil,
                                                observedDownMs: nil,
                                                observedUpMs: nil,
                                                mode: "real")
        }

        if cartesianDirectClickModeEnabled() {
            let frontmostBefore = FrontmostAppTracker.frontmostBundleIdentifier()
            let context = PendingClickContext(location: clickPoint,
                                              buttonNumber: 0,
                                              flags: [],
                                              frontmostBefore: frontmostBefore,
                                              clickedBundle: bundleIdentifier,
                                              consumeClick: false)
            let consumed = executeClickAction(context)
            if !consumed {
                _ = WindowManager.activateAndShowMainWindow(bundleIdentifier: bundleIdentifier)
                lastActionExecuted = .activateApp
                lastActionExecutedBundle = bundleIdentifier
                lastActionExecutedSource = "directDockFallback"
                lastActionExecutedAt = Date()
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
            return CartesianClickDispatchResult(sent: true,
                                                expectedBundle: bundleIdentifier,
                                                clickPoint: clickPoint,
                                                observedDownBundle: nil,
                                                observedUpBundle: nil,
                                                observedDownMs: nil,
                                                observedUpMs: nil,
                                                mode: "direct")
        }

        let token = beginCartesianClickProbe(expectedBundle: bundleIdentifier)
        postSyntheticClick(at: clickPoint)
        let started = Date()
        while Date().timeIntervalSince(started) < 0.45 {
            if let probe = cartesianClickProbe,
               probe.token == token,
               probe.observedUpAt != nil {
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        return finalizeCartesianClickProbe(token: token,
                                           expectedBundle: bundleIdentifier,
                                           clickPoint: clickPoint,
                                           sent: true,
                                           mode: "real")
    }

    private func beginCartesianClickProbe(expectedBundle: String) -> UUID {
        let token = UUID()
        cartesianClickProbe = CartesianClickProbe(token: token,
                                                  expectedBundle: expectedBundle,
                                                  startedAt: Date(),
                                                  observedDownBundle: nil,
                                                  observedDownAt: nil,
                                                  observedUpBundle: nil,
                                                  observedUpAt: nil)
        return token
    }

    private func observeCartesianClickProbe(phase: ClickPhase, bundleAtPoint: String?) {
        guard var probe = cartesianClickProbe else { return }
        switch phase {
        case .down:
            if probe.observedDownAt == nil {
                probe.observedDownAt = Date()
                probe.observedDownBundle = bundleAtPoint
            }
        case .up:
            if probe.observedUpAt == nil {
                probe.observedUpAt = Date()
                probe.observedUpBundle = bundleAtPoint
            }
        case .dragged:
            break
        }
        cartesianClickProbe = probe
    }

    private func finalizeCartesianClickProbe(token: UUID,
                                             expectedBundle: String,
                                             clickPoint: CGPoint?,
                                             sent: Bool,
                                             mode: String) -> CartesianClickDispatchResult {
        let probe: CartesianClickProbe?
        if let current = cartesianClickProbe, current.token == token {
            probe = current
            cartesianClickProbe = nil
        } else {
            probe = nil
        }

        let downMs = probe.flatMap { probe -> Double? in
            guard let downAt = probe.observedDownAt else { return nil }
            return downAt.timeIntervalSince(probe.startedAt) * 1000.0
        }
        let upMs = probe.flatMap { probe -> Double? in
            guard let upAt = probe.observedUpAt else { return nil }
            return upAt.timeIntervalSince(probe.startedAt) * 1000.0
        }

        return CartesianClickDispatchResult(sent: sent,
                                            expectedBundle: expectedBundle,
                                            clickPoint: clickPoint,
                                            observedDownBundle: probe?.observedDownBundle,
                                            observedUpBundle: probe?.observedUpBundle,
                                            observedDownMs: downMs,
                                            observedUpMs: upMs,
                                            mode: mode)
    }

    private func clickDockIconAndMeasureLatency(point: CGPoint,
                                                expectedBundle: String) async -> Double? {
        let baseline = Date()
        let click = await performCartesianDockClick(bundleIdentifier: expectedBundle, at: point)
        guard click.sent else {
            return nil
        }
        let dispatched = await waitForAnyDispatch(expectedBundle: expectedBundle,
                                                  baseline: baseline,
                                                  timeout: 2.0)
        guard dispatched, let at = lastActionExecutedAt else {
            return nil
        }
        return at.timeIntervalSince(baseline) * 1000.0
    }

    private func validateScenarioReentry(depth: ScenarioReentryDepth,
                                         targetBundle: String,
                                         targetPoint: CGPoint,
                                         alternateBundle: String?,
                                         alternatePoint: CGPoint?) async -> Bool {
        let attempts: Int
        switch depth {
        case .single:
            attempts = 1
        case .doubleImmediate:
            attempts = 2
        case .tripleAlternating:
            attempts = 3
        }

        for index in 0..<attempts {
            let switched = depth == .tripleAlternating ? (index % 2 == 0) : true
            let ok = await attemptReentry(targetBundle: targetBundle,
                                          targetPoint: targetPoint,
                                          alternateBundle: alternateBundle,
                                          alternatePoint: alternatePoint,
                                          switchBeforeReenter: switched)
            if !ok {
                return false
            }
        }
        return true
    }

    private func probeScenarioDockResponsiveness(targetBundle: String,
                                                 targetPoint: CGPoint,
                                                 alternateBundle: String?,
                                                 alternatePoint: CGPoint?) async -> Double? {
        if let alternateBundle, let alternatePoint {
            if let latency = await clickDockIconAndMeasureLatency(point: alternatePoint,
                                                                  expectedBundle: alternateBundle) {
                return latency
            }
        }
        return await clickDockIconAndMeasureLatency(point: targetPoint, expectedBundle: targetBundle)
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

        if targetBundle != "com.apple.finder",
           let finder = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.finder" }) {
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

    func findDockIconPoint(bundleIdentifier: String, maxDuration: TimeInterval? = nil) -> CGPoint? {
        var count: UInt32 = 0
        if CGGetActiveDisplayList(0, nil, &count) != .success || count == 0 {
            return nil
        }
        var displays = Array(repeating: CGDirectDisplayID(0), count: Int(count))
        if CGGetActiveDisplayList(count, &displays, &count) != .success {
            return nil
        }
        let deadline = maxDuration.map { Date().addingTimeInterval($0) }

        for id in displays {
            if let deadline, Date() > deadline { break }
            let b = CGDisplayBounds(id)

            // If the Dock is set to auto-hide, it may not be hittable unless the cursor is near the edge.
            postSyntheticMouseMove(to: CGPoint(x: b.midX, y: b.maxY - 1))
            postSyntheticMouseMove(to: CGPoint(x: b.minX + 1, y: b.midY))
            postSyntheticMouseMove(to: CGPoint(x: b.maxX - 1, y: b.midY))
            usleep(60_000)

            if let p = probeEdgeForBundle(bounds: b, edge: .bottom, bundleIdentifier: bundleIdentifier, deadline: deadline) { return p }
            if let p = probeEdgeForBundle(bounds: b, edge: .left, bundleIdentifier: bundleIdentifier, deadline: deadline) { return p }
            if let p = probeEdgeForBundle(bounds: b, edge: .right, bundleIdentifier: bundleIdentifier, deadline: deadline) { return p }
        }
        return nil
    }

    func postSyntheticMouseMove(to point: CGPoint) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        if let ev = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            ev.flags = []
            ev.setIntegerValueField(.eventSourceUserData, value: DockClickEventTap.syntheticClickUserData)
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

    func postSyntheticMouseUpPassthrough(at point: CGPoint) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        guard let up = CGEvent(mouseEventSource: source,
                               mouseType: .leftMouseUp,
                               mouseCursorPosition: point,
                               mouseButton: .left) else { return }
        up.flags = []
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
            let hitBundle = DockHitTest.bundleIdentifierAtPoint(location)
            observeCartesianClickProbe(phase: .down, bundleAtPoint: hitBundle)
            guard let clickedBundle = hitBundle else {
                if lastTriggeredBundle != nil || currentExposeApp != nil {
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
            if cartesianClickProbe != nil {
                let hitBundle = DockHitTest.bundleIdentifierAtPoint(location)
                observeCartesianClickProbe(phase: .up, bundleAtPoint: hitBundle)
            }
            guard let context = pendingClickContext else {
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

            let consumeNow = executeClickAction(context)
            if consumeNow != context.consumeClick {
                Logger.debug("WORKFLOW: Click consume mismatch planned=\(context.consumeClick) actual=\(consumeNow)")
            }
            if context.consumeClick && shouldRunDockPressedStateRecovery() {
                scheduleDockPressedStateRecovery(at: context.location, expectedBundle: context.clickedBundle)
            }
            return context.consumeClick
        }
    }

    private func shouldRunDockPressedStateRecovery() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env["DOCKACTIONER_APPEXPOSE_CARTESIAN_TEST"] == "1" {
            return true
        }
        if env["DOCKACTIONER_DOCK_RELEASE_RECOVERY"] == "1" {
            return true
        }
        return false
    }

    private func scheduleDockPressedStateRecovery(at location: CGPoint, expectedBundle: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) { [weak self] in
            guard let self else { return }
            postSyntheticMouseMove(to: location)
            postSyntheticMouseUpPassthrough(at: location)
            Logger.debug("WORKFLOW: Posted passthrough mouse-up recovery for \(expectedBundle)")
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
