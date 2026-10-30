import AppKit
import AgentDockCore
import SwiftUI

@main
struct AgentDockApp: App {
    @StateObject private var model = AgentDockModel()
    @StateObject private var updater = AppUpdater()

    var body: some Scene {
        WindowGroup("AgentDock", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(updater)
                .frame(minWidth: 820, minHeight: 540)
                .task {
                    model.resetReminders.configure(sources: model.resetSources, appURL: model.codexAppURL)
                }
                .onChange(of: model.profiles) {
                    model.resetReminders.configure(sources: model.resetSources, appURL: model.codexAppURL)
                }
                .onChange(of: model.codexAppURL) {
                    model.resetReminders.configure(sources: model.resetSources, appURL: model.codexAppURL)
                }
                .onChange(of: model.preferences.appearance, initial: true) { _, appearance in
                    // Applying the choice app-wide also covers Settings, sheets, and
                    // menus, and a return to System follows the system appearance again.
                    NSApp.appearance = appearance.nsAppearance
                }
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                }
        }
        .defaultSize(width: 1080, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            AgentDockCommands(model: model, updater: updater)
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(updater)
        }
    }
}

private struct AgentDockCommands: Commands {
    @ObservedObject var model: AgentDockModel
    @ObservedObject var updater: AppUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.isConfigured)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Profile…") {
                model.showAddProfile = true
            }
            .keyboardShortcut("n")

            Button("Restore Profile…") {
                model.restoreProfile()
            }
        }

        CommandGroup(after: .textEditing) {
            Button("Find Profile") {
                NotificationCenter.default.post(name: .agentDockFocusSearch, object: nil)
            }
            .keyboardShortcut("f")
        }

        SidebarCommands()

        CommandGroup(before: .sidebar) {
            Button("Home") {
                model.selectHome()
            }
            .keyboardShortcut("1")

            Button("Available Resets") {
                model.selectHome()
                model.resetReminders.showsAvailableResets = true
            }
            .keyboardShortcut("2")

            Divider()

            Button("Refresh") {
                model.refreshVisibleContent()
            }
            .keyboardShortcut("r")

            Divider()
        }

        CommandMenu("Profile") {
            let profile = model.selectedProfile
            let official = model.selectedOfficialProduct
            let running = profile.map { model.instanceStatus(for: $0).isRunning }
                ?? official.map { model.stockInstanceStatuses[$0]?.isRunning == true }
                ?? false

            Button(running ? "Focus" : "Open") {
                if let profile {
                    model.launch(profile)
                } else if let official {
                    model.openStock(official)
                }
            }
            .keyboardShortcut("o")
            .disabled(profile.map(model.isBusy) ?? official.map { model.busyStockProducts.contains($0) } ?? true)

            Button("Close") {
                if let profile { model.close(profile) }
            }
            .disabled(!running || (profile.map(model.isBusy) ?? true))

            Divider()

            Button("Edit Profile…") {
                model.showEditProfile = true
            }
            .keyboardShortcut("i")
            .disabled(profile == nil)

            if let profile, model.shortcutExists(for: profile) {
                Button("Show Shortcut in Finder") {
                    model.revealShortcut(profile)
                }
            } else {
                Button("Install Shortcut") {
                    if let profile { model.installShortcut(profile) }
                }
                .disabled(profile == nil)
            }

            Button("Show Profile Data in Finder") {
                if let profile { model.revealData(profile) }
            }
            .disabled(profile == nil)

            Divider()

            Button("Remove from AgentDock…") {
                if let profile { model.confirmRemoveProfile(profile) }
            }
            .disabled(profile == nil)

            Button("Delete Profile Data…") {
                model.pendingDeleteProfile = profile
            }
            .disabled(profile == nil)
        }
    }
}

extension Notification.Name {
    static let agentDockFocusSearch = Notification.Name("AgentDock.focusSearch")
}
