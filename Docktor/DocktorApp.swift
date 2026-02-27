//
//  DocktorApp.swift
//  Docktor
//
//  Created by Alex on 27/12/2025.
//

import SwiftUI
import AppKit

@main
struct DocktorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    private let services: AppServices
    @ObservedObject private var preferences: Preferences

    init() {
        let services = AppServices.live
        self.services = services
        self._preferences = ObservedObject(wrappedValue: services.preferences)
        AppDelegate.services = services
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $preferences.showMenuBarIcon) {
            SettingsLink {
                Text("Settings…")
            }
            .keyboardShortcut(",")

            Divider()

            Button("Quit Docktor") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(nsImage: StatusBarIcon.image())
                .renderingMode(.template)
                .accessibilityLabel("Docktor")
        }

        Settings {
            PreferencesView(coordinator: services.coordinator,
                            updateManager: services.updateManager,
                            preferences: services.preferences)
        }
    }
}
