import AppKit

struct HotKey {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

enum AppExposeInvokeStrategy: String {
    case dockAccessibility = "dockAccessibility"
    case dockNotification = "dockNotification"
    case resolvedHotKey = "resolvedHotKey"
    case fallbackControlDown = "fallbackControlDown"
}

struct AppExposeInvokeResult {
    let dispatched: Bool
    let evidence: Bool
    let confirmed: Bool
    let acknowledged: Bool
    let strategy: AppExposeInvokeStrategy?
    let attempts: [String]
    let frontmostAfter: String
}

struct AppExposeDispatchReceipt {
    let dispatched: Bool
    let strategy: AppExposeInvokeStrategy?
    let attempts: [String]
    let frontmostAfterDispatch: String
}

private struct DockWindowSignature: Hashable {
    let windowNumber: Int
    let layer: Int
    let widthBucket: Int
    let heightBucket: Int
    let alphaBucket: Int
    let title: String
}

private struct AppExposeAttemptOutcome {
    let dispatched: Bool
    let evidence: Bool
    let strategy: AppExposeInvokeStrategy?
    var acknowledged: Bool = false
}

/// Prefers the target Dock item's App Exposé action; notification is an availability fallback.
@MainActor
final class AppExposeInvoker {
    private let appExposeDockNotification = "com.apple.expose.front.awake"
    private let evidenceSampleDelaysNs: [UInt64] = [60_000_000, 120_000_000, 180_000_000]

    private let performDockAction: (String) -> AXError
    private let postNotification: (String) -> Bool
    private let frontmostBundle: () -> String?

    init(performDockAction: @escaping (String) -> AXError = DockAppExposeAction.perform,
         postNotification: @escaping (String) -> Bool = DockNotificationSender.post,
         frontmostBundle: @escaping () -> String? = {
             NSWorkspace.shared.frontmostApplication?.bundleIdentifier
         }) {
        self.performDockAction = performDockAction
        self.postNotification = postNotification
        self.frontmostBundle = frontmostBundle
    }

    // Diagnostics kept for UI/test compatibility.
    private(set) var lastResolvedHotKey: HotKey?
    private(set) var lastResolveError: String?
    private(set) var lastInvokeStrategy: AppExposeInvokeStrategy?
    private(set) var lastInvokeAttempts: [String] = []
    private(set) var lastForcedStrategy: String?

    @discardableResult
    func invokeApplicationWindows(for bundle: String,
                                  requireEvidence: Bool = true,
                                  completion: @escaping (AppExposeInvokeResult) -> Void) -> AppExposeDispatchReceipt {
        Logger.debug("AppExposeInvoker: invokeApplicationWindows called for bundle \(bundle)")

        lastResolvedHotKey = nil
        lastResolveError = "not-used (Dock accessibility/notification path)"
        lastInvokeStrategy = nil
        lastInvokeAttempts = []
        lastForcedStrategy = nil

        let baselineDockSignature = dockWindowSignatureSnapshot()
        Logger.debug("AppExposeInvoker: baselineDockWindows=\(baselineDockSignature.count) screenCapture=\(CGPreflightScreenCaptureAccess())")
        let accessibilityResult = performDockAction(bundle)
        recordAttempt("dockAccessibility result=\(accessibilityResult.rawValue)")
        // Cannot-complete can mean that Dock received the action but its reply timed out.
        // Never send a second toggle after an ambiguous dispatch.
        let useNotification = accessibilityResult == .actionUnsupported
            || accessibilityResult == .noValue
            || accessibilityResult == .invalidUIElement
            || accessibilityResult == .apiDisabled
        let posted: Bool
        let strategy: AppExposeInvokeStrategy?
        if useNotification {
            posted = frontmostBundle() == bundle
                && postNotification(appExposeDockNotification)
            strategy = posted ? .dockNotification : nil
            recordAttempt("dockNotification posted=\(posted)")
        } else {
            posted = accessibilityResult == .success || accessibilityResult == .cannotComplete
            strategy = posted ? .dockAccessibility : nil
        }
        Logger.debug("AppExposeInvoker: target=\(bundle) attempts=\(lastInvokeAttempts)")
        lastInvokeStrategy = strategy

        let receipt = AppExposeDispatchReceipt(
            dispatched: posted,
            strategy: strategy,
            attempts: lastInvokeAttempts,
            frontmostAfterDispatch: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        )

        guard posted else {
            completion(
                finalizeResult(
                    AppExposeAttemptOutcome(dispatched: false, evidence: false, strategy: nil),
                    requireEvidence: requireEvidence
                )
            )
            return receipt
        }

        guard requireEvidence else {
            Logger.debug("AppExposeInvoker: selected strategy=\(strategy?.rawValue ?? "none") (evidence not required)")
            completion(
                finalizeResult(
                    AppExposeAttemptOutcome(dispatched: true,
                                            evidence: false,
                                            strategy: strategy,
                                            acknowledged: accessibilityResult == .success),
                    requireEvidence: false
                )
            )
            return receipt
        }

        Task { [weak self] in
            guard let self else { return }
            let evidence = await self.waitForExposeEvidence(baselineDockSignature: baselineDockSignature)
            self.recordAttempt("\(strategy?.rawValue ?? "none") evidence=\(evidence)")
            if evidence {
                Logger.debug("AppExposeInvoker: selected strategy=\(strategy?.rawValue ?? "none")")
            } else {
                Logger.debug("AppExposeInvoker: dispatch completed but no Expose evidence")
            }
            completion(
                self.finalizeResult(
                    AppExposeAttemptOutcome(dispatched: true,
                                            evidence: evidence,
                                            strategy: strategy,
                                            acknowledged: accessibilityResult == .success),
                    requireEvidence: true
                )
            )
        }

        return receipt
    }

    func isApplicationWindowsHotKeyConfigured() -> Bool {
        false
    }

    func isDockNotificationAvailable() -> Bool {
        DockNotificationSender.isAvailable
    }

    private func recordAttempt(_ attempt: String) {
        lastInvokeAttempts.append(attempt)
    }

    private func finalizeResult(_ outcome: AppExposeAttemptOutcome,
                                requireEvidence: Bool) -> AppExposeInvokeResult {
        let frontmostAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        let confirmed = DockDecisionEngine.appExposeInvocationConfirmed(dispatched: outcome.dispatched,
                                                                        evidence: outcome.evidence,
                                                                        requireEvidence: requireEvidence)
        return AppExposeInvokeResult(dispatched: outcome.dispatched,
                                     evidence: outcome.evidence,
                                     confirmed: confirmed,
                                     acknowledged: outcome.acknowledged,
                                     strategy: outcome.strategy,
                                     attempts: lastInvokeAttempts,
                                     frontmostAfter: frontmostAfter)
    }

    private func waitForExposeEvidence(baselineDockSignature: Set<DockWindowSignature>) async -> Bool {
        for delay in evidenceSampleDelaysNs {
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return false
            }

            if isExposeEvidencePresent(baselineDockSignature: baselineDockSignature) {
                return true
            }
        }
        return isExposeEvidencePresent(baselineDockSignature: baselineDockSignature)
    }

    private func isExposeEvidencePresent(baselineDockSignature: Set<DockWindowSignature>) -> Bool {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if frontmost == "com.apple.dock" {
            return true
        }
        let dockAfter = dockWindowSignatureSnapshot()
        let delta = baselineDockSignature.symmetricDifference(dockAfter).count
        Logger.debug("AppExposeInvoker: evidenceSample frontmost=\(frontmost ?? "nil") dockWindows=\(dockAfter.count) delta=\(delta)")
        return delta > 0
    }

    private func dockWindowSignatureSnapshot() -> Set<DockWindowSignature> {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        var signatures = Set<DockWindowSignature>()
        for window in raw {
            guard let owner = window[kCGWindowOwnerName as String] as? String, owner == "Dock" else {
                continue
            }

            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 1.0
            let title = (window[kCGWindowName as String] as? String) ?? ""
            let windowNumber = window[kCGWindowNumber as String] as? Int ?? -1
            let bounds = window[kCGWindowBounds as String] as? [String: Any]
            let width = Int((bounds?["Width"] as? Double) ?? 0)
            let height = Int((bounds?["Height"] as? Double) ?? 0)
            signatures.insert(
                DockWindowSignature(windowNumber: windowNumber,
                                    layer: layer,
                                    widthBucket: width / 10,
                                    heightBucket: height / 10,
                                    alphaBucket: Int(alpha * 10.0),
                                    title: title)
            )
        }
        return signatures
    }
}

enum DockNotificationSender {
    private typealias CoreDockSendNotificationFn = @convention(c) (CFString, UnsafeMutableRawPointer?) -> Void

    private static let fn: CoreDockSendNotificationFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSendNotification") else {
            Logger.log("DockNotificationSender: CoreDockSendNotification symbol unavailable")
            return nil
        }
        return unsafeBitCast(symbol, to: CoreDockSendNotificationFn.self)
    }()

    static var isAvailable: Bool {
        fn != nil
    }

    static func post(notification: String) -> Bool {
        guard let fn else { return false }
        fn(notification as CFString, nil)
        return true
    }
}

enum DockAppExposeAction {
    static func perform(for bundleIdentifier: String) -> AXError {
        guard let dock = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.dock"
        }) else { return .noValue }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        var pending: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        while let (element, depth) = pending.popLast(), visited < 256 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return .noValue }
            visited += 1
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            if subrole as? String == "AXApplicationDockItem" {
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value)
                if let url = value as? URL,
                   Bundle(url: url)?.bundleIdentifier == bundleIdentifier {
                    var actions: CFArray?
                    let result = AXUIElementCopyActionNames(element, &actions)
                    guard result == .success else { return result }
                    guard (actions as? [String])?.contains("AXShowExpose") == true else {
                        return .actionUnsupported
                    }
                    return AXUIElementPerformAction(element, "AXShowExpose" as CFString)
                }
            }
            guard depth < 3 else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let elements = children as? [AXUIElement] {
                pending.append(contentsOf: elements.prefix(256).map { ($0, depth + 1) })
            }
        }
        return .noValue
    }
}
