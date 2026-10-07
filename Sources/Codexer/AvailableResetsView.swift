import CodexerCore
import SwiftUI

struct ResetSidebarButton: View {
    @ObservedObject var controller: ResetReminderController
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label("Available Resets", systemImage: "arrow.counterclockwise.circle")
                Spacer(minLength: 0)
                if !controller.accounts.isEmpty {
                    Text(controller.accounts.reduce(0) { $0 + $1.summary.availableCount }.formatted())
                        .font(.caption.monospacedDigit())
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(controller.showsAvailableResets ? AgentDockPalette.selection : .clear,
                        in: .rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help("Banked Codex resets across accounts, sorted by expiration")
    }
}

struct ResetDetailContainer<Content: View>: View {
    @ObservedObject var controller: ResetReminderController
    let model: CodexerModel
    @ViewBuilder let content: Content

    var body: some View {
        if controller.showsAvailableResets {
            AvailableResetsView(controller: controller, openAccount: model.openResetAccount)
        } else { content }
    }
}

struct AvailableResetsView: View {
    @ObservedObject var controller: ResetReminderController
    let openAccount: (ResetAccount) -> Void

    private var sortedAccounts: [ResetAccount] {
        controller.accounts.sorted {
            let first = $0.summary.credits?.compactMap(\.expiresAt).min() ?? .distantFuture
            let second = $1.summary.credits?.compactMap(\.expiresAt).min() ?? .distantFuture
            return (first, $0.id) < (second, $1.id)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Available Resets").font(.title2.bold())
                    Text("Banked resets across your Codex accounts").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise", action: controller.refresh)
                    .disabled(controller.isRefreshing)
                    .keyboardShortcut("r", modifiers: .command)
            }
            .padding(20)
            Divider()
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        summary
                        if let key = controller.selectedResetKey, controller.reset(for: key) == nil {
                            Text("This reset is no longer in the latest account inventory. Refresh to confirm its status.")
                                .foregroundStyle(.secondary)
                        }
                        if !controller.policy.enabled {
                            Label("Expiration alerts are off. Enable them in Settings → Notifications.", systemImage: "bell.slash")
                                .foregroundStyle(.secondary)
                        }
                        if controller.scheduleLimited {
                            Text("The next 60 alerts are scheduled. Leave AgentDock running to refresh later reminders.")
                                .foregroundStyle(.orange)
                        }
                        if let error = controller.notificationError {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                        ForEach(sortedAccounts) { account in
                            ResetAccountSection(controller: controller, account: account, openAccount: openAccount)
                        }
                        ForEach(controller.sourceErrors.keys.sorted(), id: \.self) { sourceID in
                            Text(controller.sourceErrors[sourceID] ?? "Reset data unavailable")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if controller.accounts.isEmpty {
                            ContentUnavailableView(controller.isRefreshing ? "Checking accounts…" : "Reset information unavailable",
                                systemImage: "arrow.counterclockwise.circle",
                                description: Text("Sign in to Codex and refresh. Accounts with no reset credits will show a confirmed zero."))
                        }
                    }
                    .padding(20)
                }
                .onChange(of: controller.selectedResetKey, initial: true) {
                    if let key = controller.selectedResetKey { reader.scrollTo(key, anchor: .center) }
                }
            }
        }
    }

    private var summary: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let count = controller.accounts.reduce(0) { $0 + $1.summary.availableCount }
            let expiring = controller.accounts.reduce(0) { count, account in
                count + (account.summary.credits ?? []).filter {
                    $0.isAvailable(at: context.date) && ($0.expiresAt.map { $0 < context.date.addingTimeInterval(7 * 86400) } ?? false)
                }.count
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(count) reported available · \(expiring) expire this week").font(.headline)
                Text("Counts reflect the last provider response. Profiles sharing a verified account are counted once.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ResetAccountSection: View {
    @ObservedObject var controller: ResetReminderController
    let account: ResetAccount
    let openAccount: (ResetAccount) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(account.displayName).font(.headline)
                Spacer()
                Button("Open Codex") { openAccount(account) }
            }
            Text("\(account.summary.availableCount) reported available · Checked \(account.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            if account.detailsAreStale || Date().timeIntervalSince(account.checkedAt) > 600 || account.sourceIDs.contains(where: { controller.sourceErrors[$0] != nil }) {
                Label("Last known data; availability may have changed.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if account.detailsAreStale {
                Text("Expiration details could not be refreshed; last known reset details are shown.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !account.identityVerified {
                Text("Account identity unavailable; this profile is listed separately and may duplicate another account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if account.summary.credits == nil || account.missingDetailCount > 0 {
                Text("\(account.summary.availableCount) available; expiration details available for \(account.detailCount). Refresh to check missing details.")
                    .foregroundStyle(.secondary)
            }
            if account.summary.availableCount == 0 {
                Text("No available banked resets.").foregroundStyle(.secondary)
            }
            ForEach(account.summary.credits ?? []) { credit in
                ResetCreditRow(controller: controller, account: account, credit: credit)
                    .id(account.key(for: credit))
            }
        }
        .padding(16)
        .background(.secondary.opacity(0.06), in: .rect(cornerRadius: 10))
    }
}

private struct ResetCreditRow: View {
    @ObservedObject var controller: ResetReminderController
    let account: ResetAccount
    let credit: ResetCredit
    @State private var showsCustomSnooze = false
    @State private var snoozeDate = Date().addingTimeInterval(3600)
    @State private var snoozeError = false

    private var key: String { account.key(for: credit) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let state = controller.state(for: key)
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(credit.title ?? "Banked rate-limit reset").fontWeight(.medium)
                        if let description = credit.description { Text(description).font(.caption).foregroundStyle(.secondary) }
                        if let expiry = credit.expiresAt {
                            Text("Expires \(expiry.formatted(date: .abbreviated, time: .shortened))")
                            if expiry > context.date {
                                Text(expiry, style: .relative).font(.caption.monospacedDigit()).foregroundStyle(.orange)
                            } else { Text("Expired").foregroundStyle(.secondary) }
                        } else { Text("No expiration reported").foregroundStyle(.secondary) }
                        if credit.status != "available" { Text("Status: \(credit.status)").foregroundStyle(.secondary) }
                        if state.stopped { Text("Reminders stopped").font(.caption).foregroundStyle(.secondary) }
                        else if let date = state.snoozedUntil, date > context.date {
                            Text("Snoozed until \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                        } else if let date = controller.nextReminders[key], controller.policy.enabled {
                            Text("Next reminder \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 12)
                    if credit.isAvailable(at: context.date), credit.expiresAt != nil {
                        Menu("Snooze") {
                            Button("1 hour") { snooze(hours: 1) }
                            Button("4 hours") { snooze(hours: 4) }
                            Button("Tomorrow") { snooze(hours: 24) }
                            Button("Choose time…") {
                                snoozeDate = min(Date().addingTimeInterval(3600), (credit.expiresAt ?? .distantFuture).addingTimeInterval(-60))
                                showsCustomSnooze = true
                            }
                        }
                        if state.stopped || (state.snoozedUntil.map { $0 > context.date } ?? false) {
                            Button("Resume Now") { controller.resume(key: key) }
                        } else { Button("Stop Reminders") { controller.stop(key: key) } }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .sheet(isPresented: $showsCustomSnooze) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Snooze this reset").font(.headline)
                DatePicker("Resume reminders", selection: $snoozeDate)
                Text("Choose a time before the reset expires.").foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { showsCustomSnooze = false }
                    Spacer()
                    Button("Snooze") {
                        if controller.snooze(key: key, until: snoozeDate) { showsCustomSnooze = false }
                        else { snoozeError = true }
                    }
                }
            }.padding(24).frame(width: 420)
        }
        .alert("Choose an earlier snooze", isPresented: $snoozeError) {
            Button("OK", role: .cancel) {}
        } message: { Text("Reminders must resume before this reset expires.") }
    }

    private func snooze(hours: Int) {
        snoozeError = !controller.snooze(key: key, until: Date().addingTimeInterval(Double(hours) * 3600))
    }
}
