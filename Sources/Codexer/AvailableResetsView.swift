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
            AvailableResetsView(controller: controller, openAccount: model.openResetAccount,
                profileNames: Dictionary(uniqueKeysWithValues: model.resetSources.map { ($0.id, $0.name) }))
        } else { content }
    }
}

struct AvailableResetsView: View {
    @ObservedObject var controller: ResetReminderController
    let openAccount: (ResetAccount) -> Void
    var profileNames: [String: String] = [:]
    @State private var query = ""
    @State private var grouping = ResetInventoryGrouping.date
    @State private var sort = ResetInventorySort.soonest
    @State private var onlyExpiringSoon = false
    @State private var showsAccountStatus = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let sections = ResetInventory.sections(accounts: controller.accounts, profileNames: profileNames,
                grouping: grouping, sort: sort, query: query, onlyExpiringSoon: onlyExpiringSoon, now: context.date)
            VStack(spacing: 0) {
                header
                urgencyStrip(now: context.date)
                controls
                inventory(sections: sections, now: context.date)
                accountStatus(now: context.date)
            }
            .background(AgentDockPalette.graphite)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Available Resets").font(.system(size: 20, weight: .semibold))
                Text("\(controller.accounts.reduce(0) { $0 + $1.summary.availableCount }) reported available · Shared accounts counted once")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if controller.isRefreshing { ProgressView().controlSize(.small) }
            Button("Refresh", systemImage: "arrow.clockwise", action: controller.refresh)
                .agentDockToolbarAction()
                .disabled(controller.isRefreshing)
                .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }

    @ViewBuilder
    private func urgencyStrip(now: Date) -> some View {
        let soon = ResetInventory.expiringCount(accounts: controller.accounts, within: 7 * 86400, now: now)
        let today = ResetInventory.expiringCount(accounts: controller.accounts, within: 86400, now: now)
        if soon > 0 {
            HStack(spacing: 7) {
                Image(systemName: "clock.badge.exclamationmark")
                Text("\(soon) expire within 7 days").fontWeight(.medium)
                if today > 0 { Text("· \(today) within 24 hours") }
                Spacer(minLength: 8)
                Button(onlyExpiringSoon ? "Show all" : "Show expiring soon") {
                    onlyExpiringSoon.toggle()
                }
                .buttonStyle(.plain)
                .fontWeight(.medium)
                .accessibilityValue(onlyExpiringSoon ? "Filtering to resets expiring within 7 days" : "Showing all resets")
            }
            .font(.system(size: 11))
            .foregroundStyle(.orange)
            .padding(.horizontal, 10).frame(height: 30)
            .background(.orange.opacity(0.08), in: .rect(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).stroke(.orange.opacity(0.15)) }
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { searchField; groupPicker; sortPicker }
            VStack(spacing: 7) {
                searchField
                HStack(spacing: 10) { groupPicker; Spacer(minLength: 0); sortPicker }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search accounts or profiles", text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search resets, accounts or profiles")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8).frame(minWidth: 160, idealWidth: 260, maxWidth: .infinity, minHeight: 28)
        .agentDockGlassControl(radius: 7)
    }

    private var groupPicker: some View {
        HStack(spacing: 6) {
            Text("Group by").font(.system(size: 11)).foregroundStyle(.secondary)
            Picker("Group resets by", selection: $grouping) {
                ForEach(ResetInventoryGrouping.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 194)
        }
        .fixedSize()
    }

    private var sortPicker: some View {
        Picker("Sort resets", selection: $sort) {
            ForEach(ResetInventorySort.allCases) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden().frame(width: 136)
    }

    private func inventory(sections: [ResetInventorySection], now: Date) -> some View {
        GeometryReader { geometry in
            let columns = ResetInventoryColumns(compact: geometry.size.width < 760)
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    ResetColumnHeadings(sort: $sort, columns: columns)
                    ScrollViewReader { reader in
                        ScrollView {
                            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                                ForEach(sections) { section in
                                    Section {
                                        ForEach(section.rows) { row in
                                            ResetCreditRow(controller: controller, row: row,
                                                now: now, openAccount: openAccount, columns: columns)
                                                .id(row.id)
                                        }
                                    } header: {
                                        HStack {
                                            Text(section.title).fontWeight(.medium)
                                            Text(section.rows.count.formatted()).foregroundStyle(.secondary)
                                            Spacer()
                                        }
                                        .font(.system(size: 11))
                                        .padding(.horizontal, 12).frame(height: 24)
                                        .background(AgentDockPalette.panel)
                                        .overlay(alignment: .bottom) { Divider() }
                                    }
                                }
                                if sections.isEmpty { emptyState }
                                if let key = controller.selectedResetKey, controller.reset(for: key) == nil {
                                    Label("This reset is no longer in the latest inventory. Refresh to confirm its status.",
                                        systemImage: "info.circle")
                                        .font(.callout).foregroundStyle(.secondary).padding(16)
                                }
                            }
                        }
                        .onChange(of: controller.selectedResetKey, initial: true) {
                            revealSelectedReset(sections: sections, reader: reader)
                        }
                        .onChange(of: sections.flatMap { $0.rows.map(\.id) }) {
                            revealSelectedReset(sections: sections, reader: reader)
                        }
                        .onChange(of: controller.selectedResetKey) {
                            // Native View Reset actions must remain visible through a previous search/filter.
                            if controller.selectedResetKey != nil { query = ""; onlyExpiringSoon = false }
                        }
                    }
                }
                .frame(width: max(610, geometry.size.width), height: geometry.size.height)
            }
        }
        .padding(.horizontal, 16)
        .overlay(alignment: .top) { Divider().padding(.horizontal, 16) }
    }

    private func revealSelectedReset(sections: [ResetInventorySection], reader: ScrollViewProxy) {
        guard let key = controller.selectedResetKey,
              let row = sections.lazy.flatMap(\.rows).first(where: { $0.key == key }) else { return }
        reader.scrollTo(row.id, anchor: .center)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            !query.isEmpty ? "No matching resets" : onlyExpiringSoon ? "Nothing expiring soon"
                : controller.isRefreshing ? "Checking accounts…"
                : controller.accounts.isEmpty ? "Reset information unavailable" : "No reset details",
            systemImage: "arrow.counterclockwise.circle",
            description: Text(!query.isEmpty ? "Try another account, profile, or reset name."
                : onlyExpiringSoon ? "No reported available resets expire within seven days."
                : controller.accounts.isEmpty ? "Sign in to Codex and refresh."
                : "Check account status below for confirmed counts and missing details."))
            .frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    private func accountStatus(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if controller.scheduleLimited {
                Label("Only the next 60 alerts are scheduled; keep AgentDock running to refresh later reminders.",
                    systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let error = controller.notificationError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            DisclosureGroup(isExpanded: $showsAccountStatus) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(controller.accounts) { account in
                            ResetAccountStatus(account: account, now: now,
                                hasSourceError: account.sourceIDs.contains { controller.sourceErrors[$0] != nil },
                                openAccount: openAccount)
                        }
                        ForEach(controller.sourceErrors.keys.sorted(), id: \.self) { sourceID in
                            Label("\(profileNames[sourceID] ?? "Codex source"): \(controller.sourceErrors[sourceID] ?? "Reset data unavailable")",
                                systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }.padding(.top, 6)
                }.frame(maxHeight: 150)
            } label: {
                HStack(spacing: 6) {
                    Text("Account status")
                    Text("· \(controller.accounts.count) accounts").foregroundStyle(.secondary)
                    let issues = controller.accounts.filter {
                        $0.detailsAreStale || $0.missingDetailCount > 0 || $0.summary.credits == nil
                            || !$0.identityVerified || now.timeIntervalSince($0.checkedAt) > 600
                    }.count + controller.sourceErrors.count
                    if issues > 0 { Text("· \(issues) need attention").foregroundStyle(.orange) }
                    Spacer()
                    if !controller.policy.enabled {
                        Label("Alerts off", systemImage: "bell.slash").foregroundStyle(.secondary)
                            .help("Enable expiration alerts in Settings → Notifications.")
                    }
                    Text(TimeZone.current.abbreviation() ?? "Local time").foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(AgentDockPalette.graphite)
        .overlay(alignment: .top) { Divider().padding(.horizontal, 16) }
    }
}

private struct ResetInventoryColumns {
    let compact: Bool
    var expiration: CGFloat { compact ? 154 : 182 }
    var profile: CGFloat { compact ? 80 : 116 }
    var reset: CGFloat { compact ? 94 : 140 }
    var reminder: CGFloat { compact ? 76 : 96 }
    var spacing: CGFloat { compact ? 6 : 10 }
}

private struct ResetColumnHeadings: View {
    @Binding var sort: ResetInventorySort
    let columns: ResetInventoryColumns
    var body: some View {
        HStack(spacing: columns.spacing) {
            Button {
                sort = sort == .soonest ? .latest : .soonest
            } label: {
                HStack(spacing: 4) {
                    Text("Expires")
                    Image(systemName: sort == .latest ? "chevron.down" : "chevron.up")
                }
            }
            .buttonStyle(.plain).frame(width: columns.expiration, alignment: .leading)
            .accessibilityLabel("Sort by expiration, \(sort.rawValue)")
            Text("Account").frame(maxWidth: .infinity, alignment: .leading)
            Text("Profile").frame(width: columns.profile, alignment: .leading)
            Text("Reset").frame(width: columns.reset, alignment: .leading)
            Text("Reminder").frame(width: columns.reminder, alignment: .leading)
            Color.clear.frame(width: 24).accessibilityHidden(true)
        }
        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        .padding(.horizontal, 12).frame(height: 27)
        .background(AgentDockPalette.panel)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct ResetAccountStatus: View {
    let account: ResetAccount
    let now: Date
    let hasSourceError: Bool
    let openAccount: (ResetAccount) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(account.accountName).fontWeight(.medium)
                Text("· \(account.displayName)").foregroundStyle(.secondary)
                Spacer()
                Text("\(account.summary.availableCount) reported available").monospacedDigit()
                Button("Open Codex") { openAccount(account) }.controlSize(.mini)
            }
            Text("Checked \(account.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                .foregroundStyle(.secondary)
            if account.detailsAreStale || now.timeIntervalSince(account.checkedAt) > 600 || hasSourceError {
                Label("Last known data; availability may have changed.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if !account.identityVerified {
                Text("Account identity unavailable; this profile is separate and may duplicate another account.")
                    .foregroundStyle(.secondary)
            }
            if account.summary.credits == nil || account.missingDetailCount > 0 {
                Text("\(account.summary.availableCount) available; expiration details for \(account.detailCount). Refresh to check missing details.")
                    .foregroundStyle(.secondary)
            }
            if account.summary.availableCount == 0 {
                Text("No available banked resets.").foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
    }
}

private struct ResetCreditRow: View {
    @ObservedObject var controller: ResetReminderController
    let row: ResetInventoryRow
    let now: Date
    let openAccount: (ResetAccount) -> Void
    let columns: ResetInventoryColumns
    @State private var showsCustomSnooze = false
    @State private var snoozeDate = Date().addingTimeInterval(3600)
    @State private var snoozeError = false
    @State private var hovering = false

    private var state: ResetReminderState { controller.state(for: row.key) }
    private var stale: Bool {
        row.account.detailsAreStale || now.timeIntervalSince(row.account.checkedAt) > 600
            || row.account.sourceIDs.contains { controller.sourceErrors[$0] != nil }
    }

    private var expiresWithinDay: Bool {
        row.credit.isAvailable(at: now) && row.credit.expiresAt.map { $0 <= now.addingTimeInterval(86400) } == true
    }

    var body: some View {
        HStack(spacing: columns.spacing) {
            expiration.frame(width: columns.expiration, alignment: .leading)
            HStack(spacing: 4) {
                Text(row.account.accountName).lineLimit(1)
                if stale {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        .help("Last known data; availability may have changed.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(row.account.accountName + (stale ? " · Last known data" : ""))
            Text(row.profileName).lineLimit(1)
                .frame(width: columns.profile, alignment: .leading).foregroundStyle(.secondary).help(row.profileName)
            Text(row.credit.title ?? "Banked reset").lineLimit(1)
                .frame(width: columns.reset, alignment: .leading)
                .help("\(row.credit.title ?? "Banked reset")\n\(row.credit.description ?? row.credit.resetType)\nGranted \(row.credit.grantedAt.formatted(date: .abbreviated, time: .shortened))\nStatus: \(row.credit.status)")
            Text(reminderText).lineLimit(1).foregroundStyle(.secondary)
                .frame(width: columns.reminder, alignment: .leading).help(reminderHelp)
            actions.frame(width: 24)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12).frame(height: 32)
        .background(controller.selectedResetKey == row.key ? AgentDockPalette.selection
            : hovering ? Color.primary.opacity(0.035)
            : expiresWithinDay ? Color.orange.opacity(0.065) : .clear)
        .overlay(alignment: .leading) {
            if row.expiresSoon(at: now) {
                Rectangle().fill(.orange.opacity(expiresWithinDay ? 1 : 0.45)).frame(width: expiresWithinDay ? 3 : 2)
            }
        }
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.credit.title ?? "Banked reset"), \(row.account.accountName), \(row.profileName)")
    }

    private var expiration: some View {
        HStack(spacing: 5) {
            if let expiry = row.credit.expiresAt {
                Text(expiry.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .monospacedDigit().lineLimit(1)
                if row.credit.isAvailable(at: now), row.expiresSoon(at: now) {
                    Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(.orange)
                    Text(timeLeft(until: expiry)).font(.system(size: 10, weight: .medium)).monospacedDigit()
                } else if expiry <= now {
                    Text("Expired").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else {
                Text("Not reported").foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .help(row.credit.expiresAt.map { "Expires \($0.formatted(date: .complete, time: .shortened))" }
            ?? "No expiration reported by Codex.")
        .accessibilityElement(children: .combine)
    }

    private func timeLeft(until date: Date) -> String {
        let minutes = max(1, Int(ceil(date.timeIntervalSince(now) / 60)))
        if minutes < 60 { return "\(minutes)m left" }
        if minutes < 1440 { return "\(minutes / 60)h left" }
        return "\(minutes / 1440)d left"
    }

    private var reminderText: String {
        if !row.credit.isAvailable(at: now) {
            return row.credit.expiresAt.map { $0 <= now } == true ? "Expired" : row.credit.status
        }
        if row.credit.resetType != "codexRateLimits" { return "Unsupported" }
        if state.stopped { return "Stopped" }
        if let date = state.snoozedUntil, date > now { return "Snoozed" }
        if !controller.policy.enabled { return "Alerts off" }
        if row.credit.expiresAt == nil { return "No expiry" }
        if let date = controller.nextReminders[row.key] { return "In \(timeLeft(until: date).replacingOccurrences(of: " left", with: ""))" }
        return "No alert"
    }

    private var reminderHelp: String {
        if let date = state.snoozedUntil, date > now {
            return "Snoozed until \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        if let date = controller.nextReminders[row.key], controller.policy.enabled {
            return "Next reminder \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        return reminderText
    }

    private var actions: some View {
        Menu {
            Button("Open Codex") { openAccount(row.accountToOpen) }
            if row.credit.isAvailable(at: now), row.credit.expiresAt != nil,
               row.credit.resetType == "codexRateLimits" {
                Divider()
                Menu("Snooze") {
                    Button("1 hour") { snooze(hours: 1) }
                    Button("4 hours") { snooze(hours: 4) }
                    Button("Tomorrow") { snooze(hours: 24) }
                    Button("Choose time…") {
                        snoozeDate = min(Date().addingTimeInterval(3600), (row.credit.expiresAt ?? .distantFuture).addingTimeInterval(-60))
                        showsCustomSnooze = true
                    }
                }
                if state.stopped || (state.snoozedUntil.map { $0 > now } ?? false) {
                    Button("Resume Now") { controller.resume(key: row.key) }
                } else {
                    Button("Stop Reminders") { controller.stop(key: row.key) }
                }
            }
        } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Actions for \(row.credit.title ?? "reset") on \(row.profileName)")
        .sheet(isPresented: $showsCustomSnooze) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Snooze this reset").font(.headline)
                DatePicker("Resume reminders", selection: $snoozeDate)
                Text("Choose a time before the reset expires.").foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { showsCustomSnooze = false }
                    Spacer()
                    Button("Snooze") {
                        if controller.snooze(key: row.key, until: snoozeDate) { showsCustomSnooze = false }
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
        snoozeError = !controller.snooze(key: row.key, until: Date().addingTimeInterval(Double(hours) * 3600))
    }
}
