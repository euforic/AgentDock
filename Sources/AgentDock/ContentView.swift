import AppKit
import AgentDockCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AgentDockModel
    @State private var profileSearch = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            AgentDockSidebar(resetReminders: model.resetReminders, query: profileQuery)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            AgentDockDetail(resetReminders: model.resetReminders)
        }
        .searchable(text: $profileSearch, placement: .sidebar, prompt: "Search Profiles")
        .searchFocused($searchFocused)
        .onSubmit(of: .search, selectFirstSearchResult)
        .sheet(isPresented: $model.showAddProfile) {
            AddProfileSheet()
        }
        .sheet(isPresented: analyticsConsentBinding) {
            AnalyticsConsentView()
        }
        .sheet(item: editingProfileBinding) { profile in
            EditProfileSheet(profile: profile)
        }
        .alert("Unable to Complete the Action", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(
            "Remove “\(model.pendingRemoveProfile?.name ?? "Profile")” from AgentDock?",
            isPresented: removeBinding
        ) {
            Button("Remove") {
                if let profile = model.pendingRemoveProfile {
                    model.removeProfileFromList(profile)
                    model.pendingRemoveProfile = nil
                }
            }
            Button("Cancel", role: .cancel) {
                model.pendingRemoveProfile = nil
            }
        } message: {
            Text("Its data stays on disk, and you can restore it later with File › Restore Profile.")
        }
        .alert(
            "Delete All Data for “\(model.pendingDeleteProfile?.name ?? "Profile")”?",
            isPresented: deleteBinding
        ) {
            Button("Delete", role: .destructive) {
                if let profile = model.pendingDeleteProfile {
                    model.deleteProfileData(profile)
                }
            }
            Button("Cancel", role: .cancel) {
                model.pendingDeleteProfile = nil
            }
        } message: {
            Text("This permanently deletes the profile's local sessions, settings, and shortcut. Credentials in the shared macOS Keychain or provider accounts aren't affected. You can't undo this action.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentDockFocusSearch)) { _ in
            searchFocused = true
        }
        .onChange(of: model.detailTab) { _, tab in
            let surface: AnalyticsSurface = switch tab {
            case .overview: .overview
            case .advanced: .advanced
            }
            ProductAnalytics.shared.capture(AnalyticsEvent(
                .navigation,
                [.action(.viewed), .surface(surface)]
            ))
        }
    }

    private var profileQuery: String {
        profileSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func selectFirstSearchResult() {
        ProductAnalytics.shared.capture(AnalyticsEvent(
            .navigation,
            [.action(.searched), .surface(.sidebar)]
        ))
        if let first = model.profiles.first(where: { $0.matches(profileQuery) }) {
            model.selectProfile(first.id)
        }
    }

    private var editingProfileBinding: Binding<CodexProfile?> {
        Binding(
            get: { model.showEditProfile ? model.selectedProfile : nil },
            set: { if $0 == nil { model.showEditProfile = false } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil && !model.showAddProfile && !model.showEditProfile },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private var removeBinding: Binding<Bool> {
        Binding(
            get: { model.pendingRemoveProfile != nil },
            set: { if !$0 { model.pendingRemoveProfile = nil } }
        )
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { model.pendingDeleteProfile != nil },
            set: { if !$0 { model.pendingDeleteProfile = nil } }
        )
    }

    private var analyticsConsentBinding: Binding<Bool> {
        Binding(
            get: {
                AnalyticsConsentView.shouldPresent(
                    consent: model.analyticsConsent,
                    isConfigured: ProductAnalytics.shared.isConfigured
                )
            },
            set: { _ in }
        )
    }
}

extension CodexProfile {
    func matches(_ query: String) -> Bool {
        query.isEmpty
            || name.localizedCaseInsensitiveContains(query)
            || slug.localizedCaseInsensitiveContains(query)
    }
}

// MARK: - Sidebar

private enum SidebarItem: Hashable {
    case home
    case resets
    case official(DesktopProduct)
    case profile(CodexProfile.ID)
}

private struct AgentDockSidebar: View {
    @EnvironmentObject private var model: AgentDockModel
    @EnvironmentObject private var updater: AppUpdater
    @ObservedObject var resetReminders: ResetReminderController
    let query: String

    var body: some View {
        List(selection: selection) {
            Section {
                Label("Home", systemImage: "house")
                    .tag(SidebarItem.home)
                Label("Available Resets", systemImage: "clock.arrow.circlepath")
                    .badge(resetCount)
                    .tag(SidebarItem.resets)
                    .help("Banked Codex resets across accounts, sorted by expiration")
            }

            ForEach(DesktopProduct.allCases) { product in
                let profiles = model.profiles.filter { $0.product == product && $0.matches(query) }
                Section(product.displayName) {
                    if query.isEmpty {
                        OfficialSidebarRow(product: product)
                            .tag(SidebarItem.official(product))
                    }
                    ForEach(profiles) { profile in
                        ProfileSidebarRow(profile: profile)
                            .tag(SidebarItem.profile(profile.id))
                    }
                    .onMove(perform: query.isEmpty ? { source, destination in
                        model.moveProfiles(of: product, from: source, to: destination)
                    } : nil)
                }
            }

            if !query.isEmpty, !model.profiles.contains(where: { $0.matches(query) }) {
                Text("No Matching Profiles")
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            if let item = items.first, items.count == 1 {
                SidebarContextMenu(item: item)
            }
        } primaryAction: { items in
            guard let item = items.first, items.count == 1 else { return }
            open(item)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if updater.presentation.isVisible {
                SidebarUpdateButton(presentation: updater.presentation) {
                    updater.installAvailableUpdate()
                }
                .padding(12)
            }
        }
    }

    private var resetCount: Int {
        resetReminders.accounts.reduce(0) { $0 + $1.summary.availableCount }
    }

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                if resetReminders.showsAvailableResets { return .resets }
                return switch model.sidebarSelection {
                case .home: .home
                case let .official(product): .official(product)
                case let .profile(id): .profile(id)
                case nil: nil
                }
            },
            set: { item in
                switch item {
                case .home, nil:
                    model.selectHome()
                case .resets:
                    model.selectHome()
                    resetReminders.showsAvailableResets = true
                case let .official(product):
                    model.selectOfficial(product)
                case let .profile(id):
                    model.selectProfile(id)
                }
            }
        )
    }

    private func open(_ item: SidebarItem) {
        switch item {
        case let .official(product):
            model.openStock(product)
        case let .profile(id):
            if let profile = model.profiles.first(where: { $0.id == id }) {
                model.launch(profile)
            }
        case .home, .resets:
            break
        }
    }
}

private struct SidebarContextMenu: View {
    @EnvironmentObject private var model: AgentDockModel
    let item: SidebarItem

    var body: some View {
        switch item {
        case let .official(product):
            let running = model.stockInstanceStatuses[product]?.isRunning == true
            Button(running ? "Focus \(product.displayName)" : "Open \(product.displayName)") {
                model.openStock(product)
            }
            .disabled(model.busyStockProducts.contains(product))
            Divider()
            Button("Show Data in Finder") {
                model.revealOfficialData(product)
            }
        case let .profile(id):
            if let profile = model.profiles.first(where: { $0.id == id }) {
                profileMenu(profile)
            }
        case .home, .resets:
            EmptyView()
        }
    }

    @ViewBuilder
    private func profileMenu(_ profile: CodexProfile) -> some View {
        let running = model.instanceStatus(for: profile).isRunning
        Button(running ? "Focus" : "Open in \(profile.product.displayName)") {
            model.launch(profile)
        }
        .disabled(model.isBusy(profile))
        if running {
            Button("Close") {
                model.close(profile)
            }
            .disabled(model.isBusy(profile))
        }
        Divider()
        Button("Edit Profile…") {
            model.selectProfile(profile.id)
            model.showEditProfile = true
        }
        if model.shortcutExists(for: profile) {
            Button("Show Shortcut in Finder") {
                model.revealShortcut(profile)
            }
        } else {
            Button("Install Shortcut") {
                model.installShortcut(profile)
            }
            .disabled(model.isBusy(profile))
        }
        Button("Show Profile Data in Finder") {
            model.revealData(profile)
        }
        Divider()
        Button("Remove from AgentDock…") {
            model.confirmRemoveProfile(profile)
        }
        Button("Delete Profile Data…", role: .destructive) {
            model.pendingDeleteProfile = profile
        }
    }
}

private struct OfficialSidebarRow: View {
    @EnvironmentObject private var model: AgentDockModel
    let product: DesktopProduct

    var body: some View {
        let running = model.stockInstanceStatuses[product]?.isRunning == true
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text("Official \(product.displayName)")
                    .lineLimit(1)
                Text("Default installation")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            ProviderIconView(product: product, appURL: model.appURL(for: product), size: 24)
                .runningBadge(model.preferences.showStatusInProfileList && running, diameter: 7)
        }
        .accessibilityValue(running ? "Running" : "Not running")
    }
}

private struct ProfileSidebarRow: View {
    @EnvironmentObject private var model: AgentDockModel
    let profile: CodexProfile

    var body: some View {
        let running = model.instanceStatus(for: profile).isRunning
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .lineLimit(1)
                Text(subtitle(running: running))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            ProfileIconView(profile: profile, size: 24)
                .runningBadge(model.preferences.showStatusInProfileList && running, diameter: 7)
        }
        .help(profile.name)
        .accessibilityValue(running ? "Running" : "Not running")
    }

    private func subtitle(running: Bool) -> String {
        var parts: [String] = []
        if profile.product == .codex, let configProfile = model.effectiveCodexConfigProfile(for: profile) {
            parts.append(configProfile.displayName)
        }
        if running {
            parts.append("Running")
        } else if let lastLaunchedAt = profile.lastLaunchedAt {
            parts.append("Opened \(lastLaunchedAt.formatted(.relative(presentation: .named)))")
        } else {
            parts.append("Not opened yet")
        }
        return parts.joined(separator: " · ")
    }
}

private struct SidebarUpdateButton: View {
    let presentation: AppUpdatePresentation
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if presentation.showsProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                }
                Text(title)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(!presentation.allowsAction)
        .help(presentation.version.map { "Install AgentDock \($0)" } ?? "Install update")
    }

    private var title: String {
        if presentation.usesCompactAvailableStyle, let version = presentation.version {
            return "Update to \(version)"
        }
        return presentation.buttonTitle
    }
}

// MARK: - Detail

private struct AgentDockDetail: View {
    @EnvironmentObject private var model: AgentDockModel
    @ObservedObject var resetReminders: ResetReminderController

    var body: some View {
        content
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .toolbar {
                if !resetReminders.showsAvailableResets, model.selectedProfile != nil {
                    ToolbarItem(placement: .principal) {
                        Picker("Profile Section", selection: $model.detailTab) {
                            ForEach(AgentDockDetailTab.availableTabs(hasManagedProfile: true)) { tab in
                                Text(tab.title).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        model.refreshVisibleContent()
                    }
                    .help(model.showsHome ? "Refresh accounts, usage, and banked resets" : "Refresh activity and usage")

                    Button("Add Profile", systemImage: "plus") {
                        model.showAddProfile = true
                    }
                    .help("Add a profile for another account")
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if resetReminders.showsAvailableResets {
            AvailableResetsView(
                controller: resetReminders,
                openAccount: model.openResetAccount,
                profileNames: Dictionary(uniqueKeysWithValues: model.resetSources.map { ($0.id, $0.name) })
            )
        } else if model.showsHome {
            HomeView(resetReminders: resetReminders)
        } else {
            switch model.detailTab {
            case .overview:
                OverviewView()
            case .advanced:
                AdvancedView()
            }
        }
    }

    private var title: String {
        if resetReminders.showsAvailableResets { return "Available Resets" }
        if let profile = model.selectedProfile { return profile.name }
        if let product = model.selectedOfficialProduct { return "Official \(product.displayName)" }
        return "Home"
    }

    private var subtitle: String {
        if resetReminders.showsAvailableResets {
            let count = resetReminders.accounts.reduce(0) { $0 + $1.summary.availableCount }
            return "\(count) reported available"
        }
        if let profile = model.selectedProfile {
            return "Managed \(profile.product.displayName) profile"
        }
        if model.selectedOfficialProduct != nil { return "Default installation" }
        return ""
    }
}
