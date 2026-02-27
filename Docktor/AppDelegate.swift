import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var services: AppServices = .live

    private var coordinator: DockExposeCoordinator { Self.services.coordinator }
    private var preferences: Preferences { Self.services.preferences }
    private var updateManager: UpdateManager { Self.services.updateManager }
    private let legacyAppBundleNames = ["DockActioner.app", "Dockter.app"]
    private let currentAppBundleName = "Docktor.app"
    private let openSettingsLaunchArguments: Set<String> = ["--settings", "-settings", "--open-settings"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        migrateLegacyAppBundleNameIfNeeded()
        Logger.log("Launched bundle at \(Bundle.main.bundleURL.path), bundleId \(Bundle.main.bundleIdentifier ?? "nil"), pid \(ProcessInfo.processInfo.processIdentifier), LSUIElement \(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool ?? false)")

        terminateOtherInstances()

        coordinator.startIfPossible()
        updateManager.configureForLaunch(isAutomatedMode: false)

        let isFirstLaunch = !preferences.firstLaunchCompleted
        let launchRequestsSettings = ProcessInfo.processInfo.arguments.contains { openSettingsLaunchArguments.contains($0) }
        let shouldShowWindow = launchRequestsSettings || isFirstLaunch || preferences.showOnStartup
        if launchRequestsSettings {
            Logger.log("Launch argument requested settings window")
        }

        DispatchQueue.main.async {
            if shouldShowWindow {
                self.showSettingsWindow()
            } else {
                self.hideSettingsWindow()
            }
            self.handlePermissionsIfNeeded(allowPrompt: shouldShowWindow)
            if isFirstLaunch {
                self.preferences.firstLaunchCompleted = true
            }
        }
    }

    private func terminateOtherInstances() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != me }

        guard !others.isEmpty else { return }
        Logger.log("Terminating other running instances: \(others.map { $0.processIdentifier })")
        for app in others {
            _ = app.terminate()
        }
    }

    private func migrateLegacyAppBundleNameIfNeeded() {
        let currentBundleURL = Bundle.main.bundleURL.standardizedFileURL
        guard legacyAppBundleNames.contains(currentBundleURL.lastPathComponent) else { return }

        let destinationURL = currentBundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(currentAppBundleName, isDirectory: true)
            .standardizedFileURL
        guard destinationURL.path != currentBundleURL.path else { return }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            Logger.log("Legacy app rename skipped: destination already exists at \(destinationURL.path)")
            return
        }

        do {
            try fileManager.moveItem(at: currentBundleURL, to: destinationURL)
            Logger.log("Renamed legacy app bundle from \(currentBundleURL.lastPathComponent) to \(currentAppBundleName)")
        } catch {
            Logger.log("Legacy app rename failed from \(currentBundleURL.lastPathComponent) to \(currentAppBundleName): \(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }

    private func handlePermissionsIfNeeded(allowPrompt: Bool) {
        let needsAccessibility = !coordinator.hasAccessibilityPermission
        let needsInputMonitoring = !coordinator.inputMonitoringGranted
        guard needsAccessibility || needsInputMonitoring else { return }

        if allowPrompt && needsAccessibility {
            coordinator.requestAccessibilityPermission()
        }

        if allowPrompt && needsInputMonitoring {
            let delay: TimeInterval = needsAccessibility ? 0.6 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.coordinator.requestInputMonitoringPermission()
                self.coordinator.startWhenPermissionAvailable()
            }
        } else {
            coordinator.startWhenPermissionAvailable()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleIncomingURL(url)
        }
    }

    private func handleIncomingURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "docktor" || scheme == "dockter" else {
            return
        }

        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        if host == "settings" || host == "preferences" || path == "/settings" || path == "/preferences" {
            Logger.log("Received URL request to open settings: \(url.absoluteString)")
            showSettingsWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsWindow()
        return true
    }

    @objc func showSettingsWindow(_ sender: Any?) {
        showSettingsWindow()
    }

    func showSettingsWindow() {
        Logger.log("Opening settings window")
        NSApp.activate(ignoringOtherApps: true)

        let openedViaSettings = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        if openedViaSettings {
            return
        }

        let openedViaPreferences = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        if openedViaPreferences {
            return
        }

        Logger.log("Unable to route to system settings window action")
    }

    private func hideSettingsWindow() {
        NSApp.windows
            .filter { $0.title == "Settings" || $0.title == "Docktor Settings" }
            .forEach { $0.orderOut(nil) }
    }
}
