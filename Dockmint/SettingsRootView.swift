import SwiftUI

struct SettingsRootView: View {
    @ObservedObject var coordinator: DockExposeCoordinator
    @ObservedObject var updateManager: UpdateManager
    @ObservedObject var preferences: Preferences
    @ObservedObject var folderOpenWithOptionsStore: FolderOpenWithOptionsStore
    @ObservedObject var viewModel: SettingsWindowViewModel
    let onPaneAppear: (SettingsPane) -> Void
    let onPaneSelectionRequest: (SettingsPane) -> Void
    let onOnboardingContentHeightChange: (CGFloat) -> Void

    var body: some View {
        Group {
            if preferences.shouldPresentOnboarding {
                OnboardingView(
                    coordinator: coordinator,
                    preferences: preferences,
                    onContentHeightChange: onOnboardingContentHeightChange
                )
            } else {
                PreferencesView(
                    coordinator: coordinator,
                    updateManager: updateManager,
                    preferences: preferences,
                    folderOpenWithOptionsStore: folderOpenWithOptionsStore,
                    viewModel: viewModel,
                    onPaneAppear: onPaneAppear,
                    onPaneSelectionRequest: onPaneSelectionRequest
                )
            }
        }
    }
}

struct SharedPermissionsSection: View {
    @ObservedObject var coordinator: DockExposeCoordinator
    let footerText: String?

    private let appDisplayName = AppServices.appDisplayName

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PermissionStatusRow(
                permission: .accessibility,
                granted: coordinator.accessibilityGranted,
                infoText: "Allows \(appDisplayName) to identify Dock icons and trigger actions.",
                action: { coordinator.requestPermissionFromUser(.accessibility) }
            )

            PermissionStatusRow(
                permission: .inputMonitoring,
                granted: coordinator.inputMonitoringGranted,
                infoText: "Allows \(appDisplayName) to listen for global click and scroll gestures.",
                action: { coordinator.requestPermissionFromUser(.inputMonitoring) }
            )

            if let footerText {
                Text(footerText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PermissionStatusRow: View {
    let permission: DockmintPermission
    let granted: Bool
    let infoText: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(granted ? Color.green : Color.orange)

                Text(permission.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help(infoText)
            }

            Button(action: action) {
                Text("Open \(permission.title) Settings")
                    .frame(maxWidth: .infinity)
                    .lineLimit(1)
            }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
