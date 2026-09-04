import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var coordinator: DockExposeCoordinator
    @ObservedObject var preferences: Preferences
    var onFinish: (Bool) -> Void = { _ in }
    @State private var openSettingsWhenFinished = false

    private var permissionsReady: Bool {
        OnboardingSetup.canFinish(
            accessibilityGranted: coordinator.accessibilityGranted,
            inputMonitoringGranted: coordinator.inputMonitoringGranted
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Image(nsImage: StatusBarIcon.image(pointSize: 40))
                            .renderingMode(.template)
                            .accessibilityLabel("\(AppServices.appDisplayName) menu bar icon")
                        Text("Welcome to \(AppServices.appDisplayName)")
                            .font(.title2.weight(.semibold))
                        Text("Customize clicks and scrolling on the Dock.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Enable both permissions to get started.")
                            .foregroundStyle(.secondary)
                        permissionRow(
                            .accessibility,
                            granted: coordinator.accessibilityGranted,
                            detail: "Identify Dock icons and perform actions."
                        )
                        permissionRow(
                            .inputMonitoring,
                            granted: coordinator.inputMonitoringGranted,
                            detail: "Respond to clicks and scrolling on the Dock."
                        )
                    }
                    .accessibilityIdentifier("onboarding-step-permissions")

                    Text("Try it: click a Dock app with multiple windows open, or scroll on an app icon.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(24)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            HStack {
                Toggle("Open Settings when finished", isOn: $openSettingsWhenFinished)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Get Started", action: finish)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!permissionsReady)
                    .help(permissionsReady ? "Finish setup" : "Enable both permissions to continue.")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .font(.body)
        .onAppear {
            preferences.beginOnboarding()
            coordinator.refreshPermissionsAfterExternalChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            coordinator.refreshPermissionsAfterExternalChange()
        }
    }

    private func permissionRow(_ permission: DockmintPermission, granted: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .accessibilityLabel(granted ? "Granted" : "Required")
            VStack(alignment: .leading, spacing: 4) {
                Text(permission.title)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Open Settings") {
                coordinator.requestPermissionFromUser(permission)
            }
            .help("Open \(permission.title) in System Settings")
        }
    }

    private func finish() {
        coordinator.refreshPermissionsAfterExternalChange()
        guard permissionsReady else { return }
        preferences.completeOnboarding()
        onFinish(openSettingsWhenFinished)
    }
}

#Preview("Onboarding") {
    OnboardingView(
        coordinator: AppServices.live.coordinator,
        preferences: AppServices.live.preferences
    )
}
