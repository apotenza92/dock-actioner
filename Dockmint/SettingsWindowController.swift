import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private enum WindowMode {
        case onboarding
        case settings

        var title: String {
            switch self {
            case .onboarding: return "\(AppServices.appDisplayName) Setup"
            case .settings: return AppServices.settingsWindowTitle
            }
        }

        var initialFocusButtonTitles: [String] {
            switch self {
            case .onboarding:
                return ["Get Started"]
            case .settings:
                return []
            }
        }
    }

    private static let automationSectionEnvironmentKey = "DOCKMINT_SETTINGS_AUTOMATION_SECTION"
    private static let legacyAutomationSectionEnvironmentKey = "DOCKTOR_SETTINGS_AUTOMATION_SECTION"

    private let preferences: Preferences
    private let coordinator: DockExposeCoordinator
    private let updateManager: UpdateManager
    private let folderOpenWithOptionsStore: FolderOpenWithOptionsStore
    private let viewModel: SettingsWindowViewModel
    private let hostingController: NSHostingController<SettingsRootView>
    private var cancellables: Set<AnyCancellable> = []
    private var pendingOpenSession: SettingsPerformance.Session?
    private var pendingPaneSession: SettingsPerformance.Session?
    private var pendingPaneReady: SettingsPane?
    private var pendingRefit: DispatchWorkItem?
    private var lastRequestedFrame: NSRect?
    private var needsInitialCenter = true
    private var needsInitialSettingsCenter = true
    private var fittedMode: WindowMode?

    init(services: AppServices) {
        preferences = services.preferences
        coordinator = services.coordinator
        updateManager = services.updateManager
        folderOpenWithOptionsStore = services.folderOpenWithOptionsStore
        let model = SettingsWindowViewModel()
        viewModel = model

        hostingController = NSHostingController(rootView: SettingsRootView(
            coordinator: services.coordinator,
            updateManager: services.updateManager,
            preferences: services.preferences,
            folderOpenWithOptionsStore: services.folderOpenWithOptionsStore,
            viewModel: model,
            onPaneAppear: { _ in }
        ))

        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.level = .normal
        super.init(window: window)
        window.delegate = self

        hostingController.rootView = SettingsRootView(
            coordinator: services.coordinator,
            updateManager: services.updateManager,
            preferences: services.preferences,
            folderOpenWithOptionsStore: services.folderOpenWithOptionsStore,
            viewModel: model,
            onPaneAppear: { [weak self] pane in self?.paneDidAppear(pane) },
            onOnboardingFinish: { [weak self] openSettings in
                guard let self else { return }
                if openSettings {
                    self.viewModel.selectedPane = .general
                } else {
                    self.close()
                }
            }
        )

        bindContentChanges()
        applyWindowMode()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var mode: WindowMode {
        preferences.shouldPresentOnboarding ? .onboarding : .settings
    }

    func show(openSession: SettingsPerformance.Session? = nil) {
        guard let window else { return }
        pendingOpenSession = openSession
        pendingPaneReady = preferences.shouldPresentOnboarding ? nil : (automationRequestedPane()?.destination ?? viewModel.selectedPane)

        if window.isMiniaturized { window.deminiaturize(nil) }
        applyWindowMode()
        refitWindow(center: needsInitialCenter)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduleRefit()
            self.applyInitialKeyboardSelection()
            if self.preferences.shouldPresentOnboarding {
                self.pendingOpenSession?.complete(extraMetadata: ["pane": "onboarding"])
                self.pendingOpenSession = nil
            } else if let pane = self.automationRequestedPane() {
                self.selectSection(pane, recordPerformance: true)
            } else {
                self.paneDidAppear(self.viewModel.selectedPane)
            }
        }
    }

    private func bindContentChanges() {
        preferences.$onboardingState
            .map(\.isCompleted)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] completed in
                guard let self else { return }
                if completed { self.viewModel.selectedPane = .general }
                self.applyWindowMode()
                self.scheduleRefit()
            }
            .store(in: &cancellables)

    }

    private func applyWindowMode() {
        guard let window else { return }
        window.title = mode == .settings ? viewModel.selectedPane.destination.title : mode.title
        window.styleMask.remove(.fullSizeContentView)
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .automatic
        if mode == .settings {
            window.styleMask.remove(.resizable)
            window.titleVisibility = .visible
            window.toolbarStyle = .preference
            if window.toolbar == nil {
                let toolbar = NSToolbar(identifier: "DockmintSettingsTabs")
                toolbar.delegate = self
                toolbar.displayMode = .iconAndLabel
                toolbar.allowsUserCustomization = false
                toolbar.autosavesConfiguration = false
                toolbar.centeredItemIdentifiers = Set(SettingsPane.tabs.map { NSToolbarItem.Identifier($0.rawValue) })
                window.toolbar = toolbar
            }
            window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(viewModel.selectedPane.destination.rawValue)
        } else {
            window.styleMask.insert(.resizable)
            window.toolbar = nil
            window.titleVisibility = .visible
            window.toolbarStyle = .automatic
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.tabs.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = SettingsPane(rawValue: itemIdentifier.rawValue),
              SettingsPane.tabs.contains(pane) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.paletteLabel = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(selectToolbarTab(_:))
        return item
    }

    @objc private func selectToolbarTab(_ sender: NSToolbarItem) {
        guard let pane = SettingsPane(rawValue: sender.itemIdentifier.rawValue) else { return }
        selectSection(pane, recordPerformance: true)
    }

    private func scheduleRefit() {
        pendingRefit?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refitWindow(
                center: self.needsInitialCenter
            )
        }
        pendingRefit = work
        // Apply mode constraints on the next run-loop pass.
        DispatchQueue.main.async(execute: work)
    }

    private func refitWindow(center: Bool) {
        guard let window else { return }
        let centerSettingsOnMainDisplay = mode == .settings && needsInitialSettingsCenter
        // The first screen is the primary display. NSScreen.main can instead
        // follow the setup window if the user moved it to another display.
        let screen = centerSettingsOnMainDisplay ? NSScreen.screens.first : targetScreen(for: window)
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let chrome = window.frame.height - window.contentLayoutRect.height
        let maximumContentSize = NSSize(
            width: visibleFrame.width,
            height: max(1, visibleFrame.height - chrome)
        )

        let changingMode = fittedMode != mode
        let contentSize = SettingsWindowSizing.limitedSize(
            NSSize(
                width: mode == .settings
                    ? SettingsLayout.contentSize.width
                    : SettingsLayout.onboardingWidth,
                height: mode == .settings ? SettingsLayout.settingsHeight : SettingsLayout.initialHeight
            ),
            to: maximumContentSize
        )
        var targetFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
        if !changingMode && mode == .onboarding {
            // Keep the user's vertical resize across page changes and reopening.
            targetFrameSize.height = min(window.frame.height, visibleFrame.height)
        }
        fittedMode = mode
        let targetFrame: NSRect
        if center || centerSettingsOnMainDisplay {
            targetFrame = SettingsWindowSizing.centeredFrame(size: targetFrameSize, in: visibleFrame)
        } else {
            targetFrame = SettingsWindowSizing.topLeftAnchoredFrame(
                currentFrame: window.frame,
                targetSize: targetFrameSize,
                visibleFrame: visibleFrame
            )
        }

        window.contentMinSize = NSSize(
            width: contentSize.width,
            height: mode == .settings ? contentSize.height : min(SettingsLayout.minimumHeight, maximumContentSize.height)
        )
        window.contentMaxSize = NSSize(
            width: contentSize.width,
            height: mode == .settings ? contentSize.height : maximumContentSize.height
        )
        if !SettingsWindowSizing.framesApproximatelyEqual(window.frame, targetFrame),
           lastRequestedFrame.map({ !SettingsWindowSizing.framesApproximatelyEqual($0, targetFrame) }) ?? true {
            lastRequestedFrame = targetFrame
            window.setFrame(targetFrame, display: true, animate: false)
        }
        needsInitialCenter = false
        if mode == .settings && window.isVisible {
            needsInitialSettingsCenter = false
        }
    }

    private func targetScreen(for window: NSWindow) -> NSScreen? {
        if window.isVisible, let screen = window.screen { return screen }
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func paneDidAppear(_ pane: SettingsPane) {
        if pane == .general && !preferences.shouldPresentOnboarding {
            window?.defaultButtonCell = nil
            viewModel.generalFocusRequest += 1
        }
        if pane == .folderActions { folderOpenWithOptionsStore.warmIfNeeded() }
        guard pane == pendingPaneReady else { return }
        pendingPaneReady = nil
        pendingPaneSession?.complete(extraMetadata: SettingsPerformance.sectionMetadata(for: pane))
        pendingPaneSession = nil
        pendingOpenSession?.complete(extraMetadata: SettingsPerformance.sectionMetadata(for: pane))
        pendingOpenSession = nil
    }

    private func selectSection(_ requestedPane: SettingsPane, recordPerformance: Bool) {
        let pane = requestedPane.destination
        if recordPerformance {
            pendingPaneSession = SettingsPerformance.begin(.paneSwitch, metadata: SettingsPerformance.sectionMetadata(for: pane))
            pendingPaneReady = pane
        }
        let changed = pane != viewModel.selectedPane
        viewModel.selectedPane = pane.destination
        window?.title = pane.destination.title
        window?.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(pane.destination.rawValue)
        if !changed { DispatchQueue.main.async { [weak self] in self?.paneDidAppear(pane) } }
    }

    private func automationRequestedPane() -> SettingsPane? {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment[Self.automationSectionEnvironmentKey]
            ?? environment[Self.legacyAutomationSectionEnvironmentKey] else { return nil }
        let normalized = raw.replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        return SettingsPane.allCases.first {
            $0.rawValue.lowercased() == normalized || $0.title.replacingOccurrences(of: " ", with: "").lowercased() == normalized
        }
    }

    private func applyInitialKeyboardSelection() {
        guard let window, let contentView = window.contentView else { return }
        guard mode == .onboarding else {
            window.defaultButtonCell = nil
            return
        }
        let button = mode.initialFocusButtonTitles.lazy.compactMap { self.findButton(in: contentView, titled: $0) }.first
        guard let button else { return }
        window.defaultButtonCell = button.cell as? NSButtonCell
    }

    private func findButton(in view: NSView, titled title: String) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { self.findButton(in: $0, titled: title) }.first
    }
}
