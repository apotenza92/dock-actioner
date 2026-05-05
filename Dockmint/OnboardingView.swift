import SwiftUI

struct OnboardingView: View {
    @ObservedObject var coordinator: DockExposeCoordinator
    @ObservedObject var preferences: Preferences

    @State private var showPermissionsRequiredPopover = false
    @State private var showMenuBarHint = false

    private let appDisplayName = AppServices.appDisplayName

    private var loginItemAvailable: Bool {
        AppIdentity.supportsLoginItem
    }

    private var permissionsReady: Bool {
        coordinator.accessibilityGranted && coordinator.inputMonitoringGranted
    }

    private var missingPermissionsMessage: String {
        var missing: [String] = []
        if !coordinator.accessibilityGranted {
            missing.append("Accessibility")
        }
        if !coordinator.inputMonitoringGranted {
            missing.append("Input Monitoring")
        }
        return "Allow \(missing.joined(separator: " and ")) permissions to finish setup."
    }

    var body: some View {
        Group {
            if showMenuBarHint {
                completionView
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    permissionsSection
                    loginItemSection
                    detectedMouseScrollToolSection
                    updatesSection
                    footerActions
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear {
            coordinator.refreshPermissionsAfterExternalChange()
        }
        .onChange(of: permissionsReady) { ready in
            if ready {
                showPermissionsRequiredPopover = false
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Welcome to \(appDisplayName)")
                .font(.title2.weight(.semibold))

            Text("Dockmint adds custom click and scroll actions to app and folder icons in the Dock.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionsSection: some View {
        onboardingSection(
            title: "Permissions",
            description: "Dockmint needs Accessibility and Input Monitoring permissions to work."
        ) {
            SharedPermissionsSection(
                coordinator: coordinator,
                buttonTitle: "Open Settings",
                footerText: permissionsFooterText
            )
        }
    }

    private var permissionsFooterText: String? {
        if permissionsReady {
            return "All required permissions are enabled."
        }
        return nil
    }

    private var loginItemSection: some View {
        onboardingSection(
            title: "Start at Login",
            description: "Choose whether \(appDisplayName) should start automatically when you log in."
        ) {
            if loginItemAvailable {
                Toggle("Start \(appDisplayName) at login", isOn: $preferences.startAtLogin)
            } else {
                Text("Start at Login is unavailable in this build.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var detectedMouseScrollToolSection: some View {
        if let tool = MouseScrollDirectionToolDetector.detectedTools().first(where: { preferences.shouldSuggestReverseMouseScrollDuringOnboarding(for: $0) }) {
            onboardingSection(
                title: "Mouse Scroll Direction",
                description: "Detected \(tool.displayName). If you use LinearMouse, Mos, UnnaturalScrollWheels, or a similar app to reverse your mouse's scrolling direction, turn this on so Dockmint's Scroll Up and Scroll Down actions match your mouse. Trackpad and other continuous scrolling gestures keep following macOS behavior."
            ) {
                HStack(spacing: 8) {
                    Button("Turn On Reverse Mouse Scroll Direction") {
                        preferences.enableReverseMouseScrollActionsFromSuggestion(for: tool)
                    }
                    .buttonStyle(.bordered)

                    Button("Not Now") {
                        preferences.dismissMouseScrollToolSuggestion(for: tool)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var updatesSection: some View {
        onboardingSection(
            title: "Updates",
            description: ""
        ) {
            Toggle("Enable background update checks", isOn: $preferences.backgroundUpdateChecksEnabled)

            if preferences.backgroundUpdateChecksEnabled {
                HStack(spacing: 8) {
                    Text("Check")
                        .foregroundStyle(.secondary)

                    Picker("", selection: $preferences.updateCheckFrequency) {
                        ForEach(UpdateCheckFrequency.allCases.filter { $0 != .never }) { frequency in
                            Text(frequency.displayName).tag(frequency)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 180, alignment: .leading)
                }
            } else {
                Text("Background checks stay off until you opt in. Manual update checks remain available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footerActions: some View {
        HStack {
            Spacer()

            Button("Finish Setup") {
                if permissionsReady {
                    showMenuBarHint = true
                } else {
                    showPermissionsRequiredPopover = true
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .help(permissionsReady ? "Finish setup" : missingPermissionsMessage)
            .popover(isPresented: $showPermissionsRequiredPopover, arrowEdge: .top) {
                Text(missingPermissionsMessage)
                    .padding(12)
                    .frame(width: 260, alignment: .leading)
            }
        }
    }

    private var completionView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("You’re all set")
                .font(.title2.weight(.semibold))

            Text("Here is the icon in your menu bar for \(appDisplayName). Use it any time to open Settings or quit \(appDisplayName).")
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()

                Image(nsImage: StatusBarIcon.image(pointSize: 42))
                    .renderingMode(.template)
                    .foregroundStyle(.primary)
                    .frame(width: 42, height: 42)

                Spacer()
            }
            .padding(.top, 4)

            Spacer()

            HStack {
                Spacer()

                Button("Done") {
                    for tool in MouseScrollDirectionToolDetector.detectedTools() {
                        preferences.markMouseScrollToolSuggestionSeen(for: tool)
                    }
                    preferences.completeOnboarding()
                    NSApp.keyWindow?.close()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func onboardingSection<Content: View>(title: String,
                                                  description: String,
                                                  @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))

            if !description.isEmpty {
                Text(description)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

#Preview("Onboarding") {
    OnboardingView(
        coordinator: AppServices.live.coordinator,
        preferences: AppServices.live.preferences
    )
}
