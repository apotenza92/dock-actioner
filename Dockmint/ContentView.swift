import AppKit
import Combine
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case appActions
    case folderActions
    case permissions
    case updates
    case about

    static let tabs: [Self] = [.general, .appActions, .folderActions]

    var destination: Self {
        switch self {
        case .permissions, .updates, .about: return .general
        default: return self
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return "General"
        case .appActions:
            return "App Actions"
        case .folderActions:
            return "Folder Actions"
        case .permissions:
            return "Permissions"
        case .updates:
            return "Updates"
        case .about:
            return "About & Updates"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appActions: return "macwindow.on.rectangle"
        case .folderActions: return "folder"
        case .permissions: return "hand.raised"
        case .updates: return "arrow.triangle.2.circlepath"
        case .about: return "info.circle"
        }
    }

}

@MainActor
final class SettingsWindowViewModel: ObservableObject {
    @Published var selectedPane: SettingsPane = .general
    @Published var generalFocusRequest = 0
}

struct PreferencesView: View {
    @ObservedObject var coordinator: DockExposeCoordinator
    @ObservedObject var updateManager: UpdateManager
    @ObservedObject var preferences: Preferences
    @ObservedObject var folderOpenWithOptionsStore: FolderOpenWithOptionsStore
    @ObservedObject var viewModel: SettingsWindowViewModel
    let onPaneAppear: (SettingsPane) -> Void

    @FocusState private var menuBarIconFocused: Bool

    private let appDisplayName = AppServices.appDisplayName
    private var suggestedMouseScrollTool: MouseScrollDirectionTool? {
        MouseScrollDirectionToolDetector.detectedTools().first { tool in
            preferences.shouldSuggestReverseMouseScrollAfterOnboarding(for: tool)
        }
    }

    private enum MappingSource: CaseIterable, Hashable {
        case click
        case scrollUp
        case scrollDown

        var appExposeSlotSource: AppExposeSlotSource {
            switch self {
            case .click:
                return .click
            case .scrollUp:
                return .scrollUp
            case .scrollDown:
                return .scrollDown
            }
        }

        var title: String {
            switch self {
            case .click:
                return "Click"
            case .scrollUp:
                return "Scroll Up"
            case .scrollDown:
                return "Scroll Down"
            }
        }
    }

    private enum MappingModifier: CaseIterable, Hashable, Identifiable {
        var id: Self { self }
        case none
        case shift
        case option
        case shiftOption

        var title: String {
            switch self {
            case .none:
                return "No Modifier"
            case .shift:
                return "Shift (⇧)"
            case .option:
                return "Option (⌥)"
            case .shiftOption:
                return "Shift + Option (⇧ + ⌥)"
            }
        }

        var symbol: String {
            switch self {
            case .none:
                return "circle.slash"
            case .shift:
                return "shift"
            case .option:
                return "option"
            case .shiftOption:
                return "plus"
            }
        }

        var appExposeSlotModifier: AppExposeSlotModifier {
            switch self {
            case .none:
                return .none
            case .shift:
                return .shift
            case .option:
                return .option
            case .shiftOption:
                return .shiftOption
            }
        }
    }

    private enum ActionMenuOption: String, CaseIterable, Hashable {
        case none
        case activateApp
        case hideApp
        case appExpose
        case appExposeMultiple
        case minimizeAll
        case quitApp
        case hideOthers
        case singleAppMode

        var displayName: String {
            switch self {
            case .none:
                return "-"
            case .activateApp:
                return "Activate App"
            case .hideApp:
                return "Hide App"
            case .appExpose:
                return "App Exposé"
            case .appExposeMultiple:
                return "App Exposé (>1 window only)"
            case .minimizeAll:
                return "Minimize All"
            case .quitApp:
                return "Quit App"
            case .hideOthers:
                return "Hide Others"
            case .singleAppMode:
                return "Hide Current, Activate Clicked"
            }
        }

        static func from(action: DockAction, requiresMultipleWindows: Bool) -> ActionMenuOption {
            if action == .appExpose {
                return requiresMultipleWindows ? .appExposeMultiple : .appExpose
            }
            return ActionMenuOption(rawValue: action.rawValue) ?? .none
        }
    }

    private enum FirstClickMenuOption: String, CaseIterable, Hashable {
        case activateApp
        case appExpose
        case appExposeMultiple

        var displayName: String {
            switch self {
            case .activateApp:
                return "Activate App"
            case .appExpose:
                return "App Exposé"
            case .appExposeMultiple:
                return "App Exposé (>1 window only)"
            }
        }

        static func from(behavior: FirstClickBehavior, requiresMultipleWindows: Bool) -> FirstClickMenuOption {
            if behavior == .appExpose {
                return requiresMultipleWindows ? .appExposeMultiple : .appExpose
            }
            return FirstClickMenuOption(rawValue: behavior.rawValue) ?? .activateApp
        }
    }

    var body: some View {
        selectedPane
            .id(viewModel.selectedPane.destination)
            .onAppear { reportPaneReady(viewModel.selectedPane.destination) }
            .onChange(of: viewModel.selectedPane) { _, pane in reportPaneReady(pane.destination) }
            .onChange(of: viewModel.generalFocusRequest) {
                menuBarIconFocused = viewModel.selectedPane.destination == .general
            }
    }

    @ViewBuilder
    private var selectedPane: some View {
        switch viewModel.selectedPane.destination {
        case .appActions:
            appActionsPane
        case .folderActions:
            folderActionsPane
        default:
            generalPane
        }
    }

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Behavior").foregroundStyle(.secondary)
                    Toggle("Show menu bar icon", isOn: $preferences.showMenuBarIcon)
                        .focused($menuBarIconFocused)
                    Toggle("Open at login", isOn: $preferences.startAtLogin)
                        .disabled(!AppIdentity.supportsLoginItem)
                    Toggle("Reverse mouse scrolling", isOn: $preferences.reverseMouseScrollActions)
                        .help(mouseScrollHelp)
                    Toggle("Save diagnostic logs", isOn: $preferences.persistentDiagnosticFileLoggingEnabled)
                        .help("Save logs to help troubleshoot problems.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Permissions").foregroundStyle(.secondary)
                    permissionButton(.accessibility, granted: coordinator.accessibilityGranted)
                    permissionButton(.inputMonitoring, granted: coordinator.inputMonitoringGranted)
                    Text(permissionStatusText)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Updates").foregroundStyle(.secondary)
                    Toggle("Automatic checks", isOn: $preferences.backgroundUpdateChecksEnabled)
                        .disabled(!AppIdentity.supportsUpdates)
                    Picker("Update frequency", selection: $preferences.updateCheckFrequency) {
                        ForEach(UpdateCheckFrequency.allCases.filter { $0 != .never }) { frequency in
                            Text(frequency.displayName).tag(frequency)
                        }
                    }
                    .labelsHidden()
                    .disabled(!AppIdentity.supportsUpdates || !preferences.backgroundUpdateChecksEnabled)
                    Button("Check for Updates", action: updateManager.checkForUpdates)
                        .disabled(!AppIdentity.supportsUpdates || !updateManager.canCheckForUpdates)
                    if !AppIdentity.isDevelopmentIdentity {
                        Text(updateManager.updateStatusText)
                            .lineLimit(1)
                            .help(updateManager.updateStatusText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Text("\(appDisplayName) · \(updateManager.currentVersionText)")
                Spacer()
                Button("GitHub", action: openGitHubPage)
                Button("Restart", action: restartApp)
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .font(.body)
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .accessibilityIdentifier("settings-section-general")
        .onAppear { coordinator.refreshPermissionsAfterExternalChange() }
    }

    private var mouseScrollHelp: String {
        if let tool = suggestedMouseScrollTool {
            return "Detected \(tool.displayName). Turn this on if it reverses mouse scrolling. Trackpad gestures are unchanged."
        }
        return "Reverse Dock actions for the mouse. Trackpad gestures are unchanged."
    }

    private func permissionButton(_ permission: DockmintPermission, granted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .accessibilityLabel(granted ? "Granted" : "Required")
            Button(permission.title) { coordinator.requestPermissionFromUser(permission) }
                .help("Open \(permission.title) in System Settings")
        }
    }

    private var permissionStatusText: String {
        switch (coordinator.accessibilityGranted, coordinator.inputMonitoringGranted) {
        case (true, true): return "Both permissions granted."
        case (false, true): return "\(DockmintPermission.accessibility.title) required."
        case (true, false): return "Input Monitoring required."
        case (false, false): return "Both permissions required."
        }
    }

    private var appActionsPane: some View {
        VStack(spacing: 0) {
            Table(MappingModifier.allCases) {
                TableColumn("Modifier") { modifier in Text(modifier.title) }
                    .width(SettingsLayout.actionModifierColumnWidth)
                TableColumn("Click") { modifier in
                    appActionFirstClickCell(for: modifier)
                        .accessibilityLabel("\(modifier.title), Click")
                }
                .width(SettingsLayout.actionColumnWidth)
                TableColumn("Scroll Up") { modifier in
                    appActionCell(actionMenuBinding(source: .scrollUp, modifier: modifier))
                        .accessibilityLabel("\(modifier.title), Scroll Up")
                }
                .width(SettingsLayout.actionColumnWidth)
                TableColumn("Scroll Down") { modifier in
                    appActionCell(actionMenuBinding(source: .scrollDown, modifier: modifier))
                        .accessibilityLabel("\(modifier.title), Scroll Down")
                }
                .width(SettingsLayout.actionColumnWidth)
            }
            .tableStyle(.automatic)
            .scrollIndicators(.hidden)
            HStack {
                Button("Reset App Actions", action: preferences.resetAppActionsToDefaults)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .accessibilityIdentifier("settings-section-app-actions")
    }

    private var folderActionsPane: some View {
        VStack(spacing: 0) {
            Table(MappingModifier.allCases) {
                TableColumn("Modifier") { modifier in Text(modifier.title) }
                    .width(SettingsLayout.actionModifierColumnWidth)
                TableColumn("Click") { modifier in
                    folderActionCell(source: .click, modifier: modifier)
                        .accessibilityLabel("\(modifier.title), Click")
                }
                .width(SettingsLayout.actionColumnWidth)
                TableColumn("Scroll Up") { modifier in
                    folderActionCell(source: .scrollUp, modifier: modifier)
                        .accessibilityLabel("\(modifier.title), Scroll Up")
                }
                .width(SettingsLayout.actionColumnWidth)
                TableColumn("Scroll Down") { modifier in
                    folderActionCell(source: .scrollDown, modifier: modifier)
                        .accessibilityLabel("\(modifier.title), Scroll Down")
                }
                .width(SettingsLayout.actionColumnWidth)
            }
            .tableStyle(.automatic)
            .scrollIndicators(.hidden)
            HStack {
                Button("Reset Folder Actions", action: preferences.resetFolderActionsToDefaults)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .accessibilityIdentifier("settings-section-folder-actions")
        .onAppear { folderOpenWithOptionsStore.warmIfNeeded() }
    }

    private func reportPaneReady(_ pane: SettingsPane) {
        DispatchQueue.main.async { onPaneAppear(pane) }
    }

    private func appActionFirstClickCell(for modifier: MappingModifier) -> some View {
        Group {
            if modifier == .none {
                Picker("Click", selection: firstClickBehaviorMenuBinding()) {
                    ForEach(FirstClickMenuOption.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            } else {
                Picker("Click", selection: firstClickActionMenuBinding(for: modifier)) {
                    ForEach(ActionMenuOption.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    private func appActionCell(_ selection: Binding<ActionMenuOption>) -> some View {
        Picker("Action", selection: selection) {
            ForEach(ActionMenuOption.allCases, id: \.self) { option in
                Text(option.displayName).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    private func folderActionCell(source: MappingSource, modifier: MappingModifier) -> some View {
        let configuration = folderMappingBinding(source: source, modifier: modifier).wrappedValue
        let options = folderOpenWithOptionsStore.options(including: configuration.openInApplicationIdentifier)
        return Picker(source.title, selection: folderOpenInBinding(source: source, modifier: modifier)) {
            ForEach(options, id: \.identifier) { option in
                Text(option.displayName).tag(option.identifier)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .disabled(!folderOpenWithOptionsStore.isReady)
    }

    private func appExposeRequiresMultipleBinding(source: MappingSource, modifier: MappingModifier) -> Binding<Bool> {
        if source == .click && modifier == .none {
            return $preferences.clickAppExposeRequiresMultipleWindows
        }
        return preferences.appExposeMultipleWindowsBinding(slot: slotKey(for: source, modifier: modifier))
    }

    private func firstClickAppExposeRequiresMultipleBinding(for modifier: MappingModifier) -> Binding<Bool> {
        if modifier == .none {
            return $preferences.firstClickAppExposeRequiresMultipleWindows
        }
        return preferences.appExposeMultipleWindowsBinding(slot: firstClickSlotKey(for: modifier))
    }

    private func slotKey(for source: MappingSource, modifier: MappingModifier) -> String {
        AppExposeSlotKey.make(source: source.appExposeSlotSource, modifier: modifier.appExposeSlotModifier)
    }

    private func firstClickSlotKey(for modifier: MappingModifier) -> String {
        AppExposeSlotKey.make(source: .firstClick, modifier: modifier.appExposeSlotModifier)
    }

    private func actionMenuBinding(source: MappingSource, modifier: MappingModifier) -> Binding<ActionMenuOption> {
        let action = mappingBinding(source: source, modifier: modifier)
        let requiresMultiple = appExposeRequiresMultipleBinding(source: source, modifier: modifier)
        return Binding(
            get: { ActionMenuOption.from(action: action.wrappedValue, requiresMultipleWindows: requiresMultiple.wrappedValue) },
            set: { option in
                switch option {
                case .appExpose:
                    action.wrappedValue = .appExpose
                    requiresMultiple.wrappedValue = false
                case .appExposeMultiple:
                    action.wrappedValue = .appExpose
                    requiresMultiple.wrappedValue = true
                default:
                    action.wrappedValue = DockAction(rawValue: option.rawValue) ?? .none
                }
            }
        )
    }

    private func firstClickActionMenuBinding(for modifier: MappingModifier) -> Binding<ActionMenuOption> {
        let action = firstClickActionBinding(for: modifier)
        let requiresMultiple = firstClickAppExposeRequiresMultipleBinding(for: modifier)
        return Binding(
            get: { ActionMenuOption.from(action: action.wrappedValue, requiresMultipleWindows: requiresMultiple.wrappedValue) },
            set: { option in
                switch option {
                case .appExpose:
                    action.wrappedValue = .appExpose
                    requiresMultiple.wrappedValue = false
                case .appExposeMultiple:
                    action.wrappedValue = .appExpose
                    requiresMultiple.wrappedValue = true
                default:
                    action.wrappedValue = DockAction(rawValue: option.rawValue) ?? .none
                }
            }
        )
    }

    private func firstClickBehaviorMenuBinding() -> Binding<FirstClickMenuOption> {
        Binding(
            get: {
                FirstClickMenuOption.from(
                    behavior: preferences.firstClickBehavior,
                    requiresMultipleWindows: preferences.firstClickAppExposeRequiresMultipleWindows
                )
            },
            set: { option in
                switch option {
                case .activateApp:
                    preferences.firstClickBehavior = .activateApp
                case .appExpose:
                    preferences.firstClickBehavior = .appExpose
                    preferences.firstClickAppExposeRequiresMultipleWindows = false
                case .appExposeMultiple:
                    preferences.firstClickBehavior = .appExpose
                    preferences.firstClickAppExposeRequiresMultipleWindows = true
                }
            }
        )
    }

    private func folderOpenInBinding(source: MappingSource, modifier: MappingModifier) -> Binding<String> {
        let action = folderMappingBinding(source: source, modifier: modifier)
        return Binding(
            get: { action.wrappedValue.openInApplicationIdentifier },
            set: { openInApplicationIdentifier in
                let normalizedIdentifier = DockFolderOpenApplicationCatalog.normalize(openInApplicationIdentifier)
                if normalizedIdentifier == DockFolderOpenApplicationCatalog.noneIdentifier {
                    action.wrappedValue = .none
                } else {
                    var updated = DockFolderAction.none
                    updated.openInApplicationIdentifier = normalizedIdentifier
                    action.wrappedValue = updated
                }
            }
        )
    }

    private func firstClickActionBinding(for modifier: MappingModifier) -> Binding<DockAction> {
        switch modifier {
        case .shift:
            return $preferences.firstClickShiftAction
        case .option:
            return $preferences.firstClickOptionAction
        case .shiftOption:
            return $preferences.firstClickShiftOptionAction
        case .none:
            return .constant(.none)
        }
    }

    private func mappingBinding(source: MappingSource, modifier: MappingModifier) -> Binding<DockAction> {
        switch (source, modifier) {
        case (.click, .none):
            return $preferences.clickAction
        case (.click, .shift):
            return $preferences.shiftClickAction
        case (.click, .option):
            return $preferences.optionClickAction
        case (.click, .shiftOption):
            return $preferences.shiftOptionClickAction
        case (.scrollUp, .none):
            return $preferences.scrollUpAction
        case (.scrollUp, .shift):
            return $preferences.shiftScrollUpAction
        case (.scrollUp, .option):
            return $preferences.optionScrollUpAction
        case (.scrollUp, .shiftOption):
            return $preferences.shiftOptionScrollUpAction
        case (.scrollDown, .none):
            return $preferences.scrollDownAction
        case (.scrollDown, .shift):
            return $preferences.shiftScrollDownAction
        case (.scrollDown, .option):
            return $preferences.optionScrollDownAction
        case (.scrollDown, .shiftOption):
            return $preferences.shiftOptionScrollDownAction
        }
    }

    private func folderMappingBinding(source: MappingSource, modifier: MappingModifier) -> Binding<DockFolderAction> {
        switch (source, modifier) {
        case (.click, .none):
            return $preferences.folderClickAction
        case (.click, .shift):
            return $preferences.shiftFolderClickAction
        case (.click, .option):
            return $preferences.optionFolderClickAction
        case (.click, .shiftOption):
            return $preferences.shiftOptionFolderClickAction
        case (.scrollUp, .none):
            return $preferences.folderScrollUpAction
        case (.scrollUp, .shift):
            return $preferences.shiftFolderScrollUpAction
        case (.scrollUp, .option):
            return $preferences.optionFolderScrollUpAction
        case (.scrollUp, .shiftOption):
            return $preferences.shiftOptionFolderScrollUpAction
        case (.scrollDown, .none):
            return $preferences.folderScrollDownAction
        case (.scrollDown, .shift):
            return $preferences.shiftFolderScrollDownAction
        case (.scrollDown, .option):
            return $preferences.optionFolderScrollDownAction
        case (.scrollDown, .shiftOption):
            return $preferences.shiftOptionFolderScrollDownAction
        }
    }

    private func restartApp() {
        let bundleURL = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundleURL.path]
        do {
            try task.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        } catch {
            Logger.log("Failed to relaunch app: \(error.localizedDescription)")
        }
    }

    private func openGitHubPage() {
        guard let url = URL(string: "https://github.com/apotenza92/dockmint") else { return }
        NSWorkspace.shared.open(url)
    }
}

#Preview("Settings Window") {
    PreferencesView(
        coordinator: AppServices.live.coordinator,
        updateManager: AppServices.live.updateManager,
        preferences: AppServices.live.preferences,
        folderOpenWithOptionsStore: AppServices.live.folderOpenWithOptionsStore,
        viewModel: SettingsWindowViewModel(),
        onPaneAppear: { _ in }
    )
}
