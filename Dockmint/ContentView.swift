import AppKit
import Combine
import SwiftUI

private enum SettingsLayout {
    static let windowPadding: CGFloat = 14
    static let sidebarWidth: CGFloat = 156
    static let tableCardPadding: CGFloat = 14
    static let pickerWidth: CGFloat = 172
    static let paneHeaderSpacing: CGFloat = 12
    static let rowSpacing: CGFloat = 10
    static let columnSpacing: CGFloat = 14
    static let formRowSpacing: CGFloat = 8
    static let tableCellSpacing: CGFloat = 12
    static let actionModifierColumnWidth: CGFloat = 144
    static let actionColumnWidth: CGFloat = 172
    static let appActionsCardWidth: CGFloat =
        actionModifierColumnWidth +
        (actionColumnWidth * 3) +
        (tableCellSpacing * 3) +
        (tableCardPadding * 2)
    static let windowContentWidth: CGFloat = appActionsCardWidth
    static let generalColumnWidth: CGFloat = 236
    static let updatesColumnWidth: CGFloat = 240
    static let permissionsColumnWidth: CGFloat =
        windowContentWidth - generalColumnWidth - updatesColumnWidth - (columnSpacing * 2)
    static let generalContentWidth: CGFloat = windowContentWidth
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case appActions
    case folderActions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return "General"
        case .appActions:
            return "App Actions"
        case .folderActions:
            return "Folder Actions"
        }
    }

}

@MainActor
final class SettingsWindowViewModel: ObservableObject {
    @Published var selectedPane: SettingsPane = .general
}

private struct PopUpPickerOption<Value: Hashable> {
    let value: Value
    let title: String
}

private struct FullWidthPopUpPicker<Value: Hashable>: NSViewRepresentable {
    let options: [PopUpPickerOption<Value>]
    @Binding var selection: Value
    let isEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.bezelStyle = .rounded
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection

        let currentTitles = button.itemTitles
        let expectedTitles = options.map(\.title)
        if currentTitles != expectedTitles {
            button.removeAllItems()
            for option in options {
                button.addItem(withTitle: option.title)
            }
        }

        context.coordinator.options = options.map(\.value)
        if let selectedIndex = options.firstIndex(where: { $0.value == selection }) {
            button.selectItem(at: selectedIndex)
        }
        button.isEnabled = isEnabled
    }

    final class Coordinator: NSObject {
        var selection: Binding<Value>
        var options: [Value] = []

        init(selection: Binding<Value>) {
            self.selection = selection
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard options.indices.contains(index) else { return }
            selection.wrappedValue = options[index]
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var coordinator: DockExposeCoordinator
    @ObservedObject var updateManager: UpdateManager
    @ObservedObject var preferences: Preferences
    @ObservedObject var folderOpenWithOptionsStore: FolderOpenWithOptionsStore
    @ObservedObject var viewModel: SettingsWindowViewModel
    let onPaneAppear: (SettingsPane) -> Void
    let onPaneSelectionRequest: (SettingsPane) -> Void

    private let appDisplayName = AppServices.appDisplayName
    private var loginItemAvailable: Bool {
        AppIdentity.supportsLoginItem
    }

    private var updatesAvailable: Bool {
        AppIdentity.supportsUpdates
    }

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

    private enum MappingModifier: CaseIterable, Hashable {
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
        NavigationSplitView {
            List(SettingsPane.allCases, selection: paneSelection) { pane in
                Text(pane.title)
                    .tag(pane)
                    .accessibilityIdentifier("settings-sidebar-\(pane.rawValue)")
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(
                min: SettingsLayout.sidebarWidth,
                ideal: SettingsLayout.sidebarWidth,
                max: SettingsLayout.sidebarWidth
            )
        } detail: {
            selectedPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            reportPaneReady(viewModel.selectedPane)
        }
        .onChange(of: viewModel.selectedPane) { pane in
            reportPaneReady(pane)
        }
    }

    private var paneSelection: Binding<SettingsPane?> {
        Binding(
            get: { viewModel.selectedPane },
            set: { pane in
                guard let pane else { return }
                onPaneSelectionRequest(pane)
            }
        )
    }

    @ViewBuilder
    private var selectedPane: some View {
        switch viewModel.selectedPane {
        case .general:
            generalPane
        case .appActions:
            appActionsPane
        case .folderActions:
            folderActionsPane
        }
    }

    private var generalPane: some View {
        generalOverviewSection
            .frame(width: SettingsLayout.generalContentWidth, alignment: .topLeading)
            .accessibilityIdentifier("settings-section-general")
            .accessibilityLabel("General Section")
            .frame(width: SettingsLayout.windowContentWidth, alignment: .topLeading)
            .padding(SettingsLayout.windowPadding)
    }

    private var generalOverviewSection: some View {
        HStack(alignment: .top, spacing: SettingsLayout.columnSpacing) {
            generalSettingsGroup
                .frame(width: SettingsLayout.generalColumnWidth, alignment: .topLeading)

            updatesSettingsGroup
                .frame(width: SettingsLayout.updatesColumnWidth, alignment: .topLeading)

            permissionsSettingsGroup
                .frame(width: SettingsLayout.permissionsColumnWidth, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var generalSettingsGroup: some View {
        SettingsGroup(title: "General") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Show menu bar icon", isOn: $preferences.showMenuBarIcon)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 8) {
                        Toggle("Reverse mouse scroll direction", isOn: $preferences.reverseMouseScrollActions)

                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .help("Enable this if mouse-only scroll tools such as LinearMouse, Mos, or UnnaturalScrollWheels make Dockmint's Scroll Up and Scroll Down actions backwards. Trackpad and other continuous scrolling gestures keep following macOS behavior.")
                    }

                    if let tool = suggestedMouseScrollTool {
                        mouseScrollToolSuggestion(for: tool)
                    }
                }

                if loginItemAvailable {
                    Toggle("Start \(appDisplayName) at login", isOn: $preferences.startAtLogin)
                } else if !AppIdentity.isDevelopmentIdentity {
                    Text("Start at Login unavailable")
                        .font(.body.weight(.medium))
                }

                Toggle(
                    "Save diagnostic logs",
                    isOn: $preferences.persistentDiagnosticFileLoggingEnabled
                )

                HStack(spacing: 8) {
                    applicationButtons
                }
                .padding(.top, 4)
            }
        }
    }

    private func mouseScrollToolSuggestion(for tool: MouseScrollDirectionTool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Detected \(tool.displayName). If you use it or a similar app to reverse your mouse's scrolling direction, turn this on so Dockmint's Scroll Up and Scroll Down actions match your mouse.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Turn On") {
                    preferences.enableReverseMouseScrollActionsFromSuggestion(for: tool)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Not Now") {
                    preferences.dismissMouseScrollToolSuggestion(for: tool)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var updatesSettingsGroup: some View {
        SettingsGroup(title: "Updates") {
            VStack(alignment: .leading, spacing: 12) {
                Button("Check for Updates", action: updateManager.checkForUpdates)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!updatesAvailable || !updateManager.canCheckForUpdates)

                Toggle("Enable background update checks", isOn: $preferences.backgroundUpdateChecksEnabled)
                    .disabled(!updatesAvailable)

                if !updatesAvailable && !AppIdentity.isDevelopmentIdentity {
                    Text("Update unavailable")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if updatesAvailable && preferences.backgroundUpdateChecksEnabled {
                    HStack(alignment: .center, spacing: SettingsLayout.formRowSpacing) {
                        Text("Check")
                            .foregroundStyle(.secondary)

                        Picker("", selection: $preferences.updateCheckFrequency) {
                            ForEach(UpdateCheckFrequency.allCases.filter { $0 != .never }) { frequency in
                                Text(frequency.displayName).tag(frequency)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: SettingsLayout.pickerWidth, alignment: .leading)
                    }
                } else if updatesAvailable {
                    Text("Background checks are off until you opt in. Manual update checks remain available.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(updateManager.currentVersionText)
                    if !AppIdentity.isDevelopmentIdentity {
                        Text(updateManager.updateStatusText)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var permissionsSettingsGroup: some View {
        SettingsGroup(title: "Permissions") {
            SharedPermissionsSection(
                coordinator: coordinator,
                footerText: permissionsStatusNote
            )
        }
    }

    private var permissionsStatusNote: String? {
        var missing: [String] = []
        if !coordinator.accessibilityGranted {
            missing.append(DockmintPermission.accessibility.title)
        }
        if !coordinator.inputMonitoringGranted {
            missing.append("Input Monitoring")
        }

        guard !missing.isEmpty else { return nil }
        return "\(missing.joined(separator: " and ")) permission\(missing.count == 1 ? " is" : "s are") not enabled."
    }

    private var appActionsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneSectionHeader(
                title: "App Actions",
                description: "Choose what happens when you click or scroll on app icons in the Dock.",
                buttonTitle: "Reset App Actions",
                action: preferences.resetAppActionsToDefaults
            )

            appActionsTable
        }
        .accessibilityIdentifier("settings-section-app-actions")
        .accessibilityLabel("App Actions Section")
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(width: SettingsLayout.windowContentWidth, alignment: .topLeading)
        .padding(SettingsLayout.windowPadding)
    }

    private var folderActionsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneSectionHeader(
                title: "Folder Actions",
                description: "Choose what happens when you click or scroll on folder stacks in the Dock.",
                buttonTitle: "Reset Folder Actions",
                action: preferences.resetFolderActionsToDefaults
            )

            folderActionsTables
        }
        .accessibilityIdentifier("settings-section-folder-actions")
        .accessibilityLabel("Folder Actions Section")
        .frame(width: SettingsLayout.windowContentWidth, alignment: .topLeading)
        .padding(SettingsLayout.windowPadding)
        .onAppear {
            folderOpenWithOptionsStore.warmIfNeeded()
        }
    }

    private var applicationButtons: some View {
        Group {
            Button("Restart", action: restartApp)
            Button("Quit") { NSApp.terminate(nil) }
            Button("About", action: showAboutPanel)
            Button(action: openGitHubPage) {
                Image("GitHubMark")
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 14, height: 14)
            }
            .help("Open \(appDisplayName) on GitHub")
        }
        .buttonStyle(.bordered)
    }

    private func reportPaneReady(_ pane: SettingsPane) {
        DispatchQueue.main.async {
            onPaneAppear(pane)
        }
    }

    private func paneSectionHeader(
        title: String,
        description: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))

            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: SettingsLayout.columnSpacing)

            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
        }
        .padding(.bottom, SettingsLayout.paneHeaderSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appActionsTable: some View {
        settingsTableCard {
            Grid(alignment: .leading, horizontalSpacing: SettingsLayout.tableCellSpacing, verticalSpacing: SettingsLayout.rowSpacing) {
                GridRow {
                    tableHeaderCell("Modifier", width: SettingsLayout.actionModifierColumnWidth)
                    tableHeaderCell("Click", width: SettingsLayout.actionColumnWidth)
                    tableHeaderCell("Scroll Up", width: SettingsLayout.actionColumnWidth)
                    tableHeaderCell("Scroll Down", width: SettingsLayout.actionColumnWidth)
                }

                tableDivider(columns: 4)

                ForEach(Array(MappingModifier.allCases.enumerated()), id: \.element) { index, modifier in
                    GridRow(alignment: .center) {
                        tableLeadingCell(modifier.title, width: SettingsLayout.actionModifierColumnWidth)
                        appActionFirstClickCell(for: modifier)
                        appActionCell(actionMenuBinding(source: .scrollUp, modifier: modifier))
                        appActionCell(actionMenuBinding(source: .scrollDown, modifier: modifier))
                    }

                    if index < MappingModifier.allCases.count - 1 {
                        tableDivider(columns: 4)
                    }
                }
            }
        }
    }

    private var folderActionsTables: some View {
        settingsTableCard {
            Grid(alignment: .leading, horizontalSpacing: SettingsLayout.tableCellSpacing, verticalSpacing: SettingsLayout.rowSpacing) {
                GridRow {
                    tableHeaderCell("Modifier", width: SettingsLayout.actionModifierColumnWidth)
                    tableHeaderCell("Click", width: SettingsLayout.actionColumnWidth)
                    tableHeaderCell("Scroll Up", width: SettingsLayout.actionColumnWidth)
                    tableHeaderCell("Scroll Down", width: SettingsLayout.actionColumnWidth)
                }

                tableDivider(columns: 4)

                ForEach(Array(MappingModifier.allCases.enumerated()), id: \.element) { index, modifier in
                    GridRow(alignment: .center) {
                        tableLeadingCell(modifier.title, width: SettingsLayout.actionModifierColumnWidth)
                        folderActionCell(source: .click, modifier: modifier)
                        folderActionCell(source: .scrollUp, modifier: modifier)
                        folderActionCell(source: .scrollDown, modifier: modifier)
                    }

                    if index < MappingModifier.allCases.count - 1 {
                        tableDivider(columns: 4)
                    }
                }
            }
        }
    }

    private func settingsTableCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: SettingsLayout.rowSpacing) {
            content()
        }
        .padding(SettingsLayout.tableCardPadding)
    }

    private func tableHeaderCell(_ title: String, width: CGFloat? = nil) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .frame(width: width, alignment: .leading)
    }

    private func tableLeadingCell(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.body.weight(title.isEmpty ? .regular : .semibold))
            .foregroundStyle(title.isEmpty ? .clear : .primary)
            .frame(width: width, alignment: .leading)
            .accessibilityHidden(title.isEmpty)
    }

    private func tableDivider(columns: Int) -> some View {
        Divider()
            .gridCellColumns(columns)
    }
    private func appActionFirstClickCell(for modifier: MappingModifier) -> some View {
        Group {
            if modifier == .none {
                Picker("", selection: firstClickBehaviorMenuBinding()) {
                    ForEach(FirstClickMenuOption.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            } else {
                Picker("", selection: firstClickActionMenuBinding(for: modifier)) {
                    ForEach(ActionMenuOption.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: SettingsLayout.actionColumnWidth, alignment: .leading)
    }

    private func appActionCell(_ selection: Binding<ActionMenuOption>) -> some View {
        Picker("", selection: selection) {
            ForEach(ActionMenuOption.allCases, id: \.self) { option in
                Text(option.displayName).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: SettingsLayout.actionColumnWidth, alignment: .leading)
    }

    private func folderActionCell(source: MappingSource, modifier: MappingModifier) -> some View {
        let configuration = folderMappingBinding(source: source, modifier: modifier).wrappedValue
        let options = folderOpenWithOptionsStore.options(including: configuration.openInApplicationIdentifier)

        return FullWidthPopUpPicker(
            options: options.map { PopUpPickerOption(value: $0.identifier, title: $0.displayName) },
            selection: folderOpenInBinding(source: source, modifier: modifier),
            isEnabled: folderOpenWithOptionsStore.isReady
        )
        .frame(width: SettingsLayout.actionColumnWidth, alignment: .leading)
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

    private func showAboutPanel() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    private func openGitHubPage() {
        guard let url = URL(string: "https://github.com/apotenza92/dockmint") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview("Settings Window") {
    PreferencesView(
        coordinator: AppServices.live.coordinator,
        updateManager: AppServices.live.updateManager,
        preferences: AppServices.live.preferences,
        folderOpenWithOptionsStore: AppServices.live.folderOpenWithOptionsStore,
        viewModel: SettingsWindowViewModel(),
        onPaneAppear: { _ in },
        onPaneSelectionRequest: { _ in }
    )
}
