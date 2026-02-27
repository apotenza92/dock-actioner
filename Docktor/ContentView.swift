import SwiftUI
import AppKit

struct PreferencesView: View {
    @ObservedObject var coordinator: DockExposeCoordinator
    @ObservedObject var updateManager: UpdateManager
    @ObservedObject var preferences = Preferences.shared
    @State private var showingPermissionsInfo = false

    private enum MappingSource {
        case click
        case scrollUp
        case scrollDown
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
    }

    private let modifierColumnWidth: CGFloat = 150
    private let firstClickColumnWidth: CGFloat = 160
    private let actionColumnWidth: CGFloat = 150
    private let rowHeight: CGFloat = 44
    private let expandedFirstClickRowHeight: CGFloat = 76
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
            permissionsSection
                .frame(width: 220, alignment: .topLeading)
        }
    }

    private var appSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("General")
                .font(sectionTitleFont)
            checkboxRow("Show settings on startup", isOn: $preferences.showOnStartup)
            checkboxRow("Start Docktor at login", isOn: $preferences.startAtLogin)
            HStack(spacing: 12) {
                Button("Check for Updates", action: updateManager.checkForUpdates)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!updateManager.canCheckForUpdates)
                Button("Restart", action: restartApp)
                    .buttonStyle(.bordered)
                Button("Quit", action: { NSApp.terminate(nil) })
                    .buttonStyle(.bordered)
            }
            updateFrequencyRow
        }
    }

    private var updateFrequencyRow: some View {
        HStack(spacing: 10) {
            Text("Check for updates:")
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Picker("", selection: $preferences.updateCheckFrequency) {
                ForEach(UpdateCheckFrequency.allCases) { frequency in
                    Text(frequency.displayName).tag(frequency)
                }
            }
            .labelsHidden()
            .frame(width: 170)
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 6) {
                Text("Permissions")
                    .font(sectionTitleFont)
                Button {
                    showingPermissionsInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Permissions details")
                .popover(isPresented: $showingPermissionsInfo, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Docktor needs these permissions to detect your Dock gestures and run the actions you configure.")
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Accessibility")
                            .font(.headline)
                        Text("Lets Docktor identify Dock icons and trigger actions in other apps.")
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Input Monitoring")
                            .font(.headline)
                        Text("Lets Docktor listen for global click and scroll gestures.")
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(width: 320, alignment: .leading)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                permissionActionButton(
                    title: "Accessibility",
                    granted: coordinator.accessibilityGranted,
                    action: openAccessibilitySettings
                )
                permissionActionButton(
                    title: "Input Monitoring",
                    granted: coordinator.inputMonitoringGranted,
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
        HStack(spacing: 9) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.checkbox)
            Button {
                isOn.wrappedValue.toggle()
            } label: {
                Text(title)
            }
            .buttonStyle(.plain)
        }
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
            tableHeaderText("Active App", width: actionColumnWidth)
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
            tablePickerCell(selection: mappingBinding(source: MappingSource.scrollUp, modifier: modifier), width: actionColumnWidth)
            verticalDivider
            tablePickerCell(selection: mappingBinding(source: MappingSource.scrollDown, modifier: modifier), width: actionColumnWidth)
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

    private func tablePickerCell(selection: Binding<DockAction>, width: CGFloat) -> some View {
        Picker("", selection: selection) {
            ForEach(DockAction.allCases, id: \.self) { action in
                Text(action.displayName).tag(action)
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
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: $preferences.firstClickBehavior) {
                        ForEach(FirstClickBehavior.allCases, id: \.self) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.regular)
                    .frame(width: width - 20, alignment: .leading)

                    if shouldShowFirstClickAppExposeMultipleWindowsToggle {
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Toggle(">1 window only", isOn: $preferences.firstClickAppExposeRequiresMultipleWindows)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 12))
                                .fixedSize()
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, shouldShowFirstClickAppExposeMultipleWindowsToggle ? 6 : 0)
            } else {
                tablePickerCell(selection: firstClickActionBinding(for: modifier), width: width)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private func clickAfterActivationCell(for modifier: MappingModifier, width: CGFloat) -> some View {
        Group {
            if modifier == .none {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: mappingBinding(source: MappingSource.click, modifier: modifier)) {
                        ForEach(DockAction.allCases, id: \.self) { action in
                            Text(action.displayName).tag(action)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.regular)
                    .frame(width: width - 20, alignment: .leading)

                    if shouldShowClickAppExposeMultipleWindowsToggle {
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Toggle(">1 window only", isOn: $preferences.clickAppExposeRequiresMultipleWindows)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 12))
                                .fixedSize()
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, shouldShowClickAppExposeMultipleWindowsToggle ? 6 : 0)
            } else {
                tablePickerCell(selection: mappingBinding(source: MappingSource.click, modifier: modifier), width: width)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private func rowHeight(for modifier: MappingModifier) -> CGFloat {
        if modifier == .none && (shouldShowFirstClickAppExposeMultipleWindowsToggle || shouldShowClickAppExposeMultipleWindowsToggle) {
            return expandedFirstClickRowHeight
        }
        return rowHeight
    }

    private var shouldShowFirstClickAppExposeMultipleWindowsToggle: Bool {
        preferences.firstClickBehavior == .appExpose
    }

    private var shouldShowClickAppExposeMultipleWindowsToggle: Bool {
        preferences.clickAction == .appExpose
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
                                        action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Button(title, action: action)
                .buttonStyle(.bordered)
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
}
