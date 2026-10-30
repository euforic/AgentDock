import AppKit
import AgentDockCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AgentDockModel
    @State private var section: SettingsSection = .general

    var body: some View {
        TabView(selection: $section) {
            Tab("General", systemImage: "gearshape", value: .general) {
                GeneralSettings()
            }
            Tab("Updates", systemImage: "arrow.down.circle", value: .updates) {
                UpdateSettings()
            }
            Tab("Notifications", systemImage: "bell.badge", value: .notifications) {
                ResetNotificationSettings(controller: model.resetReminders)
            }
            Tab("Provider Apps", systemImage: "square.grid.2x2", value: .providerApps) {
                Form {
                    ForEach(DesktopProduct.allCases) { product in
                        ProviderAppSection(product: product)
                    }
                }
                .formStyle(.grouped)
            }
            Tab("Privacy", systemImage: "hand.raised", value: .privacy) {
                PrivacySettings()
            }
        }
        .frame(width: 620, height: 540)
        .onAppear {
            ProductAnalytics.shared.capture(AnalyticsEvent(
                .navigation,
                [.action(.viewed), .surface(section.analyticsSurface)]
            ))
        }
        .onChange(of: section) { _, value in
            ProductAnalytics.shared.capture(AnalyticsEvent(
                .navigation,
                [.action(.viewed), .surface(value.analyticsSurface)]
            ))
        }
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var model: AgentDockModel

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: appearanceBinding) {
                    ForEach(AgentDockAppearance.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Picker("Show at launch", selection: defaultViewBinding) {
                    ForEach(AgentDockDefaultView.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Toggle("Show running status in the sidebar", isOn: showStatusBinding)
            }

            Section {
                Toggle("Refresh activity and usage automatically", isOn: refreshBinding)
                Picker("Refresh interval", selection: refreshIntervalBinding) {
                    ForEach(AgentDockPreferencesStore.allowedIntervals, id: \.self) { minutes in
                        Text(minutes == 1 ? "Every minute" : "Every \(minutes) minutes").tag(minutes)
                    }
                }
                .disabled(!model.preferences.refreshProfileActivity)
            } footer: {
                Text("Automatic refreshes run only while AgentDock is the active app.")
            }

            Section {
                LabeledContent("Data location") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([ProfileStore.defaultRootDirectory()])
                    }
                }
                LabeledContent("Preferences") {
                    Button("Restore Defaults") { model.restorePreferences() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var appearanceBinding: Binding<AgentDockAppearance> {
        Binding(get: { model.preferences.appearance }, set: {
            guard $0 != model.preferences.appearance else { return }
            model.preferences.appearance = $0
            ProductAnalytics.shared.capture(AnalyticsEvent(
                .preferenceChanged,
                [.action(.appearanceChanged), .surface(.settingsGeneral)]
            ))
        })
    }

    private var defaultViewBinding: Binding<AgentDockDefaultView> {
        Binding(get: { model.preferences.defaultView }, set: {
            guard $0 != model.preferences.defaultView else { return }
            model.preferences.defaultView = $0
            ProductAnalytics.shared.capture(AnalyticsEvent(
                .preferenceChanged,
                [.action(.defaultViewChanged), .surface(.settingsGeneral)]
            ))
        })
    }

    private var refreshBinding: Binding<Bool> {
        Binding(get: { model.preferences.refreshProfileActivity }, set: {
            guard $0 != model.preferences.refreshProfileActivity else { return }
            model.preferences.refreshProfileActivity = $0
            ProductAnalytics.shared.capture(AnalyticsEvent(
                .preferenceChanged,
                [.action(.activityRefreshChanged), .surface(.settingsGeneral), .enabled($0)]
            ))
        })
    }

    private var refreshIntervalBinding: Binding<Int> {
        Binding(get: { model.preferences.refreshIntervalMinutes }, set: {
            if $0 != model.preferences.refreshIntervalMinutes { model.preferences.refreshIntervalMinutes = $0 }
        })
    }

    private var showStatusBinding: Binding<Bool> {
        Binding(get: { model.preferences.showStatusInProfileList }, set: {
            guard $0 != model.preferences.showStatusInProfileList else { return }
            model.preferences.showStatusInProfileList = $0
            ProductAnalytics.shared.capture(AnalyticsEvent(
                .preferenceChanged,
                [.action(.statusVisibilityChanged), .surface(.settingsGeneral), .enabled($0)]
            ))
        })
    }
}

private struct UpdateSettings: View {
    @EnvironmentObject private var updater: AppUpdater

    var body: some View {
        Form {
            Section {
                LabeledContent("AgentDock") {
                    HStack {
                        Text(versionAndBuild).foregroundStyle(.secondary)
                        Button("Check Now") { updater.checkForUpdates() }
                    }
                }
                Picker("Release channel", selection: updateChannelBinding) {
                    ForEach(AppUpdateChannel.allCases) { channel in
                        Text(channel.displayName).tag(channel)
                    }
                }
            } footer: {
                Text(updater.updateChannel == .alpha
                    ? "Alpha receives signed prerelease builds after changes merge. They may be less stable; switch back to Stable at any time."
                    : "Stable is the default and receives signed production releases.")
            }

            Section {
                Toggle("Check for updates automatically", isOn: automaticChecksBinding)
                Picker("Frequency", selection: updateCheckFrequencyBinding) {
                    ForEach(AppUpdateCheckFrequency.allCases) { frequency in
                        Text(frequency.displayName).tag(frequency)
                    }
                }
                .disabled(!updater.automaticallyChecksForUpdates)
                Toggle("Download and install updates automatically", isOn: automaticDownloadsBinding)
                    .disabled(!updater.automaticallyChecksForUpdates)
            } footer: {
                Text("Automatic installation completes when AgentDock can safely relaunch.")
            }
        }
        .formStyle(.grouped)
        .disabled(!updater.isConfigured)
        .overlay(alignment: .bottom) {
            if !updater.isConfigured {
                Text("Automatic updates are unavailable in this development build.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }

    private var versionAndBuild: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Development"
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, !build.isEmpty else {
            return "Version \(version)"
        }
        return "Version \(version) (\(build))"
    }

    private var automaticChecksBinding: Binding<Bool> {
        Binding(get: { updater.automaticallyChecksForUpdates }, set: {
            if $0 != updater.automaticallyChecksForUpdates { updater.setAutomaticallyChecksForUpdates($0) }
        })
    }

    private var updateChannelBinding: Binding<AppUpdateChannel> {
        Binding(get: { updater.updateChannel }, set: { if $0 != updater.updateChannel { updater.setUpdateChannel($0) } })
    }

    private var automaticDownloadsBinding: Binding<Bool> {
        Binding(get: { updater.automaticallyDownloadsUpdates }, set: {
            if $0 != updater.automaticallyDownloadsUpdates { updater.setAutomaticallyDownloadsUpdates($0) }
        })
    }

    private var updateCheckFrequencyBinding: Binding<AppUpdateCheckFrequency> {
        Binding(get: { updater.updateCheckFrequency }, set: {
            if $0 != updater.updateCheckFrequency { updater.setUpdateCheckFrequency($0) }
        })
    }
}

private struct PrivacySettings: View {
    @EnvironmentObject private var model: AgentDockModel

    var body: some View {
        let delivery = ProductAnalytics.shared.deliveryDiagnostics()
        Form {
            Section {
                Toggle("Share pseudonymous product analytics", isOn: analyticsBinding)
                    .disabled(!ProductAnalytics.shared.isConfigured)
                if !ProductAnalytics.shared.isConfigured {
                    Label("Analytics delivery isn't configured in this build, so no events can be sent.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                } else if model.analyticsConsent == .granted, delivery.failedBatches > 0, let failure = delivery.lastFailure {
                    Label(
                        "\(delivery.failedBatches) delivery \(delivery.failedBatches == 1 ? "issue" : "issues") this launch. Latest: \(failure.displayName).",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
                Link("View the Exact Event Catalog", destination: URL(string: "https://github.com/euforic/AgentDock/blob/main/docs/analytics.md")!)
            } header: {
                Text("Product Analytics")
            } footer: {
                Text("Off until you allow it. AgentDock then sends only allowlisted feature actions, outcomes, safe error codes, coarse counts and timing buckets, app version, macOS major version, and architecture. It never sends names, accounts, exact usage, model names, paths, commands, prompts, chats, transcripts, session IDs, configuration, logs, or location. Turning this off clears pending events and deletes the local analytics identifier.")
            }

            Section {
                LabeledContent("Profile metadata and activity summaries") {
                    Text("Stored on this Mac").foregroundStyle(.secondary)
                }
            } header: {
                Text("Local Data")
            } footer: {
                Text("AgentDock reads only managed profile metadata and supported local session records. It doesn't upload profile data or sync it. Provider apps may use their own network services and account storage.")
            }
        }
        .formStyle(.grouped)
    }

    private var analyticsBinding: Binding<Bool> {
        Binding(
            get: { model.analyticsConsent == .granted },
            set: {
                guard $0 != (model.analyticsConsent == .granted) else { return }
                model.setAnalyticsConsent(granted: $0, surface: .settingsPrivacy)
            }
        )
    }
}

private extension AnalyticsDeliveryFailure {
    var displayName: String {
        switch self {
        case .transport: "network transport failure"
        case .invalidResponse: "invalid server response"
        case .rejected: "server rejected the batch"
        case .serialization: "local payload serialization failure"
        }
    }
}

private enum SettingsSection: Hashable {
    case general
    case updates
    case notifications
    case providerApps
    case privacy

    var analyticsSurface: AnalyticsSurface {
        switch self {
        case .general, .updates, .notifications: .settingsGeneral
        case .providerApps: .settingsProviders
        case .privacy: .settingsPrivacy
        }
    }
}
