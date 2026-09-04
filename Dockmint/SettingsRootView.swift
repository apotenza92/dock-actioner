import SwiftUI

struct SettingsRootView: View {
    @ObservedObject var coordinator: DockExposeCoordinator
    @ObservedObject var updateManager: UpdateManager
    @ObservedObject var preferences: Preferences
    @ObservedObject var folderOpenWithOptionsStore: FolderOpenWithOptionsStore
    @ObservedObject var viewModel: SettingsWindowViewModel
    let onPaneAppear: (SettingsPane) -> Void
    var onOnboardingFinish: (Bool) -> Void = { _ in }

    var body: some View {
        Group {
            if preferences.shouldPresentOnboarding {
                OnboardingView(
                    coordinator: coordinator,
                    preferences: preferences,
                    onFinish: onOnboardingFinish
                )
            } else {
                PreferencesView(
                    coordinator: coordinator,
                    updateManager: updateManager,
                    preferences: preferences,
                    folderOpenWithOptionsStore: folderOpenWithOptionsStore,
                    viewModel: viewModel,
                    onPaneAppear: onPaneAppear
                )
            }
        }
    }
}
