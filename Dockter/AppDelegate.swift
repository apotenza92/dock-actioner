import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private let coordinator = DockExposeCoordinator.shared
    private let preferences = Preferences.shared
    private let updateManager = UpdateManager.shared
    private let settingsWindowIdentifier = NSUserInterfaceItemIdentifier("DockterSettingsWindow")
    private var fallbackPreferencesWindow: NSWindow?
    private let legacyAppBundleName = "DockActioner.app"
    private let currentAppBundleName = "Dockter.app"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        migrateLegacyAppBundleNameIfNeeded()
        Logger.log("Launched bundle at \(Bundle.main.bundleURL.path), bundleId \(Bundle.main.bundleIdentifier ?? "nil"), pid \(ProcessInfo.processInfo.processIdentifier), LSUIElement \(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool ?? false)")

        terminateOtherInstances()

        configureStatusItem()
        coordinator.startIfPossible()
        updateManager.configureForLaunch(isAutomatedMode: false)
        
        let isFirstLaunch = !preferences.firstLaunchCompleted
        let shouldShowWindow = isFirstLaunch || preferences.showOnStartup
        DispatchQueue.main.async {
            if shouldShowWindow {
                NSApp.activate(ignoringOtherApps: true)
                self.showPreferencesWindow()
            } else {
                self.hidePreferencesWindow()
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
        guard currentBundleURL.lastPathComponent == legacyAppBundleName else { return }

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
            Logger.log("Renamed legacy app bundle from \(legacyAppBundleName) to \(currentAppBundleName)")
        } catch {
            Logger.log("Legacy app rename failed from \(legacyAppBundleName) to \(currentAppBundleName): \(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }

    private func configureStatusItem() {
        Logger.log("Configuring status item.")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = StatusBarIcon.image()
        item.button?.image?.isTemplate = true
        item.button?.setAccessibilityLabel("Dockter")
        statusMenu.delegate = self
        item.menu = statusMenu
        rebuildStatusMenu()
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        statusMenu.removeAllItems()

        let preferencesItem = NSMenuItem(title: "Preferences…",
                                         action: #selector(showPreferences),
                                         keyEquivalent: ",")
        preferencesItem.target = self
        statusMenu.addItem(preferencesItem)

        statusMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Dockter",
                                  action: #selector(quit),
                                  keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }
    
    @objc private func showPreferences() {
        showPreferencesWindow()
        Logger.log("Status menu preferences triggered.")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
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
                self.rebuildStatusMenu()
            }
        } else {
            coordinator.startWhenPermissionAvailable()
            rebuildStatusMenu()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPreferencesWindow()
        return true
    }

    private func showPreferencesWindow() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = currentPreferencesWindow {
            configurePreferencesWindow(window)
            window.makeKeyAndOrderFront(nil)
            return
        }

        showFallbackPreferencesWindow()
    }
    
    private func hidePreferencesWindow() {
        currentPreferencesWindow?.orderOut(nil)
        fallbackPreferencesWindow?.orderOut(nil)
    }

    private var currentPreferencesWindow: NSWindow? {
        if let fallbackPreferencesWindow {
            return fallbackPreferencesWindow
        }
        return NSApp.windows.first(where: {
            $0.identifier == settingsWindowIdentifier || $0.title == "Dockter Settings" || $0.title == "Settings"
        })
    }

    private func configurePreferencesWindow(_ window: NSWindow) {
        window.identifier = settingsWindowIdentifier
        window.title = "Dockter Settings"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = false
        sizePreferencesWindowToContent(window)
        window.center()
    }

    private func sizePreferencesWindowToContent(_ window: NSWindow) {
        guard let contentView = window.contentView else { return }
        contentView.layoutSubtreeIfNeeded()
        let fittingSize = contentView.fittingSize
        guard fittingSize.width > 0, fittingSize.height > 0 else { return }
        window.setContentSize(fittingSize)
    }

    private func showFallbackPreferencesWindow() {
        if let window = fallbackPreferencesWindow {
            configurePreferencesWindow(window)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = PreferencesView(coordinator: DockExposeCoordinator.shared,
                                       updateManager: UpdateManager.shared)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize

        let window = NSWindow(
            contentRect: NSRect(origin: .zero,
                                size: NSSize(width: max(fittingSize.width, 1), height: max(fittingSize.height, 1))),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        configurePreferencesWindow(window)
        fallbackPreferencesWindow = window
        window.makeKeyAndOrderFront(nil)
    }
}
