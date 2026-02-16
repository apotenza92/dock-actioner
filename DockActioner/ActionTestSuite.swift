import AppKit

@MainActor
final class ActionTestSuite {
    enum Trigger: String, CaseIterable {
        case click
        case scrollUp
        case scrollDown
    }

    struct CaseResult {
        let action: DockAction
        let trigger: Trigger
        let passed: Bool
        let detail: String
    }

    private unowned let coordinator: DockExposeCoordinator

    init(coordinator: DockExposeCoordinator) {
        self.coordinator = coordinator
    }

    func runAll(targetBundleIdentifier: String) async -> [CaseResult] {
        var results: [CaseResult] = []

        let savedClick = Preferences.shared.clickAction
        let savedUp = Preferences.shared.scrollUpAction
        let savedDown = Preferences.shared.scrollDownAction
        defer {
            Preferences.shared.clickAction = savedClick
            Preferences.shared.scrollUpAction = savedUp
            Preferences.shared.scrollDownAction = savedDown
        }

        guard AXIsProcessTrusted() else {
            return DockAction.allCases.flatMap { action in
                Trigger.allCases.map { trig in
                    CaseResult(action: action, trigger: trig, passed: false, detail: "Accessibility not granted")
                }
            }
        }
        guard CGPreflightListenEventAccess() else {
            return DockAction.allCases.flatMap { action in
                Trigger.allCases.map { trig in
                    CaseResult(action: action, trigger: trig, passed: false, detail: "Input Monitoring not granted")
                }
            }
        }

        if !coordinator.isRunning {
            coordinator.startIfPossible()
        }
        guard coordinator.isRunning else {
            return DockAction.allCases.flatMap { action in
                Trigger.allCases.map { trig in
                    CaseResult(action: action, trigger: trig, passed: false, detail: "Event tap not running")
                }
            }
        }

        // Ensure we have at least two regular apps so hideOthers can be validated.
        await ensureHelperAppRunning()

        // Pick a target that we can actually locate in the Dock.
        guard let target = await selectTargetBundleIdentifier(preferred: targetBundleIdentifier) else {
            return DockAction.allCases.flatMap { action in
                Trigger.allCases.map { trig in
                    CaseResult(action: action, trigger: trig, passed: false, detail: "Couldn't find any testable Dock icon target")
                }
            }
        }

        // Run non-destructive-ish actions first; quit last.
        let actions = DockAction.allCases.filter { $0 != .quitApp } + [.quitApp]

        for action in actions {
            for trigger in Trigger.allCases {
                let r = await runSingle(action: action, trigger: trigger, targetBundleIdentifier: target)
                results.append(r)

                // If we quit the target, relaunch so later triggers still have a Dock icon.
                if action == .quitApp {
                    await launchTarget(bundleIdentifier: target)
                }
            }
        }

        return results
    }

    private func runSingle(action: DockAction, trigger: Trigger, targetBundleIdentifier: String) async -> CaseResult {
        await resetTargetState(targetBundleIdentifier: targetBundleIdentifier)

        // Give Dock a moment to reflect state changes (especially after quitting/relaunching).
        try? await Task.sleep(nanoseconds: 250_000_000)

        guard let initialPoint = coordinator.findDockIconPoint(bundleIdentifier: targetBundleIdentifier) else {
            return CaseResult(action: action, trigger: trigger, passed: false, detail: "Couldn't locate Dock icon for \(targetBundleIdentifier)")
        }

        let targetPoint = liveDockPoint(for: targetBundleIdentifier, around: initialPoint) ?? initialPoint

        let baseline = coordinator.lastActionExecutedAt ?? Date.distantPast

        switch trigger {
        case .click:
            Preferences.shared.clickAction = action
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == targetBundleIdentifier }) {
                _ = app.activate(options: [.activateIgnoringOtherApps])
            }
        case .scrollUp:
            Preferences.shared.scrollUpAction = action
        case .scrollDown:
            Preferences.shared.scrollDownAction = action
        }

        let points = candidatePoints(seed: targetPoint, bundleIdentifier: targetBundleIdentifier)
        var okDispatch = false
        for point in points {
            coordinator.postSyntheticMouseMove(to: point)
            try? await Task.sleep(nanoseconds: 90_000_000)

            switch trigger {
            case .click:
                coordinator.postSyntheticClick(at: point)
            case .scrollUp:
                coordinator.postSyntheticScroll(at: point, deltaY: -6)
            case .scrollDown:
                coordinator.postSyntheticScroll(at: point, deltaY: 6)
            }

            okDispatch = await waitForDispatch(
                expectedAction: action,
                expectedBundle: targetBundleIdentifier,
                expectedSource: trigger.rawValue,
                baseline: baseline,
                timeout: 0.65
            )
            if okDispatch { break }
        }

        // Allow effects (hide/minimize/quit) time to apply.
        try? await Task.sleep(nanoseconds: 280_000_000)

        if !okDispatch {
            // One final attempt with a freshly scanned Dock point.
            if let refreshed = coordinator.findDockIconPoint(bundleIdentifier: targetBundleIdentifier) {
                coordinator.postSyntheticMouseMove(to: refreshed)
                try? await Task.sleep(nanoseconds: 80_000_000)
                switch trigger {
                case .click:
                    coordinator.postSyntheticClick(at: refreshed)
                case .scrollUp:
                    coordinator.postSyntheticScroll(at: refreshed, deltaY: -6)
                case .scrollDown:
                    coordinator.postSyntheticScroll(at: refreshed, deltaY: 6)
                }
                okDispatch = await waitForDispatch(
                    expectedAction: action,
                    expectedBundle: targetBundleIdentifier,
                    expectedSource: trigger.rawValue,
                    baseline: baseline,
                    timeout: 0.75
                )
            }
        }

        switch trigger {
        case .click, .scrollUp, .scrollDown:
            break
        }
        if !okDispatch {
            let got = coordinator.lastActionExecuted?.rawValue ?? "nil"
            let gotBundle = coordinator.lastActionExecutedBundle ?? "nil"
            let gotSource = coordinator.lastActionExecutedSource ?? "nil"
            return CaseResult(action: action, trigger: trigger, passed: false, detail: "No dispatch (got action=\(got), bundle=\(gotBundle), source=\(gotSource))")
        }

        // Verify effect when possible.
        let effect = verifyEffect(action: action, targetBundleIdentifier: targetBundleIdentifier)
        return CaseResult(action: action, trigger: trigger, passed: effect.passed, detail: effect.detail)
    }

    private func verifyEffect(action: DockAction, targetBundleIdentifier: String) -> (passed: Bool, detail: String) {
        switch action {
        case .none:
            return (true, "No action configured (pass-through)")
        case .hideApp:
            let hidden = WindowManager.isAppHidden(bundleIdentifier: targetBundleIdentifier)
            return (hidden, hidden ? "Target app hidden" : "Target app not hidden")
        case .hideOthers:
            let anyHidden = WindowManager.anyHiddenOthers(excluding: targetBundleIdentifier)
            return (anyHidden, anyHidden ? "Other apps hidden" : "No other apps hidden")
        case .bringAllToFront:
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            return (front == targetBundleIdentifier, "Frontmost=\(front ?? "nil")")
        case .minimizeAll:
            let minimized = WindowManager.allWindowsMinimized(bundleIdentifier: targetBundleIdentifier)
            return (minimized, minimized ? "All windows minimized" : "Not all windows minimized")
        case .quitApp:
            let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == targetBundleIdentifier }
            return (!running, running ? "Target still running" : "Target quit")
        case .appExpose:
            // We can only validate dispatch. Whether Mission Control responds depends on the user's
            // configured shortcut in System Settings.
            let configured = coordinator.isAppExposeShortcutConfigured
            if !configured {
                return (true, "Posted App Expose hotkey (not configured in System Settings; verification skipped)")
            }
            return (true, "Posted App Expose hotkey")
        case .singleAppMode:
            let hidden = WindowManager.isAppHidden(bundleIdentifier: targetBundleIdentifier)
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let passed = hidden || front == targetBundleIdentifier
            return (passed, "Single app mode frontmost=\(front ?? "nil") hidden=\(hidden)")
        }
    }

    private func ensureHelperAppRunning() async {
        let helperBundle = "com.apple.TextEdit"
        await launchTarget(bundleIdentifier: helperBundle)
        _ = WindowManager.unhideApp(bundleIdentifier: helperBundle)
        _ = WindowManager.restoreAllWindows(bundleIdentifier: helperBundle)
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    private func selectTargetBundleIdentifier(preferred: String) async -> String? {
        var candidates: [String] = []
        candidates.append(preferred)
        candidates.append(contentsOf: [
            "com.apple.calculator",
            "com.apple.TextEdit",
            "com.apple.Preview",
            "com.apple.Notes",
        ])

        // De-dupe while preserving order.
        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0).inserted }

        for bundle in candidates {
            await launchTarget(bundleIdentifier: bundle)
            if coordinator.findDockIconPoint(bundleIdentifier: bundle) != nil {
                return bundle
            }
        }
        return nil
    }

    private func waitForDispatch(expectedAction: DockAction, expectedBundle: String, expectedSource: String, baseline: Date, timeout: TimeInterval) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if let at = coordinator.lastActionExecutedAt,
               at > baseline,
               coordinator.lastActionExecuted == expectedAction,
               coordinator.lastActionExecutedBundle == expectedBundle,
               coordinator.lastActionExecutedSource == expectedSource {
                return true
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return false
    }

    private func launchTarget(bundleIdentifier: String) async {
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    private func resetTargetState(targetBundleIdentifier: String) async {
        _ = WindowManager.showAllApplications()
        _ = WindowManager.unhideApp(bundleIdentifier: targetBundleIdentifier)
        _ = WindowManager.restoreAllWindows(bundleIdentifier: targetBundleIdentifier)
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    private func liveDockPoint(for bundleIdentifier: String, around seed: CGPoint) -> CGPoint? {
        if let b = DockHitTest.bundleIdentifierAtPoint(seed), b == bundleIdentifier {
            return seed
        }

        let deltas: [CGFloat] = [0, -8, 8, -16, 16, -24, 24]
        for dy in deltas {
            for dx in deltas {
                let p = CGPoint(x: seed.x + dx, y: seed.y + dy)
                if let b = DockHitTest.bundleIdentifierAtPoint(p), b == bundleIdentifier {
                    return p
                }
            }
        }
        return nil
    }

    private func candidatePoints(seed: CGPoint, bundleIdentifier: String) -> [CGPoint] {
        var out: [CGPoint] = []
        if let live = liveDockPoint(for: bundleIdentifier, around: seed) {
            out.append(live)
        }

        let offsets: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: -6, y: 0), CGPoint(x: 6, y: 0),
            CGPoint(x: 0, y: -6), CGPoint(x: 0, y: 6),
            CGPoint(x: -12, y: -4), CGPoint(x: 12, y: -4),
            CGPoint(x: -18, y: 0), CGPoint(x: 18, y: 0),
        ]
        for o in offsets {
            let p = CGPoint(x: seed.x + o.x, y: seed.y + o.y)
            if !out.contains(where: { $0 == p }) {
                out.append(p)
            }
        }
        return out
    }
}
