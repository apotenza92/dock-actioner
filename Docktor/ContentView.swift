import SwiftUI
import AppKit

struct PreferencesView: View {
    @ObservedObject var coordinator: DockExposeCoordinator
    @ObservedObject var updateManager: UpdateManager
    @ObservedObject var preferences: Preferences

    private enum MappingSource {
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
    }

    private enum MappingModifier: CaseIterable {
        case none
        case shift
        case option
        case shiftOption

        var title: String {
            switch self {
            case .none:
                return "No Modifier"
            case .shift:
                return "⇧ Shift"
            case .option:
                return "⌥ Option"
            case .shiftOption:
                return "⇧ Shift + ⌥ Option"
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
        case bringAllToFront
        case hideOthers
        case singleAppMode

        var displayName: String {
            switch self {
            case .none: return "-"
            case .activateApp: return "Activate App"
            case .hideApp: return "Hide App"
            case .appExpose: return "App Exposé"
            case .appExposeMultiple: return "App Exposé (>1 window only)"
            case .minimizeAll: return "Minimize All"
            case .quitApp: return "Quit App"
            case .bringAllToFront: return "Bring All to Front"
            case .hideOthers: return "Hide Others"
            case .singleAppMode: return "Single App Mode"
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
        case bringAllToFront
        case appExpose
        case appExposeMultiple

        var displayName: String {
            switch self {
            case .activateApp: return "Activate App"
            case .bringAllToFront: return "Bring All to Front"
            case .appExpose: return "App Exposé"
            case .appExposeMultiple: return "App Exposé (>1 window only)"
            }
        }

        static func from(behavior: FirstClickBehavior, requiresMultipleWindows: Bool) -> FirstClickMenuOption {
            if behavior == .appExpose {
                return requiresMultipleWindows ? .appExposeMultiple : .appExpose
            }
            return FirstClickMenuOption(rawValue: behavior.rawValue) ?? .activateApp
        }
    }

    private let modifierColumnWidth: CGFloat = 150
    private let firstClickColumnWidth: CGFloat = 160
    private let actionColumnWidth: CGFloat = 150
    private let rowHeight: CGFloat = 44
    private let horizontalPadding: CGFloat = 16
    private let contentFont: Font = .system(size: 14)
    private let sectionTitleFont: Font = .system(size: 14, weight: .semibold)
    private var tableWidth: CGFloat { modifierColumnWidth + firstClickColumnWidth + (actionColumnWidth * 3) + 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            topSection
            actionsSection
        }
        .font(contentFont)
        .padding(horizontalPadding)
        .fixedSize(horizontal: true, vertical: true)
    }

    private var topSection: some View {
        HStack(alignment: .top, spacing: 24) {
            appSettingsSection
                .frame(width: 280, alignment: .topLeading)
            updatesSection
                .frame(width: 220, alignment: .topLeading)
            permissionsSection
                .frame(width: 220, alignment: .topLeading)
        }
    }

    private var appSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("General")
                .font(sectionTitleFont)
            checkboxRow("Show menu bar icon", isOn: $preferences.showMenuBarIcon)
            checkboxRow("Show settings on startup", isOn: $preferences.showOnStartup)
            checkboxRow("Start Docktor at login", isOn: $preferences.startAtLogin)
            HStack(spacing: 12) {
                Button("Restart", action: restartApp)
                    .buttonStyle(.bordered)
                Button("Quit", action: { NSApp.terminate(nil) })
                    .buttonStyle(.bordered)
                Button("About", action: showAboutPanel)
                    .buttonStyle(.bordered)
                Button(action: openGitHubPage) {
                    Image("GitHubMark")
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 14, height: 14)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.bordered)
                .help("Open Docktor on GitHub")
            }
        }
    }

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Updates")
                .font(sectionTitleFont)
            Button("Check for Updates", action: updateManager.checkForUpdates)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!updateManager.canCheckForUpdates)
            VStack(alignment: .leading, spacing: 6) {
                Text("Check frequency:")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Picker("", selection: $preferences.updateCheckFrequency) {
                    ForEach(UpdateCheckFrequency.allCases) { frequency in
                        Text(frequency.displayName).tag(frequency)
                    }
                }
                .labelsHidden()
                .frame(width: 170, alignment: .leading)
            }
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Permissions")
                .font(sectionTitleFont)

            VStack(alignment: .leading, spacing: 8) {
                permissionActionButton(
                    title: "Accessibility",
                    granted: coordinator.accessibilityGranted,
                    infoText: "Allows Docktor to identify Dock icons and trigger actions.",
                    action: openAccessibilitySettings
                )
                permissionActionButton(
                    title: "Input Monitoring",
                    granted: coordinator.inputMonitoringGranted,
                    infoText: "Allows Docktor to listen for global click and scroll gestures.",
                    action: openInputMonitoringSettings
                )
            }
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            actionMappingTable
            HStack {
                Spacer()
                Button("Reset mappings to defaults") {
                    preferences.resetMappingsToDefaults()
                }
                .buttonStyle(.bordered)
            }
            .frame(width: tableWidth, alignment: .trailing)
        }
    }

    private func checkboxRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.checkbox)
    }

    private var actionMappingTable: some View {
        VStack(spacing: 0) {
            mappingHeaderRow
            mappingDataRow(for: .none, isLast: false)
            mappingDataRow(for: .shift, isLast: false)
            mappingDataRow(for: .option, isLast: false)
            mappingDataRow(for: .shiftOption, isLast: true)
        }
        .font(.body)
        .frame(width: tableWidth, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private var mappingHeaderRow: some View {
        HStack(spacing: 0) {
            tableHeaderText("Modifier", width: modifierColumnWidth)
            verticalDivider
            tableHeaderText("First Click", width: firstClickColumnWidth)
            verticalDivider
            tableHeaderText("Active App Click", width: actionColumnWidth)
            verticalDivider
            tableHeaderText("Scroll Up", width: actionColumnWidth)
            verticalDivider
            tableHeaderText("Scroll Down", width: actionColumnWidth)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
        .frame(height: 44)
    }

    private func mappingDataRow(for modifier: MappingModifier, isLast: Bool) -> some View {
        HStack(spacing: 0) {
            tableRowLabel(modifier.title, width: modifierColumnWidth)
            verticalDivider
            firstClickCell(for: modifier, width: firstClickColumnWidth)
            verticalDivider
            clickAfterActivationCell(for: modifier, width: actionColumnWidth)
            verticalDivider
            tablePickerCell(selection: actionMenuBinding(source: .scrollUp, modifier: modifier),
                            width: actionColumnWidth)
            verticalDivider
            tablePickerCell(selection: actionMenuBinding(source: .scrollDown, modifier: modifier),
                            width: actionColumnWidth)
        }
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)
            }
        }
        .frame(height: rowHeight(for: modifier))
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
    }

    private func tableHeaderText(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(sectionTitleFont)
            .foregroundColor(.primary)
            .padding(.horizontal, 10)
            .frame(width: width, alignment: .leading)
    }

    private func tableRowLabel(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(width: width, alignment: .leading)
    }

    private func tablePickerCell(selection: Binding<ActionMenuOption>, width: CGFloat) -> some View {
        Picker("", selection: selection) {
            ForEach(ActionMenuOption.allCases, id: \.self) { option in
                Text(option.displayName).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.regular)
        .frame(width: width - 20, alignment: .leading)
        .padding(.horizontal, 10)
        .frame(width: width, alignment: .leading)
    }

    private func firstClickCell(for modifier: MappingModifier, width: CGFloat) -> some View {
        Group {
            if modifier == .none {
                firstClickBehaviorPickerCell(width: width)
            } else {
                tablePickerCell(selection: firstClickActionMenuBinding(for: modifier), width: width)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private func firstClickBehaviorPickerCell(width: CGFloat) -> some View {
        Picker("", selection: firstClickBehaviorMenuBinding()) {
            ForEach(FirstClickMenuOption.allCases, id: \.self) { option in
                Text(option.displayName).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.regular)
        .frame(width: width - 20, alignment: .leading)
        .padding(.horizontal, 10)
        .frame(width: width, alignment: .leading)
    }

    private func clickAfterActivationCell(for modifier: MappingModifier, width: CGFloat) -> some View {
        tablePickerCell(selection: actionMenuBinding(source: .click, modifier: modifier), width: width)
    }

    private func rowHeight(for _: MappingModifier) -> CGFloat {
        rowHeight
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
                FirstClickMenuOption.from(behavior: preferences.firstClickBehavior,
                                          requiresMultipleWindows: preferences.firstClickAppExposeRequiresMultipleWindows)
            },
            set: { option in
                switch option {
                case .activateApp:
                    preferences.firstClickBehavior = .activateApp
                case .bringAllToFront:
                    preferences.firstClickBehavior = .bringAllToFront
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

    private func permissionActionButton(title: String,
                                        granted: Bool,
                                        infoText: String,
                                        action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Button(title, action: action)
                .buttonStyle(.bordered)
            Button(action: {}) {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(infoText)
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundColor(granted ? .green : .orange)
                .frame(width: 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        coordinator.requestAccessibilityPermission()
        coordinator.startWhenPermissionAvailable()
    }

    private func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
        coordinator.requestInputMonitoringPermission()
        coordinator.startWhenPermissionAvailable()
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
            return
        }
    }

    private func showAboutPanel() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    private func openGitHubPage() {
        guard let url = URL(string: "https://github.com/apotenza92/docktor") else { return }
        NSWorkspace.shared.open(url)
    }
}
