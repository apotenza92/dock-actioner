import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private let defaults = UserDefaults.standard
    private let frameDefaultsKey = "settingsWindowFrame"
    private let primaryInitialFocusControlTitle = "Show menu bar icon"
    private let fallbackInitialFocusControlTitle = "Check for Updates"
    private var frameObservers: [NSObjectProtocol] = []

    init(services: AppServices) {
        let view = PreferencesView(
            coordinator: services.coordinator,
            updateManager: services.updateManager,
            preferences: services.preferences
        )
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)

        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "Docktor Settings"
        window.isReleasedWhenClosed = false
        window.level = .normal

        hostingController.view.layoutSubtreeIfNeeded()
        let fittingSize = hostingController.view.fittingSize
        if fittingSize.width > 0, fittingSize.height > 0 {
            window.setContentSize(fittingSize)
            window.minSize = fittingSize
        }

        super.init(window: window)

        if !restoreFrame(for: window) {
            center(window: window)
        }
        observeFrameChanges(for: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.applyInitialKeyboardSelection()
        }
    }

    deinit {
        let center = NotificationCenter.default
        for observer in frameObservers {
            center.removeObserver(observer)
        }
    }

    private func observeFrameChanges(for window: NSWindow) {
        let center = NotificationCenter.default
        frameObservers.append(
            center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.saveFrame(from: window)
                }
            }
        )
        frameObservers.append(
            center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.saveFrame(from: window)
                }
            }
        )
        frameObservers.append(
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.saveFrame(from: window)
                }
            }
        )
    }

    private func saveFrame(from window: NSWindow) {
        defaults.set(NSStringFromRect(window.frame), forKey: frameDefaultsKey)
    }

    private func restoreFrame(for window: NSWindow) -> Bool {
        guard let frameString = defaults.string(forKey: frameDefaultsKey) else {
            return false
        }
        let frame = NSRectFromString(frameString)
        guard frame.width > 0, frame.height > 0, frameIsVisible(frame) else {
            return false
        }
        window.setFrame(frame, display: false)
        return true
    }

    private func frameIsVisible(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { screen in
            screen.visibleFrame.intersects(frame)
        }
    }

    private func center(window: NSWindow) {
        guard let targetScreen = targetScreen() else {
            window.center()
            return
        }
        let visibleFrame = targetScreen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - (window.frame.width / 2),
            y: visibleFrame.midY - (window.frame.height / 2)
        )
        window.setFrameOrigin(origin)
    }

    private func targetScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        if let hoveredScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return hoveredScreen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func applyInitialKeyboardSelection() {
        guard let window, let contentView = window.contentView else { return }
        let button = findButton(in: contentView, titled: primaryInitialFocusControlTitle)
            ?? findButton(in: contentView, titled: fallbackInitialFocusControlTitle)
        guard let button else { return }
        window.defaultButtonCell = button.cell as? NSButtonCell
        window.makeFirstResponder(button)
    }

    private func findButton(in view: NSView, titled title: String) -> NSButton? {
        if let button = view as? NSButton, button.title == title {
            return button
        }
        for subview in view.subviews {
            if let button = findButton(in: subview, titled: title) {
                return button
            }
        }
        return nil
    }
}
