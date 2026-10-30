import AppKit
import AgentDockCore
import SwiftUI

struct AdvancedView: View {
    @EnvironmentObject private var model: AgentDockModel

    var body: some View {
        if let profile = model.selectedProfile {
            ProfileAdvancedView(profile: profile)
        } else if let product = model.selectedOfficialProduct {
            OfficialAdvancedView(product: product)
        } else {
            ContentUnavailableView(
                "No Profile Selected",
                systemImage: "slider.horizontal.3",
                description: Text("Select a profile to manage its local configuration.")
            )
        }
    }
}

private struct ProfileAdvancedView: View {
    @EnvironmentObject private var model: AgentDockModel
    let profile: CodexProfile

    var body: some View {
        Form {
            ProviderAppSection(product: profile.product)

            Section {
                PathRow(title: "Profile Data", url: profile.profileDirectory, detail: storageSummary)
                if profile.product == .codex {
                    PathRow(title: "Codex Home", url: profile.codexHomePath)
                    PathRow(title: "App Data", url: profile.electronUserDataPath)
                } else {
                    PathRow(title: "User Data", url: profile.claudeUserDataPath)
                }
            } header: {
                Text("Local Data")
            } footer: {
                Text("Profile data stays on this Mac. Paths are copied or shown only when you choose an action.")
            }

            Section {
                LabeledContent {
                    if model.shortcutExists(for: profile) {
                        HStack {
                            Button("Show in Finder") { model.revealShortcut(profile) }
                            Button("Remove", role: .destructive) { model.removeShortcut(profile) }
                        }
                        .disabled(model.isBusy(profile))
                    } else {
                        Button("Install Shortcut") { model.installShortcut(profile) }
                            .disabled(model.isBusy(profile))
                    }
                } label: {
                    Text(model.shortcutExists(for: profile) ? "Installed" : "Not Installed")
                    Text(profile.shortcutPath.lastPathComponent)
                }
            } header: {
                Text("Shortcut")
            } footer: {
                Text("A shortcut in ~/Applications/AgentDock opens this profile directly and can be kept in the Dock.")
            }

            if profile.product == .codex {
                Section {
                    LabeledContent("OAuth Callback Port") {
                        Text(profile.mcpOAuthCallbackPort, format: .number.grouping(.never))
                            .monospacedDigit()
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Reserved for this profile's MCP sign-in callbacks.")
                }
            }

            Section {
                Button("Edit Profile…") { model.showEditProfile = true }
                Button("Remove from AgentDock…") { model.confirmRemoveProfile(profile) }
                Button("Delete Profile Data…", role: .destructive) { model.pendingDeleteProfile = profile }
            } header: {
                Text("Manage")
            } footer: {
                Text("Removing keeps the profile's data on disk so you can restore it later. Deleting permanently removes managed sessions and settings; shared Keychain items remain.")
            }
            .disabled(model.storeMutationInProgress)
        }
        .formStyle(.grouped)
    }

    private var storageSummary: String {
        let stats = model.stats(for: profile)
        let formatted = ByteCountFormatter.agentDock.string(fromByteCount: stats.dataBytes)
        let size = stats.dataSizeIsTruncated ? "At least \(formatted)" : formatted
        return "\(size) · \(profile.profileDirectory.abbreviatedPath)"
    }
}

private struct OfficialAdvancedView: View {
    let product: DesktopProduct

    var body: some View {
        Form {
            ProviderAppSection(product: product)
        }
        .formStyle(.grouped)
    }
}

/// The signed provider application a profile launches.
struct ProviderAppSection: View {
    @EnvironmentObject private var model: AgentDockModel
    let product: DesktopProduct

    var body: some View {
        let appURL = model.appURL(for: product)
        let available = FileManager.default.fileExists(atPath: appURL.path)
        Section {
            LabeledContent {
                Button("Choose…") { model.chooseApp(product) }
            } label: {
                Label {
                    Text("\(product.displayName).app")
                    Text(available
                        ? Bundle.shortVersion(ofAppAt: appURL).map { "Version \($0) · \(appURL.abbreviatedPath)" }
                            ?? appURL.abbreviatedPath
                        : "Not found at \(appURL.abbreviatedPath)")
                } icon: {
                    ProviderIconView(product: product, appURL: appURL, size: 32)
                }
            }
            if !available {
                Label("Choose the signed \(product.displayName) app to open profiles.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Provider App")
        } footer: {
            Text("AgentDock opens only signed, supported provider apps.")
        }
    }
}
