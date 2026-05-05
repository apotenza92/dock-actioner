import AppKit
import Combine
import SwiftUI

private enum SettingsLayout {
    static let windowPadding: CGFloat = 14
    static let tableCardPadding: CGFloat = 14
    static let pickerWidth: CGFloat = 172
    static let generalBottomInset: CGFloat = 100
    static let paneHeaderSpacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 16
    static let rowSpacing: CGFloat = 10
    static let columnSpacing: CGFloat = 14
    static let updatesLeadingInset: CGFloat = 10
    static let formRowSpacing: CGFloat = 8
    static let tableCornerRadius: CGFloat = 12
    static let tableCellSpacing: CGFloat = 12
    static let actionModifierColumnWidth: CGFloat = 144
    static let actionColumnWidth: CGFloat = 172
    static let folderModifierColumnWidth: CGFloat = 128
    static let folderGestureColumnWidth: CGFloat = 96
    static let folderOpenWithColumnWidth: CGFloat = 134
    static let folderDetailControlWidth: CGFloat = 132
    static let folderDetailLabelWidth: CGFloat = 36
    static let folderDetailInlineSpacing: CGFloat = 4
    static let folderDetailPickerWidth: CGFloat = 134
    static let appActionsCardWidth: CGFloat =
        actionModifierColumnWidth +
        (actionColumnWidth * 3) +
        (tableCellSpacing * 3) +
        (tableCardPadding * 2)
    static let folderOptionsPreferredWidth: CGFloat =
        ((folderDetailLabelWidth + folderDetailInlineSpacing + folderDetailPickerWidth) * 3) +
        (tableCellSpacing * 2)
    static let folderActionsCardWidth: CGFloat =
        folderGestureColumnWidth +
        folderOpenWithColumnWidth +
        folderOptionsPreferredWidth +
        (tableCellSpacing * 2) +
        (tableCardPadding * 2)
    static let windowContentWidth: CGFloat =
        max(appActionsCardWidth, folderActionsCardWidth)
    static let generalColumnWidth: CGFloat = 236
    static let updatesColumnWidth: CGFloat = 280
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

    var symbolName: String {
        switch self {
        case .general:
            return "gearshape"
        case .appActions:
            return "cursorarrow.click.2"
        case .folderActions:
            return "folder"
        }
    }

    var windowFrameSize: NSSize {
        switch self {
        case .general, .appActions, .folderActions:
            return NSSize(width: 873, height: 560)
        }
    }
}

@MainActor
final class SettingsWindowViewModel: ObservableObject {
    @Published var selectedPane: SettingsPane = .general
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
    private static let automationSectionNavigationEnabled: Bool = {
        AppIdentity.boolFlag(primary: "DOCKMINT_TEST_SUITE", legacy: "DOCKTOR_TEST_SUITE") ||
        AppIdentity.boolFlag(primary: "DOCKMINT_SETTINGS_PERF", legacy: "DOCKTOR_SETTINGS_PERF")
    }()

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

    private enum FolderActionDetailField: Hashable {
        case finderView
        case finderGroupBy
        case finderSortBy
        case dockSortBy
        case dockDisplayAs
        case dockViewContentAs

        var title: String {
            switch self {
            case .finderView:
                return "View"
            case .finderGroupBy:
                return "Group"
            case .finderSortBy:
                return "Sort"
            case .dockSortBy:
                return "Sort"
            case .dockDisplayAs:
                return "Display"
            case .dockViewContentAs:
                return "Content"
            }
        }
    }

    var body: some View {
        singlePagePane
    }

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                generalOverviewSection
            }
            .frame(width: SettingsLayout.generalContentWidth, alignment: .leading)
            .padding(.bottom, SettingsLayout.generalBottomInset)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(width: SettingsLayout.windowContentWidth, alignment: .topLeading)
        .padding(SettingsLayout.windowPadding)
    }

    private var singlePagePane: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: SettingsLayout.paneHeaderSpacing) {
                if Self.automationSectionNavigationEnabled {
                    automationSectionNavigationBar
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        singlePageGeneralSection
                            .id(SettingsPane.general.id)
                            .accessibilityIdentifier("settings-section-general")
                            .accessibilityLabel("General Section")

                        sectionDivider

                        VStack(alignment: .leading, spacing: 0) {
                            paneSectionHeader(
                                title: "App Actions",
                                description: "Choose what happens when you click or scroll on app icons in the Dock.",
                                buttonTitle: "Reset App Actions",
                                action: preferences.resetAppActionsToDefaults
                            )

                            appActionsTable
                        }
                        .id(SettingsPane.appActions.id)
                        .accessibilityIdentifier("settings-section-app-actions")
                        .accessibilityLabel("App Actions Section")

                        sectionDivider

                        VStack(alignment: .leading, spacing: 0) {
                            paneSectionHeader(
                                title: "Folder Actions",
                                description: "Choose what happens when you click or scroll on folder stacks in the Dock.",
                                buttonTitle: "Reset Folder Actions",
                                action: preferences.resetFolderActionsToDefaults
                            )

                            folderActionsTables
                        }
                        .id(SettingsPane.folderActions.id)
                        .accessibilityIdentifier("settings-section-folder-actions")
                        .accessibilityLabel("Folder Actions Section")
                    }
                    .frame(width: SettingsLayout.windowContentWidth, alignment: .topLeading)
                    .padding(SettingsLayout.windowPadding)
                }
                .scrollIndicators(.automatic)
            }
            .onAppear {
                scrollToSelectedPane(using: proxy, animated: false)
                reportPaneReady(viewModel.selectedPane)
            }
            .onChange(of: viewModel.selectedPane) { pane in
                scrollToSelectedPane(using: proxy, animated: false)
                reportPaneReady(pane)
            }
        }
    }

    private var singlePageGeneralSection: some View {
        generalOverviewSection
    }

    private var generalOverviewSection: some View {
        HStack(alignment: .top, spacing: SettingsLayout.columnSpacing) {
            generalSettingsGroup
                .frame(width: SettingsLayout.generalColumnWidth, alignment: .topLeading)

            updatesSettingsGroup
                .padding(.leading, SettingsLayout.updatesLeadingInset)
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
                } else {
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

                if !updatesAvailable {
                    Text("Update unavailable")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if preferences.backgroundUpdateChecksEnabled {
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
                } else {
                    Text("Background checks are off until you opt in. Manual update checks remain available.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(updateManager.currentVersionText)
                    Text(updateManager.updateStatusText)
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
                buttonTitle: "Open Settings",
                footerText: permissionsStatusNote
            )
        }
    }

    private var permissionsStatusNote: String? {
        var missing: [String] = []
        if !coordinator.accessibilityGranted {
            missing.append("Accessibility")
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(width: SettingsLayout.windowContentWidth, alignment: .topLeading)
        .padding(SettingsLayout.windowPadding)
    }

    private var folderActionsPane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                paneSectionHeader(
                    title: "Folder Actions",
                    description: "Choose what happens when you click or scroll on folder stacks in the Dock. System leaves Finder in charge of remembered window, view, group, and sort state; choosing explicit Finder options makes Dockmint override them.",
                    buttonTitle: "Reset Folder Actions",
                    action: preferences.resetFolderActionsToDefaults
                )

                folderActionsTables
            }
            .frame(width: SettingsLayout.windowContentWidth, alignment: .topLeading)
            .padding(SettingsLayout.windowPadding)
        }
        .scrollIndicators(.automatic)
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

    private var automationSectionNavigationBar: some View {
        HStack(spacing: 8) {
            Text("Automation Sections")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(SettingsPane.allCases) { pane in
                Button("\(pane.title) Section") {
                    onPaneSelectionRequest(pane)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("settings-automation-\(pane.rawValue)")
            }
        }
        .padding(.horizontal, SettingsLayout.windowPadding)
        .padding(.top, SettingsLayout.windowPadding)
    }

    private var sectionDivider: some View {
        Divider()
            .padding(.vertical, SettingsLayout.sectionSpacing)
    }

    private func scrollToSelectedPane(using proxy: ScrollViewProxy, animated: Bool) {
        let scrollAction = {
            proxy.scrollTo(viewModel.selectedPane.id, anchor: .top)
        }
        if animated {
            withAnimation {
                scrollAction()
            }
        } else {
            scrollAction()
        }
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
        HStack(alignment: .top, spacing: SettingsLayout.columnSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))

                Text(description)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            ForEach(MappingModifier.allCases, id: \.self) { modifier in
                VStack(alignment: .leading, spacing: 10) {
                    Text(modifier.title)
                        .font(.headline)

                    folderActionsTable(for: modifier)
                }
            }
        }
    }

    private func folderActionsTable(for modifier: MappingModifier) -> some View {
        settingsTableCard {
            Grid(alignment: .leading, horizontalSpacing: SettingsLayout.tableCellSpacing, verticalSpacing: SettingsLayout.rowSpacing) {
                GridRow {
                    tableHeaderCell("Gesture", width: SettingsLayout.folderGestureColumnWidth)
                    tableHeaderCell("Open With", width: SettingsLayout.folderOpenWithColumnWidth)
                    tableHeaderCell("Options")
                }

                tableDivider(columns: 3)

                ForEach(Array(MappingSource.allCases.enumerated()), id: \.element) { index, source in
                    GridRow(alignment: .top) {
                        tableSecondaryCell(folderTriggerTitle(for: source), width: SettingsLayout.folderGestureColumnWidth)
                        folderOpenWithCell(source: source, modifier: modifier)
                        folderOptionsCell(source: source, modifier: modifier)
                    }

                    if index < MappingSource.allCases.count - 1 {
                        tableDivider(columns: 3)
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
        .background(
            RoundedRectangle(cornerRadius: SettingsLayout.tableCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsLayout.tableCornerRadius, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
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

    private func tableSecondaryCell(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
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

    private func folderOpenWithCell(source: MappingSource, modifier: MappingModifier) -> some View {
        let configuration = folderMappingBinding(source: source, modifier: modifier).wrappedValue
        let options = folderOpenWithOptionsStore.options(including: configuration.openInApplicationIdentifier)
        return Picker("", selection: folderOpenInBinding(source: source, modifier: modifier)) {
            ForEach(options) { option in
                Text(option.displayName).tag(option.identifier)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: SettingsLayout.folderOpenWithColumnWidth, alignment: .leading)
        .disabled(!folderOpenWithOptionsStore.isReady)
    }

    private func folderOptionsCell(source: MappingSource, modifier: MappingModifier) -> some View {
        let configuration = folderMappingBinding(source: source, modifier: modifier).wrappedValue
        let detailFields = folderActionDetailFields(for: configuration)

        return Group {
            if detailFields.isEmpty {
                Text("No additional options")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ViewThatFits(in: .horizontal) {
                    folderDetailFieldsInlineRow(
                        fields: detailFields,
                        source: source,
                        modifier: modifier
                    )
                    .frame(minWidth: SettingsLayout.folderOptionsPreferredWidth, alignment: .leading)

                    VStack(alignment: .leading, spacing: SettingsLayout.rowSpacing) {
                        ForEach(detailFields, id: \.self) { field in
                            folderDetailFieldStack(field: field, source: source, modifier: modifier)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func folderDetailFieldsInlineRow(
        fields: [FolderActionDetailField],
        source: MappingSource,
        modifier: MappingModifier
    ) -> some View {
        HStack(alignment: .center, spacing: SettingsLayout.tableCellSpacing) {
            ForEach(fields, id: \.self) { field in
                HStack(alignment: .center, spacing: SettingsLayout.folderDetailInlineSpacing) {
                    Text(field.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: SettingsLayout.folderDetailLabelWidth, alignment: .leading)

                    folderDetailFieldPicker(field: field, source: source, modifier: modifier)
                        .frame(width: SettingsLayout.folderDetailPickerWidth, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func folderActionDetailFields(for configuration: DockFolderAction) -> [FolderActionDetailField] {
        if configuration.opensInFinder {
            return [.finderView, .finderGroupBy, .finderSortBy]
        }
        return []
    }

    private func folderDetailFieldStack(
        field: FolderActionDetailField,
        source: MappingSource,
        modifier: MappingModifier
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.title)
                .font(.caption)
                .foregroundStyle(.secondary)

            folderDetailFieldPicker(field: field, source: source, modifier: modifier)
        }
        .frame(width: SettingsLayout.folderDetailControlWidth, alignment: .leading)
    }

    @ViewBuilder
    private func folderDetailFieldPicker(
        field: FolderActionDetailField,
        source: MappingSource,
        modifier: MappingModifier
    ) -> some View {
        let action = folderMappingBinding(source: source, modifier: modifier).wrappedValue

        if action.isFinderPassthrough, field != .finderView {
            Text("-")
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Group {
                switch field {
                case .finderView:
                    Picker("", selection: folderViewBinding(source: source, modifier: modifier)) {
                        ForEach(DockFolderView.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                case .finderGroupBy:
                    Picker("", selection: folderGroupByBinding(source: source, modifier: modifier)) {
                        ForEach(DockFolderGroupBy.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                case .finderSortBy:
                    Picker("", selection: folderSortByBinding(source: source, modifier: modifier)) {
                        ForEach(DockFolderSortBy.allCases, id: \.self) { option in
                            Text(folderSortDisplayName(option, for: action.view)).tag(option)
                        }
                    }
                case .dockSortBy:
                    Picker("", selection: dockFolderSortByBinding(source: source, modifier: modifier)) {
                        ForEach(DockFolderStackSortBy.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                case .dockDisplayAs:
                    Picker("", selection: dockFolderDisplayAsBinding(source: source, modifier: modifier)) {
                        ForEach(DockFolderStackDisplayAs.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                case .dockViewContentAs:
                    Picker("", selection: dockFolderViewContentAsBinding(source: source, modifier: modifier)) {
                        ForEach(DockFolderStackViewContentAs.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private func folderSortDisplayName(_ sortBy: DockFolderSortBy, for view: DockFolderView) -> String {
        guard sortBy == .none else {
            return sortBy.displayName
        }

        switch view {
        case .icon:
            return "None"
        case .automatic, .list, .column:
            return "System"
        }
    }

    private func folderTriggerTitle(for source: MappingSource) -> String {
        switch source {
        case .click:
            return "Click"
        case .scrollUp:
            return "Scroll Up"
        case .scrollDown:
            return "Scroll Down"
        }
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
                    var updated = action.wrappedValue
                    updated.openInApplicationIdentifier = normalizedIdentifier
                    action.wrappedValue = updated
                }
            }
        )
    }

    private func folderViewBinding(source: MappingSource, modifier: MappingModifier) -> Binding<DockFolderView> {
        let action = folderMappingBinding(source: source, modifier: modifier)
        return Binding(
            get: { action.wrappedValue.view },
            set: { view in
                var updated = action.wrappedValue
                if !updated.isConfigured {
                    updated.openInApplicationIdentifier = DockFolderOpenApplicationCatalog.finderBundleIdentifier
                }
                updated.view = view
                if view == .automatic || view == .column {
                    updated.sortBy = .none
                    updated.groupBy = .none
                }
                action.wrappedValue = updated
            }
        )
    }

    private func folderGroupByBinding(source: MappingSource, modifier: MappingModifier) -> Binding<DockFolderGroupBy> {
        let action = folderMappingBinding(source: source, modifier: modifier)
        return Binding(
            get: { action.wrappedValue.groupBy },
            set: { groupBy in
                var updated = action.wrappedValue
                if !updated.isConfigured {
                    updated.openInApplicationIdentifier = DockFolderOpenApplicationCatalog.finderBundleIdentifier
                }
                updated.groupBy = groupBy
                if groupBy != .none {
                    updated.sortBy = groupBy.defaultSortBy ?? .none
                    if updated.view == .column {
                        updated.view = .list
                    }
                }
                action.wrappedValue = updated
            }
        )
    }

    private func folderSortByBinding(source: MappingSource, modifier: MappingModifier) -> Binding<DockFolderSortBy> {
        let action = folderMappingBinding(source: source, modifier: modifier)
        return Binding(
            get: { action.wrappedValue.sortBy },
            set: { sortBy in
                var updated = action.wrappedValue
                if !updated.isConfigured {
                    updated.openInApplicationIdentifier = DockFolderOpenApplicationCatalog.finderBundleIdentifier
                }
                updated.sortBy = sortBy
                if sortBy != .none && updated.view == .column {
                    updated.view = .list
                }
                action.wrappedValue = updated
            }
        )
    }

    private func dockFolderSortByBinding(source: MappingSource, modifier: MappingModifier) -> Binding<DockFolderStackSortBy> {
        let action = folderMappingBinding(source: source, modifier: modifier)
        return Binding(
            get: { action.wrappedValue.dockSortBy },
            set: { sortBy in
                var updated = action.wrappedValue
                if !updated.isConfigured {
                    updated.openInApplicationIdentifier = DockFolderOpenApplicationCatalog.dockIdentifier
                }
                updated.dockSortBy = sortBy
                action.wrappedValue = updated
            }
        )
    }

    private func dockFolderDisplayAsBinding(source: MappingSource, modifier: MappingModifier) -> Binding<DockFolderStackDisplayAs> {
        let action = folderMappingBinding(source: source, modifier: modifier)
        return Binding(
            get: { action.wrappedValue.dockDisplayAs },
            set: { displayAs in
                var updated = action.wrappedValue
                if !updated.isConfigured {
                    updated.openInApplicationIdentifier = DockFolderOpenApplicationCatalog.dockIdentifier
                }
                updated.dockDisplayAs = displayAs
                action.wrappedValue = updated
            }
        )
    }

    private func dockFolderViewContentAsBinding(source: MappingSource, modifier: MappingModifier) -> Binding<DockFolderStackViewContentAs> {
        let action = folderMappingBinding(source: source, modifier: modifier)
        return Binding(
            get: { action.wrappedValue.dockViewContentAs },
            set: { viewContentAs in
                var updated = action.wrappedValue
                if !updated.isConfigured {
                    updated.openInApplicationIdentifier = DockFolderOpenApplicationCatalog.dockIdentifier
                }
                updated.dockViewContentAs = viewContentAs
                action.wrappedValue = updated
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
