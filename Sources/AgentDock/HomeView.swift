import AgentDockCore
import SwiftUI

/// Every source's status in one sortable table, built from existing snapshots with no extra polling.
struct HomeView: View {
    @EnvironmentObject private var model: AgentDockModel
    @ObservedObject var resetReminders: ResetReminderController
    @State private var selection: Set<DashboardSource.ID> = []
    @State private var sortOrder: [KeyPathComparator<DashboardSource>] = []

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let sources = DashboardSource.all(in: model, resets: resetReminders, now: context.date)
            VStack(spacing: 0) {
                DashboardSummary(sources: sources, controller: resetReminders, now: context.date)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                Divider()
                table(sources, now: context.date)
            }
        }
    }

    private func table(_ sources: [DashboardSource], now: Date) -> some View {
        Table(of: DashboardSource.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Account", value: \.name) { source in
                AccountCell(source: source)
            }
            .width(min: 220, ideal: 300)
            TableColumn("Session", value: \.sessionSortValue) { source in
                UsageMeterCell(window: source.sessionWindow, accent: source.product.usageTint, now: now)
            }
            .width(min: 150, ideal: 190)
            TableColumn("Weekly", value: \.weeklySortValue) { source in
                UsageMeterCell(window: source.weeklyWindow, accent: source.product.usageTint, now: now)
            }
            .width(min: 150, ideal: 190)
            TableColumn("Banked Resets", value: \.resetSortValue) { source in
                ResetCell(source: source, controller: resetReminders)
            }
            .width(min: 110, ideal: 160)
            TableColumn("") { source in
                OpenButton(source: source)
            }
            .width(min: 64, ideal: 72, max: 90)
        } rows: {
            ForEach(DesktopProduct.allCases) { product in
                Section {
                    ForEach(sorted(sources.filter { $0.product == product })) { source in
                        TableRow(source)
                    }
                } header: {
                    Text(header(for: product, in: sources))
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .contextMenu(forSelectionType: DashboardSource.ID.self) { ids in
            if let source = sources.first(where: { ids.count == 1 && ids.contains($0.id) }) {
                Button(source.running == true ? "Focus" : "Open") { open(source) }
                    .disabled(source.busy)
                Button("Show Details") { showDetails(source) }
            }
        } primaryAction: { ids in
            if let source = sources.first(where: { ids.count == 1 && ids.contains($0.id) }) {
                showDetails(source)
            }
        }
    }

    /// Provider order is fixed; a chosen column sorts rows within each provider.
    private func sorted(_ sources: [DashboardSource]) -> [DashboardSource] {
        sortOrder.isEmpty ? sources : sources.sorted(using: sortOrder)
    }

    private func header(for product: DesktopProduct, in sources: [DashboardSource]) -> String {
        let accounts = sources.filter { $0.product == product }
        let running = accounts.filter { $0.running == true }.count
        let count = "\(accounts.count) \(accounts.count == 1 ? "account" : "accounts")"
        return running > 0 ? "\(product.displayName) · \(count) · \(running) running" : "\(product.displayName) · \(count)"
    }

    private func open(_ source: DashboardSource) {
        switch source.kind {
        case .official: model.openStock(source.product)
        case let .profile(profile): model.launch(profile)
        }
    }

    private func showDetails(_ source: DashboardSource) {
        switch source.kind {
        case .official: model.selectOfficial(source.product)
        case let .profile(profile): model.selectProfile(profile.id)
        }
        model.detailTab = .overview
    }
}

/// One official installation or managed profile, as the dashboard shows it.
struct DashboardSource: Identifiable {
    enum Kind: Equatable {
        case official
        case profile(CodexProfile)
    }

    let product: DesktopProduct
    let kind: Kind
    let name: String
    let limits: ProfileRateLimits?
    let running: Bool?
    let busy: Bool
    /// Banked-reset inventory for Codex sources; nil for Claude.
    let resets: HomeResetDigest?

    var id: String {
        switch kind {
        case .official: "official.\(product.rawValue)"
        case let .profile(profile): profile.id.uuidString
        }
    }

    var windows: [HomeUsageWindow] {
        guard let limits, limits.errorMessage == nil else { return [] }
        return HomeUsageWindow.windows(in: limits)
    }

    /// The shortest reported allowance window, such as the 5-hour session.
    var sessionWindow: HomeUsageWindow? {
        windows.first { (1..<1440).contains($0.usage.windowDurationMins ?? 0) }
            ?? (weeklyWindow == nil ? windows.first : nil)
    }

    var weeklyWindow: HomeUsageWindow? {
        windows.first { ($0.usage.windowDurationMins ?? 0) >= 1440 }
    }

    // Unavailable values sort below every reported value.
    var sessionSortValue: Double { sessionWindow?.usage.usedPercent ?? -1 }
    var weeklySortValue: Double { weeklyWindow?.usage.usedPercent ?? -1 }
    var resetSortValue: Int { resets?.reportedCount ?? -1 }

    @MainActor
    static func all(in model: AgentDockModel, resets controller: ResetReminderController, now: Date) -> [DashboardSource] {
        func digest(_ sourceID: String) -> HomeResetDigest {
            HomeResetDigest(accounts: controller.accounts, sourceErrors: controller.sourceErrors, now: now, sourceID: sourceID)
        }
        return DesktopProduct.allCases.flatMap { product in
            [DashboardSource(
                product: product,
                kind: .official,
                name: "Official \(product.displayName)",
                limits: product == .codex ? model.officialCodexRateLimits : model.officialClaudeRateLimits,
                running: model.stockInstanceStatuses[product]?.isRunning,
                busy: model.busyStockProducts.contains(product),
                resets: product == .codex ? digest("official") : nil
            )] + model.profiles.filter { $0.product == product }.map { profile in
                DashboardSource(
                    product: product,
                    kind: .profile(profile),
                    name: profile.name,
                    limits: model.rateLimits(for: profile),
                    running: model.profileInstanceStatuses[profile.id]?.isRunning,
                    busy: model.isBusy(profile) || model.storeMutationInProgress,
                    resets: product == .codex ? digest(profile.id.uuidString) : nil
                )
            }
        }
    }
}

// MARK: - Cells

private struct AccountCell: View {
    @EnvironmentObject private var model: AgentDockModel
    let source: DashboardSource

    var body: some View {
        HStack(spacing: 10) {
            icon.runningBadge(source.running == true, diameter: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let error = source.limits?.errorMessage {
                    Label("Usage unavailable", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(CompactLabelStyle())
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .help(error)
                } else {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
        .help(source.name)
        .accessibilityElement(children: .combine)
        .accessibilityValue(source.running == true ? "Running" : "Not running")
    }

    @ViewBuilder
    private var icon: some View {
        switch source.kind {
        case .official:
            ProviderIconView(product: source.product, appURL: model.appURL(for: source.product), size: 24)
        case let .profile(profile):
            ProfileIconView(profile: profile, size: 24)
        }
    }

    private var subtitle: String {
        var parts: [String] = [source.kind == .official ? "Official app" : "Profile"]
        if let plan = source.limits?.planType, !plan.isEmpty {
            parts.append(plan.replacingOccurrences(of: "_", with: " ").capitalized)
        }
        switch source.running {
        case true?: parts.append("Running")
        case false?: break
        case nil: parts.append("Status unavailable")
        }
        if source.limits == nil { parts.append("Checking usage…") }
        return parts.joined(separator: " · ")
    }
}

/// An inline meter: bar, percent, and time until the window resets.
struct UsageMeterCell: View {
    let window: HomeUsageWindow?
    let accent: Color
    let now: Date

    var body: some View {
        if let window {
            let percent = min(max(window.usage.usedPercent, 0), 100)
            let tint = UsageTint.color(for: percent, base: accent)
            HStack(spacing: 8) {
                Gauge(value: percent, in: 0...100) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(tint)
                    .frame(width: 56)
                Text("\(Int(percent.rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(percent >= 75 ? tint : .primary)
                    .frame(minWidth: 34, alignment: .trailing)
                Text(window.shortCountdown(at: now))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help("\(window.title) · \(window.usage.resetsAt.map { "resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "reset time unavailable")")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(window.title) usage")
            .accessibilityValue("\(Int(percent.rounded())) percent, \(window.timeRemaining(at: now))")
        } else {
            Text("—")
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Not reported")
        }
    }
}

private struct ResetCell: View {
    let source: DashboardSource
    @ObservedObject var controller: ResetReminderController

    var body: some View {
        if let digest = source.resets {
            let tint: Color = digest.hasExpirationWithin24Hours ? .red : .orange
            Button {
                controller.selectedResetKey = digest.expirations.first?.id
                controller.showsAvailableResets = true
            } label: {
                HStack(spacing: 6) {
                    Text(digest.reportedCount.map { $0.formatted() } ?? "—")
                        .monospacedDigit()
                        .foregroundStyle(digest.reportedCount == nil ? .tertiary : .primary)
                    if let expiry = digest.expirations.first?.credit.expiresAt {
                        Label(expiry.formatted(.relative(presentation: .named)), systemImage: "clock.badge.exclamationmark.fill")
                            .labelStyle(CompactLabelStyle())
                            .font(.subheadline)
                            .foregroundStyle(tint)
                            .lineLimit(1)
                    } else if digest.lastKnown, digest.reportedCount != nil {
                        Text("Last known")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(digest.expirations.first?.credit.expiresAt.map {
                "\(digest.expirations.count) expire within 7 days. Next: \($0.formatted(date: .abbreviated, time: .shortened))."
            } ?? "Show banked resets for this account")
        } else {
            Text("—")
                .foregroundStyle(.tertiary)
                .help("Banked resets apply to Codex accounts")
        }
    }
}

private struct OpenButton: View {
    @EnvironmentObject private var model: AgentDockModel
    let source: DashboardSource

    var body: some View {
        let title = source.running == true ? "Focus" : "Open"
        Button(source.busy ? "…" : title) {
            switch source.kind {
            case .official: model.openStock(source.product)
            case let .profile(profile): model.launch(profile)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(source.busy)
        .accessibilityLabel("\(title) \(source.name)")
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - Summary

private struct DashboardSummary: View {
    @EnvironmentObject private var model: AgentDockModel
    let sources: [DashboardSource]
    @ObservedObject var controller: ResetReminderController
    let now: Date

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
            runningTile
            resetsTile
            closestToLimitTile
            nextResetTile
        }
    }

    private var runningTile: some View {
        let running = sources.filter { $0.running == true }.count
        return DashboardTile(
            title: "Running",
            systemImage: "play.circle.fill",
            tint: running > 0 ? .green : .secondary,
            value: "\(running) of \(sources.count)",
            detail: running == 1 ? "account open" : "accounts open"
        )
    }

    private var resetsTile: some View {
        let digest = HomeResetDigest(accounts: controller.accounts, sourceErrors: controller.sourceErrors, now: now)
        let tint: Color = digest.hasExpirationWithin24Hours ? .red : (digest.expirations.isEmpty ? .secondary : .orange)
        let detail: String
        if let expiry = digest.expirations.first?.credit.expiresAt {
            detail = digest.hasExpirationWithin24Hours
                ? "One expires within 24 hours"
                : "Next expires \(expiry.formatted(.relative(presentation: .named)))"
        } else if digest.reportedCount == nil {
            detail = controller.isRefreshing ? "Checking accounts…" : "Inventory unavailable"
        } else {
            detail = "None expire this week"
        }
        return DashboardTile(
            title: "Banked Resets",
            systemImage: "clock.arrow.circlepath",
            tint: tint,
            value: digest.reportedCount.map { $0.formatted() } ?? "—",
            detail: detail,
            action: { controller.showsAvailableResets = true }
        )
    }

    private var closestToLimitTile: some View {
        let candidates = sources.flatMap { source in source.windows.map { (source, $0) } }
        let closest = candidates.max { $0.1.usage.usedPercent < $1.1.usage.usedPercent }
        let percent = closest?.1.usage.usedPercent ?? 0
        return DashboardTile(
            title: "Closest to Limit",
            systemImage: "gauge.with.dots.needle.67percent",
            tint: closest == nil ? .secondary : UsageTint.color(for: percent, base: closest?.0.product.usageTint ?? .blue),
            value: closest.map { "\(Int($0.1.usage.usedPercent.rounded()))%" } ?? "—",
            detail: closest.map { "\($0.0.name) · \($0.1.title)" } ?? "No usage reported yet",
            action: closest.map { pair in { select(pair.0) } }
        )
    }

    private var nextResetTile: some View {
        let upcoming = sources.flatMap { source in
            source.windows.compactMap { window -> (DashboardSource, HomeUsageWindow, Date)? in
                guard window.usage.usedPercent >= 1, let date = window.usage.resetsAt, date > now else { return nil }
                return (source, window, date)
            }
        }
        let next = upcoming.min { $0.2 < $1.2 }
        return DashboardTile(
            title: "Next Usage Reset",
            systemImage: "arrow.counterclockwise",
            tint: next == nil ? .secondary : .accentColor,
            value: next.map { $0.1.shortCountdown(at: now) } ?? "—",
            detail: next.map { "\($0.0.name) · \($0.1.title)" } ?? "No windows in use",
            action: next.map { item in { select(item.0) } }
        )
    }

    private func select(_ source: DashboardSource) {
        switch source.kind {
        case .official: model.selectOfficial(source.product)
        case let .profile(profile): model.selectProfile(profile.id)
        }
        model.detailTab = .overview
    }
}

private struct DashboardTile: View {
    let title: String
    let systemImage: String
    let tint: Color
    let value: String
    let detail: String
    var action: (() -> Void)?

    var body: some View {
        let content = HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(detail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)

        if let action {
            Button(action: action) { content.contentShape(.rect) }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
        } else {
            content
        }
    }
}

/// Shared thresholds so a window reads the same everywhere.
enum UsageTint {
    static func color(for percent: Double, base: Color) -> Color {
        if percent >= 90 { return .red }
        if percent >= 75 { return .orange }
        return base
    }
}

// MARK: - Shared types

struct HomeResetDigest {
    struct Expiration: Identifiable {
        let account: ResetAccount
        let credit: ResetCredit
        var id: String { account.key(for: credit) }
    }

    let reportedCount: Int?
    let expirations: [Expiration]
    let hasUnknownExpirations: Bool
    let hasExpirationWithin24Hours: Bool
    let hasUnverifiedIdentity: Bool
    let lastKnown: Bool

    init(accounts: [ResetAccount], sourceErrors: [String: String], now: Date, sourceID: String? = nil) {
        let consolidated = ResetAccount.consolidated(accounts)
        let accounts = sourceID.map { id in consolidated.filter { $0.sourceIDs.contains(id) } } ?? consolidated
        let sourceErrors = sourceID.map { id in sourceErrors.filter { $0.key == id } } ?? sourceErrors
        reportedCount = accounts.isEmpty ? nil : accounts.reduce(0) { $0 + $1.summary.availableCount }
        expirations = accounts.flatMap { account in
            (account.summary.credits ?? []).filter {
                $0.isAvailable(at: now) && $0.expiresAt.map { $0 <= now.addingTimeInterval(7 * 86400) } == true
            }.map { Expiration(account: account, credit: $0) }
        }.sorted { ($0.credit.expiresAt ?? .distantFuture, $0.id) < ($1.credit.expiresAt ?? .distantFuture, $1.id) }
        hasExpirationWithin24Hours = expirations.contains {
            $0.credit.expiresAt.map { $0 <= now.addingTimeInterval(86400) } == true
        }
        hasUnknownExpirations = accounts.contains { account in
            account.missingDetailCount > 0 || (account.summary.credits ?? []).contains {
                $0.isAvailable(at: now) && $0.expiresAt == nil
            }
        }
        hasUnverifiedIdentity = accounts.contains { !$0.identityVerified }
        lastKnown = !sourceErrors.isEmpty || accounts.contains {
            $0.detailsAreStale || now.timeIntervalSince($0.checkedAt) > 600
        }
    }
}

struct HomeUsageWindow: Identifiable {
    let id: String
    let title: String
    let usage: RateLimitWindowUsage

    func timeRemaining(at now: Date) -> String {
        guard let resetsAt = usage.resetsAt else { return "Reset time unavailable" }
        guard resetsAt > now else { return "Reset due · Refresh usage" }
        let reportedMinutes = ceil(resetsAt.timeIntervalSince(now) / 60)
        guard reportedMinutes.isFinite, reportedMinutes < Double(Int.max) else { return "Reset time unavailable" }
        let minutes = max(1, Int(reportedMinutes))
        if minutes < 60 { return "\(minutes)m left" }
        if minutes < 1440 { return "\(minutes / 60)h \(minutes % 60)m left" }
        return "\(minutes / 1440)d \(minutes % 1440 / 60)h left"
    }

    /// A compact countdown for gauges and tiles, such as "3h 15m" or "2d 4h".
    func shortCountdown(at now: Date) -> String {
        guard let resetsAt = usage.resetsAt else { return "No reset time" }
        guard resetsAt > now else { return "Reset due" }
        return timeRemaining(at: now).replacingOccurrences(of: " left", with: "")
    }

    /// The display name of a reported allowance window, such as "5-hour" or "Weekly".
    static func durationTitle(minutes: Int?) -> String {
        switch minutes {
        case 10080: "Weekly"
        case let minutes? where minutes > 0 && minutes % 1440 == 0: "\(minutes / 1440)-day"
        case let minutes? where minutes > 0 && minutes % 60 == 0: "\(minutes / 60)-hour"
        case let minutes? where minutes > 0: "\(minutes)-minute"
        default: "Usage"
        }
    }

    static func windows(in limits: ProfileRateLimits) -> [Self] {
        limits.buckets.flatMap { bucket in
            [("primary", bucket.primary), ("secondary", bucket.secondary)].compactMap { key, usage in
                guard let usage else { return nil }
                let duration = durationTitle(minutes: usage.windowDurationMins)
                let title = ["codex", "claude"].contains(bucket.id) ? duration : "\(bucket.name) · \(duration)"
                return Self(id: "\(bucket.id).\(key)", title: title, usage: usage)
            }
        }
    }
}

