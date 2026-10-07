import AppKit
import CodexerCore
import SwiftUI
import UserNotifications

struct ResetSource: Equatable, Sendable {
    var id: String
    var name: String
    var homeURL: URL
}

@MainActor
final class ResetReminderController: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var policy: ResetReminderPolicy {
        didSet {
            if policy.enabled && (!oldValue.enabled || policy.warningMinutes != oldValue.warningMinutes
                || policy.repeatHours != oldValue.repeatHours || policy.quietHours != oldValue.quietHours
                || policy.quietStartHour != oldValue.quietStartHour || policy.quietEndHour != oldValue.quietEndHour) {
                for key in snapshot.states.keys { snapshot.states[key]?.scheduledThrough = nil }
            }
            persist()
            requestReconcile()
        }
    }
    @Published private(set) var accounts: [ResetAccount] = []
    @Published private(set) var sourceErrors: [String: String] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var permission = "Not requested"
    @Published private(set) var notificationError: String?
    @Published private(set) var nextReminders: [String: Date] = [:]
    @Published private(set) var scheduleLimited = false
    @Published private(set) var stateVersion = 0
    @Published var selectedResetKey: String?
    @Published var showsAvailableResets = false

    private let store: ResetReminderStore
    private var snapshot: ResetReminderStore.Snapshot
    private var sources: [ResetSource] = []
    private var appURL: URL?
    private var refreshTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var revision = 0
    private nonisolated(unsafe) var wakeObserver: NSObjectProtocol?
    private let workspaceCenter = NSWorkspace.shared.notificationCenter
    private var center: UNUserNotificationCenter?
    private let client = AppServerRateLimitClient()

    init(store: ResetReminderStore = ResetReminderStore(), nativeNotifications: Bool = true) {
        self.store = store
        let saved = store.load()
        snapshot = saved
        policy = saved.policy.validated
        accounts = ResetAccount.consolidated(saved.accounts)
        super.init()
        // NotificationCenter requires an application bundle; command-line tests have none.
        if nativeNotifications, Bundle.main.bundleURL.pathExtension == "app" {
            center = .current()
            center?.delegate = self
            center?.setNotificationCategories([
                UNNotificationCategory(identifier: "reset.expiration", actions: [
                    UNNotificationAction(identifier: "view", title: "View Reset", options: .foreground),
                    UNNotificationAction(identifier: "snooze", title: "Snooze"),
                    UNNotificationAction(identifier: "stop", title: "Stop Reminders")
                ], intentIdentifiers: [], options: .customDismissAction)
            ])
        }
    }

    deinit {
        refreshTask?.cancel()
        pollingTask?.cancel()
        reconciliationTask?.cancel()
        if let wakeObserver { workspaceCenter.removeObserver(wakeObserver) }
    }

    func configure(sources: [ResetSource], appURL: URL) {
        let changed = self.sources != sources || self.appURL != appURL
        self.sources = sources
        self.appURL = appURL
        let ids = Set(sources.map(\.id))
        sourceErrors = sourceErrors.filter { ids.contains($0.key) }
        snapshot.accounts.removeAll { $0.sourceIDs.allSatisfy { !ids.contains($0) } }
        accounts = ResetAccount.consolidated(snapshot.accounts)
        if pollingTask == nil {
            pollingTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(300)) } catch { return }
                    guard let self else { return }
                    // Inventory stays fresh while visible; notifications never depend on activity settings.
                    self.refresh()
                    await self.updatePermission()
                }
            }
            wakeObserver = workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        if changed { refresh() }
        requestReconcile()
        Task { await updatePermission() }
    }

    func refresh() {
        guard let appURL else { return }
        refreshTask?.cancel()
        let sources = sources
        let client = client
        isRefreshing = true
        refreshTask = Task { [weak self] in
            // Serial bounded reads avoid spawning an app-server for every account at once.
            for source in sources {
                let worker = Task.detached(priority: .utility) {
                    client.fetchRateLimits(codexHomeURL: source.homeURL, codexAppURL: appURL)
                }
                let limits = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, let self else { return }
                if let error = limits.errorMessage {
                    // Keep last successful data, clearly labelled as stale in the view.
                    self.sourceErrors[source.id] = error
                } else if let summary = limits.resetCredits {
                    var account = ResetAccount(id: ResetAccount.identity(accountID: limits.accountID, sourceID: source.id),
                        sourceIDs: [source.id], names: [source.name], summary: summary, checkedAt: limits.fetchedAt)
                    account.identityVerified = limits.accountID != nil
                    let old = self.snapshot.accounts.first { $0.sourceIDs.contains(source.id) }
                    account.retainUnavailableDetails(from: old)
                    for credit in summary.credits ?? [] {
                        if let previous = old?.summary.credits?.first(where: { $0.id == credit.id }),
                           previous.expiresAt != credit.expiresAt {
                            self.snapshot.states[account.key(for: credit)]?.scheduledThrough = nil
                        }
                    }
                    self.snapshot.accounts.removeAll { $0.sourceIDs.contains(source.id) }
                    self.snapshot.accounts.append(account)
                    self.sourceErrors.removeValue(forKey: source.id)
                } else {
                    self.snapshot.accounts.removeAll { $0.sourceIDs.contains(source.id) }
                    self.sourceErrors[source.id] = "Reset information is unavailable for this account or CLI version."
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.accounts = ResetAccount.consolidated(self.snapshot.accounts)
            self.isRefreshing = false
            self.pruneStates()
            self.persist()
            self.requestReconcile()
        }
    }

    func state(for key: String) -> ResetReminderState { snapshot.states[key] ?? ResetReminderState() }

    @discardableResult
    func snooze(key: String, until date: Date, now: Date = Date()) -> Bool {
        guard let (_, credit) = reset(for: key), credit.isAvailable(at: now), date > now,
              credit.expiresAt.map({ date < $0 }) ?? true else { return false }
        var state = state(for: key)
        state.snoozedUntil = date
        state.stopped = false
        snapshot.states[key] = state
        stateVersion += 1
        persist()
        requestReconcile()
        return true
    }

    func stop(key: String) {
        var state = state(for: key)
        state.stopped = true
        snapshot.states[key] = state
        stateVersion += 1
        persist()
        requestReconcile()
    }

    func resume(key: String) {
        snapshot.states[key] = ResetReminderState()
        stateVersion += 1
        persist()
        requestReconcile()
    }

    func reset(for key: String) -> (ResetAccount, ResetCredit)? {
        for account in accounts {
            if let credit = account.summary.credits?.first(where: { account.key(for: $0) == key }) {
                return (account, credit)
            }
        }
        return nil
    }

    func enableNotifications() async {
        guard let center else {
            notificationError = "Native alerts are available in the packaged AgentDock application."
            return
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            policy.enabled = granted
            if granted { notificationError = nil }
            if !granted { notificationError = "Allow AgentDock notifications in System Settings to receive alerts." }
            await updatePermission()
        } catch { notificationError = "Notifications could not be enabled: \(error.localizedDescription)" }
    }

    func updatePermission() async {
        guard let center else { permission = "Packaged app required"; return }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: permission = settings.alertSetting == .enabled ? "Allowed" : "Alerts disabled in macOS"
        case .denied: permission = "Blocked in macOS"
        case .notDetermined: permission = "Not requested"
        default: permission = "Unavailable"
        }
    }

    func sendTestNotification() async {
        guard let center else { notificationError = "Run the packaged application to test native alerts."; return }
        await updatePermission()
        guard permission == "Allowed" else { notificationError = "Enable macOS notification permission first."; return }
        let content = UNMutableNotificationContent()
        content.title = "Reset reminders are ready"
        content.body = "This is an AgentDock test notification."
        if policy.sound { content.sound = .default }
        do { try await center.add(UNNotificationRequest(identifier: "reset.test", content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))) }
        catch { notificationError = "Test alert could not be scheduled: \(error.localizedDescription)" }
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func persist() {
        snapshot.policy = policy.validated
        store.save(snapshot)
    }

    private func pruneStates() {
        let keys = Set(accounts.flatMap { account in
            (account.summary.credits ?? []).map { account.key(for: $0) }
        })
        // Partial responses can omit still-available credits. Retain their snooze/stop settings.
        let complete = accounts.allSatisfy { $0.summary.credits != nil && $0.missingDetailCount == 0 }
        if complete, sourceErrors.isEmpty {
            snapshot.states = snapshot.states.filter { keys.contains($0.key) }
        }
    }

    private func requestReconcile() {
        revision += 1
        guard reconciliationTask == nil else { return }
        // Serialize native mutations. Settings changes during an await trigger another pass.
        reconciliationTask = Task { [weak self] in
            guard let self else { return }
            var processed = -1
            while processed != self.revision, !Task.isCancelled {
                processed = self.revision
                await self.reconcile()
            }
            self.reconciliationTask = nil
        }
    }

    private func reconcile() async {
        let now = Date()
        let pending: [UNNotificationRequest]
        if let center {
            pending = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix("reset.") && $0.identifier != "reset.test" }
        } else { pending = [] }
        var planned: [ResetReminder] = []
        for account in accounts {
            for credit in account.summary.credits ?? [] {
                planned += ResetReminderPlanner.reminders(account: account, credit: credit,
                    policy: policy.validated, state: state(for: account.key(for: credit)), now: now)
            }
        }
        // A submitted catch-up has a past milestone but a future native trigger.
        // Keep it until delivery so an immediate refresh cannot cancel the first alert.
        for request in pending where !planned.contains(where: { $0.id == request.identifier }) {
            guard let key = request.content.userInfo["resetKey"] as? String,
                  let milestone = request.content.userInfo["milestone"] as? Double,
                  let expiry = request.content.userInfo["expiresAt"] as? Double,
                  let fireTime = request.content.userInfo["fireAt"] as? Double,
                  let (account, credit) = reset(for: key) else { continue }
            let fireAt = Date(timeIntervalSince1970: fireTime)
            let milestoneDate = Date(timeIntervalSince1970: milestone)
            let expiryDate = Date(timeIntervalSince1970: expiry)
            guard ResetReminderPlanner.shouldKeepCatchUp(milestone: milestoneDate, fireAt: fireAt, expiresAt: expiryDate,
                credit: credit, policy: policy.validated, state: state(for: key), now: now) else { continue }
            planned.append(ResetReminder(id: request.identifier, resetKey: key, accountID: account.id,
                fireAt: fireAt, milestone: milestoneDate, expiresAt: expiryDate))
        }
        planned.sort { ($0.fireAt, $0.id) < ($1.fireAt, $1.id) }
        scheduleLimited = planned.count > 60
        planned = Array(planned.prefix(60))
        nextReminders = Dictionary(grouping: planned, by: \.resetKey).compactMapValues { $0.map(\.fireAt).min() }
        guard let center else { return }
        let desiredIDs = Set(planned.map(\.id))
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { !desiredIDs.contains($0) })
        let existing = Dictionary(uniqueKeysWithValues: pending.map { ($0.identifier, $0) })
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(withIdentifiers: delivered.compactMap { notification in
            guard notification.request.identifier.hasPrefix("reset."),
                  let key = notification.request.content.userInfo["resetKey"] as? String else { return nil }
            let state = state(for: key)
            let snoozed = state.snoozedUntil.map { $0 > now } ?? false
            return reset(for: key)?.1.isAvailable(at: now) == true && !state.stopped && !snoozed ? nil : notification.request.identifier
        })
        for reminder in planned {
            guard let (account, _) = reset(for: reminder.resetKey) else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Codex reset expires soon"
            content.body = "\(account.displayName) · Reset last reported available. Expires \(reminder.expiresAt.formatted(date: .abbreviated, time: .shortened))."
            content.categoryIdentifier = "reset.expiration"
            content.threadIdentifier = "reset.\(account.id)"
            content.userInfo = ["resetKey": reminder.resetKey, "milestone": reminder.milestone.timeIntervalSince1970,
                                "expiresAt": reminder.expiresAt.timeIntervalSince1970, "fireAt": reminder.fireAt.timeIntervalSince1970]
            if policy.validated.sound { content.sound = .default }
            if let old = existing[reminder.id], old.content.body == content.body,
               (old.content.sound != nil) == (content.sound != nil) { continue }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, reminder.fireAt.timeIntervalSinceNow), repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
                var state = state(for: reminder.resetKey)
                state.scheduledThrough = max(state.scheduledThrough ?? .distantPast, reminder.milestone)
                snapshot.states[reminder.resetKey] = state
                notificationError = nil
            } catch { notificationError = "A reset alert could not be scheduled: \(error.localizedDescription)" }
        }
        persist()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        var options: UNNotificationPresentationOptions = [.banner, .list]
        if notification.request.content.sound != nil { options.insert(.sound) }
        completionHandler(options)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let key = response.notification.request.content.userInfo["resetKey"] as? String
        let action = response.actionIdentifier
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            guard let self, let key else { return }
            switch action {
            case "snooze":
                guard self.reset(for: key) != nil else { return }
                let date = Date().addingTimeInterval(Double(self.policy.validated.snoozeMinutes) * 60)
                if !self.snooze(key: key, until: date) {
                    self.notificationError = "This snooze would pass the reset's expiration. Choose a shorter time."
                    self.selectedResetKey = key
                    self.showsAvailableResets = true
                    NSApp.activate(ignoringOtherApps: true)
                }
            case "stop": self.stop(key: key)
            case "view", UNNotificationDefaultActionIdentifier:
                self.selectedResetKey = key
                self.showsAvailableResets = true
                self.refresh()
                NSApp.activate(ignoringOtherApps: true)
            default: break // Dismissing one banner leaves the configured cadence intact.
            }
            // Finish native rescheduling before relinquishing background action time.
            await self.reconciliationTask?.value
        }
    }
}
