import AgentDockCore
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var model: AgentDockModel

    var body: some View {
        if let profile = model.selectedProfile {
            ProfileOverview(profile: profile)
        } else if let product = model.selectedOfficialProduct {
            OfficialOverview(product: product)
        } else {
            ContentUnavailableView {
                Label("No Profile Selected", systemImage: "person.crop.square.stack")
            } description: {
                Text("Select an app or profile in the sidebar, or add a profile for another account.")
            } actions: {
                Button("Add Profile…") { model.showAddProfile = true }
            }
        }
    }
}

private struct ProfileOverview: View {
    @EnvironmentObject private var model: AgentDockModel
    @State private var activityDestination: ActivityDestination?
    let profile: CodexProfile

    var body: some View {
        let status = model.instanceStatus(for: profile)
        let stats = model.stats(for: profile)
        let loading = model.statsAreLoading(for: profile)
        Form {
            Section {
                OverviewHeader(
                    title: profile.name,
                    running: status.isRunning,
                    detail: lastOpenedText,
                    busy: model.isBusy(profile),
                    openTitle: status.isRunning ? "Focus" : "Open",
                    open: { model.launch(profile) },
                    close: status.isRunning ? { model.close(profile) } : nil
                ) {
                    ProfileIconView(profile: profile, size: 52)
                }
            }

            if profile.lastLaunchedAt == nil {
                Section {
                    Label(
                        "Open \(profile.product.displayName), then sign in inside its window to start using this profile.",
                        systemImage: "person.crop.circle.badge.plus"
                    )
                    .foregroundStyle(.secondary)
                }
            }

            UsageLimitsSection(
                limits: model.rateLimits(for: profile),
                accent: Color(hex: profile.iconColor),
                providerName: profile.product.displayName
            )

            if profile.product == .codex {
                CodexProviderSection(
                    scopeName: profile.name,
                    discoveryDescription: "this profile's CODEX_HOME",
                    selection: profile.codexLaunchProfileSelection,
                    defaultProfile: profile.codexDefaultConfigProfile,
                    availableProfiles: model.codexConfigProfiles(for: profile),
                    isRunning: status.isRunning,
                    isBusy: model.isBusy(profile) || model.storeMutationInProgress,
                    onSelect: { model.setCodexLaunchProfileSelection($0, for: profile) },
                    onMakeDefault: { model.setDefaultCodexConfigProfile($0, for: profile) }
                )
            } else {
                ClaudeUsageSection(stats: stats, loading: loading, accent: Color(hex: profile.iconColor))
            }

            ActivitySection(product: profile.product, stats: stats, loading: loading) {
                activityDestination = $0
            } footer: {
                if profile.product == .claude {
                    Text("Totals come from this profile's local Cowork history. Limit status is the latest signal Claude recorded, not a complete quota snapshot.")
                }
            }

            if profile.product == .claude {
                ClaudeUsageSourcesSection(selection: .profile(profile.id))
            }
        }
        .formStyle(.grouped)
        .sheet(item: $activityDestination) { destination in
            ActivityDetailSheet(profile: profile, destination: destination)
        }
    }

    private var lastOpenedText: String {
        guard let date = profile.lastLaunchedAt else { return "Never opened" }
        return "Last opened \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct OfficialOverview: View {
    @EnvironmentObject private var model: AgentDockModel
    @State private var activityDestination: ActivityDestination?
    let product: DesktopProduct

    var body: some View {
        let running = model.stockInstanceStatuses[product]?.isRunning == true
        let stats = product == .codex ? model.officialCodexStats : model.officialClaudeStats
        Form {
            Section {
                OverviewHeader(
                    title: "Official \(product.displayName)",
                    running: model.stockInstanceStatuses[product]?.isRunning,
                    detail: Bundle.shortVersion(ofAppAt: model.appURL(for: product)).map { "Version \($0)" }
                        ?? "Default installation",
                    busy: model.busyStockProducts.contains(product),
                    openTitle: running ? "Focus" : "Open",
                    open: { model.openStock(product) },
                    close: nil
                ) {
                    ProviderIconView(product: product, appURL: model.appURL(for: product), size: 52)
                }
            }

            if model.profiles.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your Accounts, Side by Side")
                            .font(.headline)
                        Text("Add a profile for another account, open it, and sign in inside the provider app. Each profile keeps its supported app state separate.")
                            .foregroundStyle(.secondary)
                        Button("Add Profile…") { model.showAddProfile = true }
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 4)
                    }
                    .padding(.vertical, 4)
                }
            }

            if product == .codex {
                UsageLimitsSection(limits: model.officialCodexRateLimits, accent: product.usageTint, providerName: "Codex")
                CodexProviderSection(
                    scopeName: "Official Codex",
                    discoveryDescription: "the official ~/.codex home",
                    selection: model.officialCodexProfileSettings.launchSelection,
                    defaultProfile: model.officialCodexProfileSettings.defaultConfigProfile,
                    availableProfiles: model.officialCodexConfigProfiles,
                    isRunning: running,
                    isBusy: model.busyStockProducts.contains(.codex),
                    onSelect: model.setOfficialCodexLaunchProfileSelection,
                    onMakeDefault: model.setOfficialCodexDefaultConfigProfile
                )
            } else {
                UsageLimitsSection(
                    limits: model.officialClaudeRateLimits,
                    accent: product.usageTint,
                    providerName: "Claude",
                    footer: "Live limits follow the signed-in Claude account. Local activity can also include Claude Code sessions from a different login."
                )
                ClaudeUsageSection(stats: stats, loading: model.officialStatsLoading, accent: product.usageTint)
            }

            ActivitySection(product: product, stats: stats, loading: model.officialStatsLoading) {
                activityDestination = $0
            } footer: {
                if product == .claude {
                    Text("Managed profiles isolate Claude user data, logs, configuration, and encrypted payload files. Keychain services, permissions, updater state, files, network, shell, Git, and SSH remain shared.")
                }
            }

            if product == .claude, model.profiles.contains(where: { $0.product == .claude }) {
                ClaudeUsageSourcesSection(selection: .official)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $activityDestination) { destination in
            ActivityDetailSheet(officialProduct: product, destination: destination)
        }
    }
}

/// The identity and lifecycle actions at the top of a source's detail form.
private struct OverviewHeader<Icon: View>: View {
    let title: String
    let running: Bool?
    let detail: String
    let busy: Bool
    let openTitle: String
    let open: () -> Void
    let close: (() -> Void)?
    @ViewBuilder let icon: Icon

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                identity
                Spacer(minLength: 12)
                actions
            }
            VStack(alignment: .leading, spacing: 12) {
                identity
                actions
            }
        }
        .padding(.vertical, 4)
    }

    private var identity: some View {
        HStack(spacing: 14) {
            icon.runningBadge(running == true, diameter: 11)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .help(title)
                HStack(spacing: 6) {
                    RunningStatusLabel(isRunning: running)
                    Text("·")
                    Text(detail).lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            }
            if let close {
                Button("Close", action: close)
                    .disabled(busy)
                    .help("Close this profile only")
            }
            Button(openTitle, action: open)
                .buttonStyle(.borderedProminent)
                .disabled(busy)
                .help("\(openTitle) \(title)")
        }
        .controlSize(.large)
        .fixedSize()
    }
}

private struct CodexProviderSection: View {
    let scopeName: String
    let discoveryDescription: String
    let selection: CodexLaunchProfileSelection
    let defaultProfile: CodexConfigProfile?
    let availableProfiles: [CodexConfigProfile]
    let isRunning: Bool
    let isBusy: Bool
    let onSelect: (CodexLaunchProfileSelection) -> Void
    let onMakeDefault: (CodexConfigProfile?) -> Void

    var body: some View {
        Section {
            Picker("Provider Profile", selection: selectionBinding) {
                Text(defaultLabel).tag(CodexLaunchProfileSelection.useDefault)
                if defaultProfile != nil {
                    Text("Built-in Codex (OAuth)").tag(CodexLaunchProfileSelection.builtIn)
                }
                if !profilesIncludingSelection.isEmpty {
                    Divider()
                }
                ForEach(profilesIncludingSelection) { configProfile in
                    Text(configProfile.displayName).tag(CodexLaunchProfileSelection.named(configProfile))
                }
            }
            .disabled(isBusy)

            LabeledContent("Account Default") {
                HStack(spacing: 8) {
                    Text(defaultProfile?.displayName ?? "Built-in Codex (OAuth)")
                        .foregroundStyle(.secondary)
                    if !isDefault {
                        Button("Make Current Default") {
                            onMakeDefault(effectiveProfile)
                        }
                        .disabled(effectiveProfileIsUnavailable || isBusy)
                        .help("Use the selected provider profile as the default for \(scopeName)")
                    }
                }
            }

            if effectiveProfileIsUnavailable {
                Label(
                    "This provider profile is unavailable in \(discoveryDescription).",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }
        } header: {
            Text("Provider")
        } footer: {
            Text(footer)
        }
    }

    private var selectionBinding: Binding<CodexLaunchProfileSelection> {
        Binding(
            get: { defaultProfile == nil && selection == .builtIn ? .useDefault : selection },
            set: { onSelect($0) }
        )
    }

    private var defaultLabel: String {
        if let defaultProfile {
            "Default (\(defaultProfile.displayName))"
        } else {
            "Default (Built-in Codex)"
        }
    }

    private var profilesIncludingSelection: [CodexConfigProfile] {
        var profiles = availableProfiles
        if case let .named(selected) = selection, !profiles.contains(selected) {
            profiles.append(selected)
        }
        return profiles.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private var effectiveProfile: CodexConfigProfile? {
        switch selection {
        case .useDefault: defaultProfile
        case .builtIn: nil
        case let .named(configProfile): configProfile
        }
    }

    private var effectiveProfileIsUnavailable: Bool {
        guard let effectiveProfile else { return false }
        return !availableProfiles.contains(effectiveProfile)
    }

    private var isDefault: Bool {
        effectiveProfile == defaultProfile
    }

    private var footer: String {
        let source = "Named profiles are discovered in \(discoveryDescription)."
        return isRunning ? "\(source) Changing the provider restarts only this account." : source
    }
}

private struct UsageLimitsSection: View {
    let limits: ProfileRateLimits?
    let accent: Color
    var providerName = "Codex"
    var footer: String?

    var body: some View {
        Section {
            if let error = limits?.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else if let limits {
                let windows = HomeUsageWindow.windows(in: limits)
                if let warning = limits.warningMessage {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if windows.isEmpty, limits.credits == nil {
                    Text("No \(providerName) usage-limit data is currently available.")
                        .foregroundStyle(.secondary)
                }
                ForEach(windows) { window in
                    LimitRow(window: window, accent: accent)
                }
                if let credits = limits.credits {
                    LabeledContent("Extra Usage", value: credits.balance)
                        .monospacedDigit()
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading \(providerName) usage limits…")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Text("Usage Limits")
                Spacer()
                if let plan = limits?.planType, !plan.isEmpty {
                    Text(plan.replacingOccurrences(of: "_", with: " ").capitalized)
                }
            }
        } footer: {
            if let footer {
                Text(footer)
            }
        }
    }
}

private struct LimitRow: View {
    let window: HomeUsageWindow
    let accent: Color

    var body: some View {
        let percent = window.usage.usedPercent
        LabeledContent {
            HStack(spacing: 10) {
                ProgressView(value: min(max(percent, 0), 100), total: 100)
                    .tint(percent >= 90 ? .red : accent)
                    .frame(maxWidth: 220)
                Text("\(Int(percent.rounded()))% used")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 64, alignment: .trailing)
            }
        } label: {
            Text(window.title)
            Text(resetText)
        }
        .accessibilityElement(children: .combine)
    }

    private var resetText: String {
        guard let date = window.usage.resetsAt else { return "Reset time unavailable" }
        return "Resets \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct ClaudeUsageSection: View {
    let stats: ProfileStats
    let loading: Bool
    let accent: Color

    var body: some View {
        Section("Claude Usage") {
            LabeledContent("Sessions, last 7 days", value: loading ? "Loading…" : stats.weeklySessions.formatted())
            LabeledContent("Processed tokens, last 7 days", value: loading ? "Loading…" : stats.weeklyTokens.formatted())
            LabeledContent("Token coverage", value: loading ? "Loading…" : coverageText)
            usageLimitSignal
            ForEach(stats.modelUsage.prefix(3)) { model in
                LabeledContent {
                    Text("\(model.sessions.formatted()) sessions · \(model.tokens.formatted()) tokens")
                        .monospacedDigit()
                } label: {
                    Text(model.model)
                        .font(.body.monospaced())
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var usageLimitSignal: some View {
        if let signal = stats.latestUsageLimit {
            LabeledContent {
                if let percent = signal.usedPercent {
                    Text("\(Int(percent.rounded()))% used")
                        .monospacedDigit()
                }
            } label: {
                Label {
                    Text(limitTitle(signal))
                    Text(limitDetail(signal))
                } icon: {
                    Image(systemName: signal.status == .rejected ? "exclamationmark.octagon.fill" : "gauge.with.dots.needle.50percent")
                        .foregroundStyle(signal.status == .rejected ? .red : (signal.status == .warning ? .orange : accent))
                }
            }
        } else {
            LabeledContent("Latest limit signal", value: "None recorded")
        }
    }

    private var coverageText: String {
        guard stats.totalSessions > 0 else { return "No sessions" }
        return "\(stats.tokenizedSessions) of \(stats.totalSessions) sessions"
    }

    private func limitTitle(_ signal: UsageLimitSignal) -> String {
        let bucket = signal.bucket?
            .replacingOccurrences(of: "_", with: " ")
            .capitalized ?? "Usage"
        switch signal.status {
        case .allowed: return "\(bucket) allowed"
        case .warning: return "\(bucket) nearing limit"
        case .rejected: return "\(bucket) limit reached"
        }
    }

    private func limitDetail(_ signal: UsageLimitSignal) -> String {
        var parts = ["Observed \(signal.observedAt.formatted(date: .abbreviated, time: .shortened))"]
        if let reset = signal.resetsAt {
            parts.append("resets \(reset.formatted(date: .omitted, time: .shortened))")
        }
        if signal.isUsingOverage == true { parts.append("using overage") }
        return parts.joined(separator: " · ")
    }
}

private enum ClaudeUsageSelection: Equatable {
    case official
    case profile(CodexProfile.ID)
}

private struct ClaudeUsageSourcesSection: View {
    @EnvironmentObject private var model: AgentDockModel
    let selection: ClaudeUsageSelection

    var body: some View {
        Section("Claude Usage Sources") {
            sourceRow(
                name: "Official Claude",
                summary: summary(stats: model.officialClaudeStats, loading: model.officialStatsLoading),
                running: model.stockInstanceStatuses[.claude]?.isRunning == true,
                selected: selection == .official,
                select: { model.selectOfficial(.claude) }
            ) {
                ProviderIconView(product: .claude, appURL: model.appURL(for: .claude), size: 28)
            }
            ForEach(model.profiles.filter { $0.product == .claude }) { profile in
                sourceRow(
                    name: profile.name,
                    summary: summary(stats: model.stats(for: profile), loading: model.statsAreLoading(for: profile)),
                    running: model.instanceStatus(for: profile).isRunning,
                    selected: selection == .profile(profile.id),
                    select: { model.selectProfile(profile.id) }
                ) {
                    ProfileIconView(profile: profile, size: 28)
                }
            }
        }
    }

    private func sourceRow<Icon: View>(
        name: String,
        summary: String,
        running: Bool,
        selected: Bool,
        select: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button(action: select) {
            HStack(spacing: 10) {
                icon().runningBadge(running, diameter: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).foregroundStyle(.primary)
                    Text(summary).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Current")
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func summary(stats: ProfileStats, loading: Bool) -> String {
        if loading { return "Loading local usage…" }
        return "\(stats.weeklySessions.formatted()) sessions · \(stats.weeklyTokens.formatted()) tokens in 7 days"
    }
}

private struct ActivitySection<Footer: View>: View {
    let product: DesktopProduct
    let stats: ProfileStats
    let loading: Bool
    let onSelect: (ActivityDestination) -> Void
    @ViewBuilder let footer: Footer

    var body: some View {
        Section {
            FormNavigationRow(title: "Storage", systemImage: "internaldrive", value: loading ? "Loading…" : storageSize) {
                onSelect(.storage)
            }
            if product == .codex {
                FormNavigationRow(
                    title: "Logs, Last 7 Days",
                    systemImage: "doc.text.magnifyingglass",
                    value: loading ? "Loading…" : "\(stats.weeklyErrors.formatted()) errors · \(stats.weeklyWarnings.formatted()) warnings",
                    valueStyle: stats.weeklyErrors > 0 ? .red : (stats.weeklyWarnings > 0 ? .orange : .secondary)
                ) {
                    onSelect(.logs)
                }
                latestActivityRow
                FormNavigationRow(
                    title: "Archived Sessions",
                    systemImage: "archivebox",
                    value: loading ? "Loading…" : stats.archivedSessions.formatted()
                ) {
                    onSelect(.archived)
                }
            } else {
                FormNavigationRow(
                    title: "Local Sessions",
                    systemImage: "bubble.left.and.bubble.right",
                    value: loading ? "Loading…" : stats.totalSessions.formatted()
                ) {
                    onSelect(.sessions)
                }
                latestActivityRow
            }
            ForEach(stats.errorMessages, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Activity")
        } footer: {
            footer
        }
    }

    private var storageSize: String {
        let formatted = ByteCountFormatter.agentDock.string(fromByteCount: stats.dataBytes)
        return stats.dataSizeIsTruncated ? "At least \(formatted)" : formatted
    }

    private var latestActivityRow: some View {
        FormNavigationRow(
            title: "Latest Activity",
            systemImage: "clock",
            value: loading
                ? "Loading…"
                : stats.lastActivityAt?.formatted(date: .abbreviated, time: .shortened) ?? "No activity yet"
        ) {
            onSelect(.lastActivity)
        }
    }
}
