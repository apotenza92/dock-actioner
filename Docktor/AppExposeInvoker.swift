import AppKit
import Darwin

struct HotKey {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

enum AppExposeInvokeStrategy: String {
    case dockNotification = "dockNotification"
    case resolvedHotKey = "resolvedHotKey"
    case fallbackControlDown = "fallbackControlDown"
}

struct AppExposeInvokeResult {
    let dispatched: Bool
    let evidence: Bool
    let strategy: AppExposeInvokeStrategy?
    let attempts: [String]
    let frontmostAfter: String
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

    func successful(requireEvidence: Bool) -> Bool {
        if requireEvidence {
            return dispatched && evidence
        }
        return dispatched
    }
}

/// Triggers App Expose via Dock private API.
final class AppExposeInvoker {
    private let appExposeDockNotification = "com.apple.expose.front.awake"
    private let evidenceSampleDelaysUs: [useconds_t] = [80_000, 140_000, 220_000]

    // Diagnostics kept for UI/test compatibility.
    private(set) var lastResolvedHotKey: HotKey?
    private(set) var lastResolveError: String?
    private(set) var lastInvokeStrategy: AppExposeInvokeStrategy?
    private(set) var lastInvokeAttempts: [String] = []
    private(set) var lastForcedStrategy: String?

    func invokeApplicationWindows(for bundle: String, requireEvidence: Bool = true) -> AppExposeInvokeResult {
        Logger.log("AppExposeInvoker: invokeApplicationWindows called for bundle \(bundle)")

        lastResolvedHotKey = nil
        lastResolveError = "not-used (private Dock notification path)"
        lastInvokeStrategy = nil
        lastInvokeAttempts = []
        lastForcedStrategy = nil

        let baselineDockSignature = dockWindowSignatureSnapshot()
        let outcome = attemptDockNotification(requireEvidence: requireEvidence,
                                              baselineDockSignature: baselineDockSignature)
        return finalizeResult(outcome)
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

    private func finalizeResult(_ outcome: AppExposeAttemptOutcome) -> AppExposeInvokeResult {
        let frontmostAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        return AppExposeInvokeResult(dispatched: outcome.dispatched,
                                     evidence: outcome.evidence,
                                     strategy: outcome.strategy,
                                     attempts: lastInvokeAttempts,
                                     frontmostAfter: frontmostAfter)
    }

    private func attemptDockNotification(requireEvidence: Bool,
                                         baselineDockSignature: Set<DockWindowSignature>) -> AppExposeAttemptOutcome {
        let posted = DockNotificationSender.post(notification: appExposeDockNotification)
        recordAttempt("dockNotification posted=\(posted)")
        Logger.log("AppExposeInvoker: attempt=dockNotification(\(appExposeDockNotification)) posted=\(posted)")
        guard posted else {
            return AppExposeAttemptOutcome(dispatched: false, evidence: false, strategy: nil)
        }

        let evidence = waitForExposeEvidence(baselineDockSignature: baselineDockSignature)
        recordAttempt("dockNotification evidence=\(evidence)")
        if evidence || !requireEvidence {
            lastInvokeStrategy = .dockNotification
            Logger.log("AppExposeInvoker: selected strategy=dockNotification")
            return AppExposeAttemptOutcome(dispatched: true,
                                           evidence: evidence,
                                           strategy: .dockNotification)
        }

        Logger.log("AppExposeInvoker: dock notification posted but no Expose evidence")
        return AppExposeAttemptOutcome(dispatched: true, evidence: false, strategy: .dockNotification)
    }

    private func waitForExposeEvidence(baselineDockSignature: Set<DockWindowSignature>) -> Bool {
        for delay in evidenceSampleDelaysUs {
            usleep(delay)
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

private enum DockNotificationSender {
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
