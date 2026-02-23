import AppKit
import ApplicationServices

enum WindowManager {
    private static let braveBundleIdentifier = "com.brave.Browser"
    private static let braveAuxiliarySubroles: Set<String> = [
        "AXFloatingWindow",
        "AXSystemFloatingWindow",
        "AXUnknown"
    ]

    /// Hide all windows of an app (Cmd+H equivalent)
    static func hideAllWindows(bundleIdentifier: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            Logger.log("WindowManager: App \(bundleIdentifier) is not running")
            return false
        }
        
        // First try the direct NSRunningApplication hide
        if app.hide() {
            Logger.log("WindowManager: hide() succeeded for \(bundleIdentifier)")
            return true
        }
        
        if app.isHidden {
            Logger.log("WindowManager: App \(bundleIdentifier) already hidden; treating as success")
            return true
        }
        
        // Try Accessibility hide as a stronger fallback
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let hidden: CFBoolean = kCFBooleanTrue
        if AXUIElementSetAttributeValue(appElement, kAXHiddenAttribute as CFString, hidden) == .success {
            Logger.log("WindowManager: AX hide succeeded for \(bundleIdentifier)")
            return true
        }

        Logger.log("WindowManager: AX hide failed for \(bundleIdentifier)")
        return false
    }
    
    /// Unhide an app and activate it
    static func unhideApp(bundleIdentifier: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            Logger.log("WindowManager: App \(bundleIdentifier) is not running, cannot unhide")
            return false
        }
        app.unhide()
        _ = app.activate(options: [.activateIgnoringOtherApps])
        Logger.log("WindowManager: Unhid and activated \(bundleIdentifier)")
        return true
    }
    
    /// Check if app is hidden
    static func isAppHidden(bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier })?.isHidden ?? false
    }
    
    /// Minimize all windows of an app to the Dock
    static func minimizeAllWindows(bundleIdentifier: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            Logger.log("WindowManager: App \(bundleIdentifier) is not running")
            return false
        }
        
        if app.isHidden {
            app.unhide()
        }
        let windowsArray = appWindows(for: app)
        guard !windowsArray.isEmpty else {
            Logger.log("WindowManager: No windows to minimize for \(bundleIdentifier)")
            return false
        }
        
        var minimizedCount = 0
        for window in windowsArray {
            var minimizedValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
               let isMinimized = minimizedValue as? Bool, isMinimized {
                continue // Already minimized
            }
            
            let minimized: CFBoolean = kCFBooleanTrue
            if AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, minimized) == .success {
                minimizedCount += 1
            }
        }
        
        Logger.log("WindowManager: Minimized \(minimizedCount) windows for \(bundleIdentifier)")
        return minimizedCount > 0
        
    }
    
    /// Restore all minimized windows of an app
    static func restoreAllWindows(bundleIdentifier: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            Logger.log("WindowManager: App \(bundleIdentifier) is not running")
            return false
        }
        
        let windowsArray = appWindows(for: app)
        guard !windowsArray.isEmpty else {
            Logger.log("WindowManager: No windows to restore for \(bundleIdentifier)")
            return false
        }
        
        var restoredCount = 0
        for window in windowsArray {
            var minimizedValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
               let isMinimized = minimizedValue as? Bool, isMinimized {
                let minimized: CFBoolean = kCFBooleanFalse
                if AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, minimized) == .success {
                    restoredCount += 1
                }
            }
        }
        
        Logger.log("WindowManager: Restored \(restoredCount) windows for \(bundleIdentifier)")
        
        guard restoredCount > 0 else { return false }
        
        // Bring the app to the front.
        _ = app.activate(options: [.activateIgnoringOtherApps])
        
        // Re-assert frontmost after a short delay to cover race conditions.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            _ = app.activate(options: [.activateIgnoringOtherApps])
        }
        
        return true
    }
    
    /// Check if all windows are minimized (and there is at least one window)
    static func allWindowsMinimized(bundleIdentifier: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return false
        }
        
        let windowsArray = appWindows(for: app)
        guard !windowsArray.isEmpty else {
            return false
        }
        
        for window in windowsArray {
            var minimizedValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
               let isMinimized = minimizedValue as? Bool, isMinimized {
                continue
            } else {
                return false
            }
        }
        return true
    }
    
    /// Check if an app has visible windows
    static func hasVisibleWindows(bundleIdentifier: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return false
        }
        
        let windowsArray = appWindows(for: app)
        guard !windowsArray.isEmpty else {
            return false
        }
        
        for window in windowsArray {
            var minimizedValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
               let isMinimized = minimizedValue as? Bool, isMinimized {
                continue // Skip minimized windows
            }
            
            var hiddenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXHiddenAttribute as CFString, &hiddenValue) == .success,
               let isHidden = hiddenValue as? Bool, isHidden {
                continue // Skip hidden windows
            }
            
            // Found at least one visible, non-minimized window
            return true
        }
        
        return false
    }

    /// Count all AX windows currently reported by the application.
    static func totalWindowCount(bundleIdentifier: String) -> Int {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return 0
        }

        return appWindows(for: app).count
    }

    /// True when the app currently reports at least two windows.
    static func hasMultipleWindowsOpen(bundleIdentifier: String) -> Bool {
        totalWindowCount(bundleIdentifier: bundleIdentifier) >= 2
    }
    
    /// Get the main window of an app
    static func getMainWindow(bundleIdentifier: String) -> AXUIElement? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return nil
        }
        
        let pid = app.processIdentifier
        
        let appElement = AXUIElementCreateApplication(pid)
        var mainWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainWindow)
        
        guard result == .success,
              let windowRef = mainWindow,
              CFGetTypeID(windowRef) == AXUIElementGetTypeID() else {
            // Try getting first window if no main window
            if let firstWindow = appWindows(for: app).first {
                return firstWindow
            }
            return nil
        }
        
        return (windowRef as! AXUIElement)
    }
    
    /// Activate an app and show its main window
    static func activateAndShowMainWindow(bundleIdentifier: String) -> Bool {
        // First, activate the app
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            Logger.log("WindowManager: App \(bundleIdentifier) is not running, cannot activate")
            return false
        }
        
        _ = app.activate(options: [.activateIgnoringOtherApps])
        
        // Wait a moment for app to activate, then show main window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let mainWindow = getMainWindow(bundleIdentifier: bundleIdentifier) {
                var position: CFTypeRef?
                if AXUIElementCopyAttributeValue(mainWindow, kAXPositionAttribute as CFString, &position) == .success {
                    // Window exists, try to bring it forward
                    let frontmost: CFBoolean = kCFBooleanTrue
                    AXUIElementSetAttributeValue(mainWindow, kAXFrontmostAttribute as CFString, frontmost)
                }
            }
        }
        
        Logger.log("WindowManager: Activated app \(bundleIdentifier) and showing main window")
        return true
    }
    
    /// Quit an app gracefully
    static func quitApp(bundleIdentifier: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            Logger.log("WindowManager: App \(bundleIdentifier) is not running, cannot quit")
            return false
        }

        let terminateRequested = app.terminate()
        if waitForTermination(app, timeout: 0.8) {
            Logger.log("WindowManager: App \(bundleIdentifier) terminated gracefully")
            return true
        }

        Logger.log("WindowManager: terminate() did not finish for \(bundleIdentifier), requested=\(terminateRequested). Attempting forceTerminate.")
        _ = app.forceTerminate()
        if waitForTermination(app, timeout: 0.8) {
            Logger.log("WindowManager: App \(bundleIdentifier) force-terminated")
            return true
        }

        Logger.log("WindowManager: Failed to terminate \(bundleIdentifier)")
        return false
    }
    
    /// Bring all windows of an app to the front (without minimizing/restore)
    static func bringAllToFront(bundleIdentifier: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            Logger.log("WindowManager: App \(bundleIdentifier) is not running")
            return false
        }
        
        let windows = appWindows(for: app)
        guard !windows.isEmpty else {
            Logger.log("WindowManager: No windows to bring front for \(bundleIdentifier)")
            return false
        }
        
        var raisedCount = 0
        for window in windows {
            if AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success {
                raisedCount += 1
            }
        }
        
        _ = app.activate(options: [.activateIgnoringOtherApps])
        
        Logger.log("WindowManager: Raised \(raisedCount) windows for \(bundleIdentifier)")
        return raisedCount > 0
    }
    
    /// Hide all other apps except the provided bundle
    static func hideOthers(bundleIdentifier: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            Logger.log("WindowManager: App \(bundleIdentifier) is not running")
            return false
        }
        
        // Activate target app first (and unhide if needed)
        if app.isHidden {
            app.unhide()
        }
        _ = app.activate(options: [.activateIgnoringOtherApps])

        var hiddenCount = 0
        for other in NSWorkspace.shared.runningApplications {
            guard other.processIdentifier != app.processIdentifier,
                  other.activationPolicy == .regular,
                  !other.isTerminated,
                  !other.isHidden
            else {
                continue
            }

            if other.hide() {
                hiddenCount += 1
                continue
            }

            let element = AXUIElementCreateApplication(other.processIdentifier)
            let hidden: CFBoolean = kCFBooleanTrue
            if AXUIElementSetAttributeValue(element, kAXHiddenAttribute as CFString, hidden) == .success {
                hiddenCount += 1
            }
        }

        Logger.log("WindowManager: Hide others invoked for \(bundleIdentifier); hidden=\(hiddenCount)")
        return true
    }
    
    /// Show all apps (inverse of Hide Others)
    static func showAllApplications() -> Bool {
        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        var changed = false
        for app in apps {
            if app.isHidden {
                app.unhide()
                changed = true
            }
        }
        
        if changed {
            Logger.log("WindowManager: Show All - unhid applications")
            return true
        }

        Logger.log("WindowManager: Show All - no hidden apps found")
        return true
    }
    
    /// Check if any other app (excluding the provided bundle) is currently hidden.
    static func anyHiddenOthers(excluding bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard let id = app.bundleIdentifier else { return false }
            guard id != bundleIdentifier else { return false }
            guard app.activationPolicy == .regular else { return false }
            guard !app.isTerminated else { return false }
            return app.isHidden
        }
    }

    private static func waitForTermination(_ app: NSRunningApplication,
                                           timeout: TimeInterval,
                                           pollInterval: TimeInterval = 0.05) -> Bool {
        if app.isTerminated {
            return true
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.isTerminated {
                return true
            }

            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(pollInterval))
        }
        return app.isTerminated
    }

    private static func appWindows(for app: NSRunningApplication) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let rawWindows = windowsRef as? [AXUIElement] else {
            return []
        }

        guard let bundleIdentifier = app.bundleIdentifier else {
            return rawWindows
        }
        return rawWindows.filter { shouldIncludeWindow($0, bundleIdentifier: bundleIdentifier) }
    }

    private static func shouldIncludeWindow(_ window: AXUIElement, bundleIdentifier: String) -> Bool {
        if let role = stringAttribute(window, attribute: kAXRoleAttribute as CFString),
           role != (kAXWindowRole as String) {
            return false
        }

        if bundleIdentifier == braveBundleIdentifier,
           isLikelyBraveAuxiliaryWindow(window) {
            let title = stringAttribute(window, attribute: kAXTitleAttribute as CFString) ?? "nil"
            let subrole = stringAttribute(window, attribute: kAXSubroleAttribute as CFString) ?? "nil"
            let identifier = stringAttribute(window, attribute: "AXIdentifier" as CFString) ?? "nil"
            Logger.debug("WindowManager: Excluding Brave auxiliary window title=\(title) subrole=\(subrole) identifier=\(identifier)")
            return false
        }

        return true
    }

    private static func isLikelyBraveAuxiliaryWindow(_ window: AXUIElement) -> Bool {
        let subrole = stringAttribute(window, attribute: kAXSubroleAttribute as CFString) ?? ""
        if braveAuxiliarySubroles.contains(subrole) {
            return true
        }

        let textFields = [
            stringAttribute(window, attribute: kAXTitleAttribute as CFString),
            stringAttribute(window, attribute: "AXIdentifier" as CFString),
            stringAttribute(window, attribute: kAXDescriptionAttribute as CFString)
        ]
        let containsSidebarMarker = textFields
            .compactMap { $0?.lowercased() }
            .contains { value in
                value.contains("sidebar") || value.contains("side panel") || value.contains("sidepanel") || value.contains("vertical tabs")
            }
        guard containsSidebarMarker else {
            return false
        }

        let hasTrafficLightControls =
            hasElementAttribute(window, attribute: kAXCloseButtonAttribute as CFString) ||
            hasElementAttribute(window, attribute: kAXMinimizeButtonAttribute as CFString) ||
            hasElementAttribute(window, attribute: kAXZoomButtonAttribute as CFString)
        return !hasTrafficLightControls
    }

    private static func stringAttribute(_ element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }
        return value as? String
    }

    private static func hasElementAttribute(_ element: AXUIElement, attribute: CFString) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return false
        }
        return CFGetTypeID(value) == AXUIElementGetTypeID()
    }

}
