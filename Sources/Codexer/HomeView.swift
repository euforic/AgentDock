import CodexerCore
import SwiftUI

/// A compact view of provider snapshots, with no separate polling or quota estimates.
struct HomeView: View {
    @EnvironmentObject private var model: CodexerModel
    @ObservedObject var resetReminders: ResetReminderController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HomeResetSummary(controller: resetReminders)
                ForEach(DesktopProduct.allCases, id: \.self) { product in
                    providerSection(product)
                }
                if model.profiles.isEmpty {
                    Label("Add a profile for another account, then sign in inside its provider app.",
                          systemImage: "person.crop.circle.badge.plus")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                Text("Usage is shown per source; profiles can share an account. Open Overview for all limits and local activity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(22)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func providerSection(_ product: DesktopProduct) -> some View {
        let profiles = model.profiles.filter { $0.product == product }
        return VStack(alignment: .leading, spacing: 8) {
            Text(product.displayName).font(.system(size: 17, weight: .semibold))
            LazyVStack(spacing: 0) {
                HomeSourceRow(
                    name: "Official \(product.displayName)",
                    subtitle: "Official installation",
                    limits: product == .codex ? model.officialCodexRateLimits : model.officialClaudeRateLimits,
                    running: model.stockInstanceStatuses[product]?.isRunning,
                    busy: model.busyStockProducts.contains(product),
                    accent: product == .codex ? AgentDockPalette.blue : .orange,
                    resetController: resetReminders,
                    resetSourceID: product == .codex ? "official" : nil,
                    open: { model.openStock(product) },
                    overview: {
                        model.selectOfficial(product)
                        model.detailTab = .overview
                    }
                ) {
                    ProviderIconView(product: product, appURL: model.appURL(for: product), size: 32)
                }
                ForEach(profiles) { profile in
                    Divider().overlay(AgentDockPalette.divider)
                    HomeSourceRow(
                        name: profile.name,
                        subtitle: "Managed profile",
                        limits: model.rateLimits(for: profile),
                        running: model.profileInstanceStatuses[profile.id]?.isRunning,
                        busy: model.isBusy(profile) || model.storeMutationInProgress,
                        accent: product == .codex ? AgentDockPalette.blue : .orange,
                        resetController: resetReminders,
                        resetSourceID: product == .codex ? profile.id.uuidString : nil,
                        open: { model.launch(profile) },
                        overview: {
                            model.selectProfile(profile.id)
                            model.detailTab = .overview
                        }
                    ) {
                        ProfileIconView(profile: profile, size: 32)
                    }
                }
            }
            .background(AgentDockPalette.panel.opacity(0.42), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(AgentDockPalette.divider))
        }
    }
}

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

private struct HomeResetSummary: View {
    @ObservedObject var controller: ResetReminderController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let digest = HomeResetDigest(accounts: controller.accounts,
                                         sourceErrors: controller.sourceErrors, now: context.date)
            let accent: Color = digest.hasExpirationWithin24Hours ? .red : .orange
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 20))
                    .foregroundStyle(digest.expirations.isEmpty ? Color.secondary : accent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(digest.reportedCount.map { "Banked resets · \($0) reported available" } ?? "Banked resets")
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(detail(digest))
                        .font(.caption)
                        .foregroundStyle(digest.hasExpirationWithin24Hours ? accent : .secondary)
                        .lineLimit(1)
                        .help(detail(digest))
                    if digest.lastKnown || digest.hasUnknownExpirations || digest.hasUnverifiedIdentity {
                        Text(qualifiers(digest))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(qualifiers(digest))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("View All Resets") { controller.showsAvailableResets = true }
                    .buttonStyle(.bordered)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(digest.expirations.isEmpty ? AgentDockPalette.panel.opacity(0.42) : accent.opacity(0.08),
                        in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                digest.expirations.isEmpty ? AgentDockPalette.divider : accent.opacity(0.3)))
        }
    }

    private func detail(_ digest: HomeResetDigest) -> String {
        guard digest.reportedCount != nil else {
            return controller.isRefreshing ? "Checking accounts…" : "Reset inventory unavailable"
        }
        if let next = digest.expirations.first, let expiry = next.credit.expiresAt {
            let summary = digest.hasExpirationWithin24Hours
                ? "Expires within 24 hours"
                : "\(digest.expirations.count) \(digest.expirations.count == 1 ? "expires" : "expire") within 7 days"
            return "\(summary) · \(expiry.formatted(date: .abbreviated, time: .shortened)) · \(next.account.displayName)"
        }
        return "No known available resets expire within 7 days"
    }

    private func qualifiers(_ digest: HomeResetDigest) -> String {
        [digest.lastKnown ? "Last known data; refresh to confirm" : nil,
         digest.hasUnknownExpirations ? "Some expiration details unavailable" : nil,
         digest.hasUnverifiedIdentity ? "Unverified accounts may duplicate" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

private struct HomeSourceRow<Icon: View>: View {
    let name: String
    let subtitle: String
    let limits: ProfileRateLimits?
    let running: Bool?
    let busy: Bool
    let accent: Color
    let resetController: ResetReminderController
    let resetSourceID: String?
    let open: () -> Void
    let overview: () -> Void
    @ViewBuilder let icon: Icon

    var body: some View {
        HStack(spacing: 16) {
            identity.frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                if let resetSourceID {
                    HomeProfileResets(controller: resetController, sourceID: resetSourceID)
                }
                HomeUsageSummary(limits: limits, accent: accent)
            }
            .frame(width: 220)
            actions
        }
        .padding(14)
    }

    private var identity: some View {
        Button(action: overview) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).fontWeight(.semibold).lineLimit(1).help(name)
                    Text([subtitle, limits?.planType?.replacingOccurrences(of: "_", with: " ").capitalized]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 5) {
                        StatusDot(isRunning: running == true, size: 6)
                        Text(running.map { $0 ? "Running" : "Stopped" } ?? "Status unavailable").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows \(name) overview")
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(busy ? "Working…" : running == true ? "Focus" : "Open", action: open)
                .buttonStyle(.bordered)
                .frame(minWidth: 64)
                .disabled(busy)
                .accessibilityLabel("\(running == true ? "Focus" : "Open") \(name)")
            Button(action: overview) {
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    .frame(width: 20, height: 28)
            }
            .buttonStyle(.plain)
            .help("Show \(name) overview")
            .accessibilityLabel("Show \(name) overview")
        }
        .fixedSize()
    }
}

private struct HomeProfileResets: View {
    @ObservedObject var controller: ResetReminderController
    let sourceID: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let digest = HomeResetDigest(accounts: controller.accounts,
                sourceErrors: controller.sourceErrors, now: context.date, sourceID: sourceID)
            Button {
                if let next = digest.expirations.first {
                    controller.selectedResetKey = next.id
                } else { controller.selectedResetKey = nil }
                controller.showsAvailableResets = true
            } label: {
                HStack(spacing: 5) {
                    Text(digest.reportedCount.map { "\($0) available resets" } ?? "Resets unavailable")
                    if !digest.expirations.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(digest.hasExpirationWithin24Hours ? Color.red : .orange)
                    }
                    if digest.lastKnown {
                        Text("· Last known").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(help(digest))
            .accessibilityHint(help(digest))
        }
    }

    private func help(_ digest: HomeResetDigest) -> String {
        if let expiry = digest.expirations.first?.credit.expiresAt {
            return "\(digest.expirations.count) expire within 7 days. Next expiration: \(expiry.formatted(date: .abbreviated, time: .shortened)). Show Available Resets."
        }
        if digest.reportedCount == nil { return "No reset inventory for this source. Show Available Resets to refresh." }
        if digest.hasUnknownExpirations { return "Some expiration details are unavailable. Show Available Resets." }
        return "Show banked resets for this account. Profiles sharing an account show the same allowance."
    }
}

struct HomeUsageWindow: Identifiable {
    let id: String
    let title: String
    let usage: RateLimitWindowUsage

    static func windows(in limits: ProfileRateLimits) -> [Self] {
        limits.buckets.flatMap { bucket in
            [("primary", bucket.primary), ("secondary", bucket.secondary)].compactMap { key, usage in
                guard let usage else { return nil }
                let duration: String
                switch usage.windowDurationMins {
                case 10080: duration = "Weekly"
                case let minutes? where minutes > 0 && minutes % 1440 == 0: duration = "\(minutes / 1440)-day"
                case let minutes? where minutes > 0 && minutes % 60 == 0: duration = "\(minutes / 60)-hour"
                case let minutes? where minutes > 0: duration = "\(minutes)-minute"
                default: duration = "Usage"
                }
                let title = ["codex", "claude"].contains(bucket.id) ? duration : "\(bucket.name) · \(duration)"
                return Self(id: "\(bucket.id).\(key)", title: title, usage: usage)
            }
        }
    }
}

struct HomeUsageSummary: View {
    let limits: ProfileRateLimits?
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let limits {
                if let error = limits.errorMessage {
                    Label("Usage unavailable", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary).help(error)
                    Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    let windows = HomeUsageWindow.windows(in: limits)
                    ForEach(windows.prefix(2)) { window in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(window.title).lineLimit(1).help(window.title)
                                Spacer(minLength: 8)
                                Text("\(window.usage.usedPercent.formatted(.number.precision(.fractionLength(0))))% used")
                                    .monospacedDigit()
                            }
                            ProgressView(value: min(max(window.usage.usedPercent, 0), 100), total: 100)
                                .tint(window.usage.usedPercent >= 90 ? .red : accent)
                                .accessibilityLabel(window.title)
                                .help(window.usage.resetsAt.map {
                                    "Resets \($0.formatted(date: .abbreviated, time: .shortened))"
                                } ?? "Reset time unavailable")
                        }
                    }
                    if windows.count > 2 { Text("+\(windows.count - 2) more in Overview").foregroundStyle(.secondary) }
                    if windows.isEmpty { Text("No usage windows reported").foregroundStyle(.secondary) }
                    if let warning = limits.warningMessage {
                        Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(2).help(warning)
                    }
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    if limits.errorMessage == nil && context.date.timeIntervalSince(limits.fetchedAt) > 600 {
                        Text("Last known usage").foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Usage not loaded").foregroundStyle(.secondary)
                Text("Refresh to check this source.").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
