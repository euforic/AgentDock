import CryptoKit
import Foundation

/// Banked resets are separate from usage windows and pay-as-you-go credits.
public struct ResetCreditsSummary: Codable, Equatable, Sendable {
    public var availableCount: Int
    public var credits: [ResetCredit]?

    public init(availableCount: Int, credits: [ResetCredit]?) {
        self.availableCount = max(0, availableCount)
        self.credits = credits
    }
}

public struct ResetCredit: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var resetType: String
    public var status: String
    public var grantedAt: Date
    public var expiresAt: Date?
    public var title: String?
    public var description: String?

    public init(id: String, resetType: String = "codexRateLimits", status: String = "available",
                grantedAt: Date, expiresAt: Date?, title: String? = nil, description: String? = nil) {
        self.id = id
        self.resetType = resetType
        self.status = status
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.title = title
        self.description = description
    }

    public func isAvailable(at now: Date) -> Bool {
        status == "available" && (expiresAt.map { $0 > now } ?? true)
    }
}

public struct ResetAccount: Codable, Equatable, Identifiable, Sendable {
    /// Hash provider identity; never use names or paths as account identity.
    public var id: String
    public var sourceIDs: [String]
    public var identityVerified = false
    public var detailsAreStale = false
    public var names: [String]
    /// Display-only metadata. Account identity still comes from the provider ID.
    public var accountEmail: String?
    public var sourceNames: [String: String]?
    public var summary: ResetCreditsSummary
    public var checkedAt: Date

    public init(id: String, sourceIDs: [String], names: [String], summary: ResetCreditsSummary,
                checkedAt: Date, identityVerified: Bool = false) {
        self.id = id
        self.sourceIDs = sourceIDs
        self.names = names
        self.summary = summary
        self.checkedAt = checkedAt
        self.identityVerified = identityVerified
    }

    public var displayName: String { names.joined(separator: ", ") }
    public var accountName: String {
        accountEmail ?? (identityVerified ? "Account \(id.prefix(8))" : "Account unavailable")
    }
    public var detailCount: Int { Set((summary.credits ?? []).map(\.id)).count }
    public var missingDetailCount: Int { max(0, summary.availableCount - detailCount) }

    public mutating func retainUnavailableDetails(from previous: Self?) {
        guard summary.credits == nil, summary.availableCount > 0, previous?.id == id,
              let credits = previous?.summary.credits else { return }
        summary.credits = credits
        detailsAreStale = true
    }

    public static func identity(accountID: String?, sourceID: String) -> String {
        opaqueID(accountID.map { "account:\($0)" } ?? "source:\(sourceID)")
    }

    public static func opaqueID(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func key(for credit: ResetCredit) -> String {
        Self.opaqueID(id + ":" + credit.id)
    }

    /// Keep the latest snapshot's authoritative count; profile aliases never add quota.
    public static func consolidated(_ accounts: [Self]) -> [Self] {
        Dictionary(grouping: accounts, by: \.id).values.compactMap { group in
            guard var newest = group.max(by: { $0.checkedAt < $1.checkedAt }) else { return nil }
            newest.sourceIDs = Array(Set(group.flatMap(\.sourceIDs))).sorted()
            newest.names = Array(Set(group.flatMap(\.names))).sorted()
            newest.sourceNames = group.sorted { $0.checkedAt > $1.checkedAt }.reduce(into: [String: String]()) { result, account in
                result.merge(account.sourceNames ?? [:]) { existing, _ in existing }
            }
            if let credits = newest.summary.credits {
                newest.summary.credits = Dictionary(grouping: credits, by: \.id)
                    .compactMap { $0.value.first }
                    .sorted { ($0.expiresAt ?? .distantFuture, $0.id) < ($1.expiresAt ?? .distantFuture, $1.id) }
            }
            return newest
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}

public struct ResetReminderPolicy: Codable, Equatable, Sendable {
    public var enabled = false
    public var warningMinutes = [7 * 24 * 60, 24 * 60, 60]
    /// Zero means reminders only at the selected warning times.
    public var repeatHours = 0
    public var snoozeMinutes = 60
    public var sound = true
    public var quietHours = false
    public var quietStartHour = 22
    public var quietEndHour = 8

    public init() {}

    public var validated: Self {
        var value = self
        value.warningMinutes = Array(Set(warningMinutes.filter { (1...525600).contains($0) })).sorted(by: >)
        value.repeatHours = min(max(0, repeatHours), 24 * 365)
        value.snoozeMinutes = min(max(1, snoozeMinutes), 7 * 24 * 60)
        value.quietStartHour = min(max(0, quietStartHour), 23)
        value.quietEndHour = min(max(0, quietEndHour), 23)
        return value
    }
}

public struct ResetReminderState: Codable, Equatable, Sendable {
    public var snoozedUntil: Date?
    public var stopped = false
    /// Already submitted milestones must not become duplicate catch-up alerts.
    public var scheduledThrough: Date?
    public init() {}
}

public struct ResetReminder: Equatable, Identifiable, Sendable {
    public var id: String
    public var resetKey: String
    public var accountID: String
    public var fireAt: Date
    public var milestone: Date
    public var expiresAt: Date

    public init(id: String, resetKey: String, accountID: String, fireAt: Date, milestone: Date, expiresAt: Date) {
        self.id = id
        self.resetKey = resetKey
        self.accountID = accountID
        self.fireAt = fireAt
        self.milestone = milestone
        self.expiresAt = expiresAt
    }
}

public enum ResetReminderPlanner {
    /// Finite one-shot requests; never install a repeating trigger that outlives a credit.
    public static func reminders(account: ResetAccount, credit: ResetCredit,
                                 policy: ResetReminderPolicy, state: ResetReminderState,
                                 now: Date, calendar: Calendar = .current) -> [ResetReminder] {
        let policy = policy.validated
        guard policy.enabled, credit.isAvailable(at: now), credit.resetType == "codexRateLimits",
              let expiry = credit.expiresAt, !state.stopped else { return [] }
        var milestones = policy.warningMinutes.map { expiry.addingTimeInterval(-Double($0) * 60) }
        guard let start = milestones.min() else { return [] }
        if policy.repeatHours > 0 {
            var date = start.addingTimeInterval(Double(policy.repeatHours) * 3600)
            // Policy validation bounds this loop to at most 8,760 entries.
            while date < expiry {
                milestones.append(date)
                date = date.addingTimeInterval(Double(policy.repeatHours) * 3600)
            }
        }
        let snooze = state.snoozedUntil.flatMap { $0 > now ? $0 : nil }
        let adjusted = Set(milestones.map {
            quietAdjusted($0, expiry: expiry, policy: policy, calendar: calendar)
        }).sorted()
        // One catch-up for newly discovered overdue milestones, never a backlog.
        let past = adjusted.last { $0 <= now && $0 > (state.scheduledThrough ?? .distantPast) }
        var dates = adjusted.filter { $0 > now }
        if let past { dates.insert(past, at: 0) }
        if let snooze {
            dates.removeAll { $0 < snooze }
            dates.append(snooze)
        }
        let key = account.key(for: credit)
        return Set(dates).sorted().compactMap { milestone in
            let earliest = max(milestone, now.addingTimeInterval(2))
            let fireAt = max(now.addingTimeInterval(2), quietAdjusted(earliest, expiry: expiry, policy: policy, calendar: calendar))
            guard fireAt < expiry else { return nil }
            let id = "reset." + ResetAccount.opaqueID("\(key):\(expiry.timeIntervalSince1970):\(milestone.timeIntervalSince1970)")
            return ResetReminder(id: id, resetKey: key, accountID: account.id,
                                 fireAt: fireAt, milestone: milestone, expiresAt: expiry)
        }
    }

    public static func shouldKeepCatchUp(milestone: Date, fireAt: Date, expiresAt: Date,
                                        credit: ResetCredit, policy: ResetReminderPolicy,
                                        state: ResetReminderState, now: Date) -> Bool {
        policy.enabled && credit.isAvailable(at: now) && credit.resetType == "codexRateLimits"
            && credit.expiresAt == expiresAt && milestone <= now && fireAt > now && fireAt < expiresAt
            && (state.scheduledThrough.map { $0 >= milestone } ?? false)
            && !state.stopped && (state.snoozedUntil.map { $0 <= fireAt } ?? true)
    }

    private static func quietAdjusted(_ date: Date, expiry: Date, policy: ResetReminderPolicy,
                                      calendar: Calendar) -> Date {
        guard policy.quietHours, policy.quietStartHour != policy.quietEndHour else { return date }
        let hour = calendar.component(.hour, from: date)
        let overnight = policy.quietStartHour > policy.quietEndHour
        let quiet = overnight ? hour >= policy.quietStartHour || hour < policy.quietEndHour
            : hour >= policy.quietStartHour && hour < policy.quietEndHour
        guard quiet else { return date }
        guard let end = calendar.nextDate(after: date, matching: DateComponents(hour: policy.quietEndHour),
                                          matchingPolicy: .nextTime) else { return date }
        if end < expiry { return end }
        // Warn before quiet hours rather than silently deferring beyond expiration.
        var start = calendar.date(bySettingHour: policy.quietStartHour, minute: 0, second: 0, of: date) ?? date
        if start > date { start = calendar.date(byAdding: .day, value: -1, to: start) ?? start }
        return start.addingTimeInterval(-60)
    }
}

/// Only local metadata and reminder preferences. Credentials and paths are never persisted here.
public struct ResetReminderStore {
    private let defaults: UserDefaults
    private let key: String
    public init(defaults: UserDefaults = .standard, key: String = "AgentDock.resetReminders") {
        self.defaults = defaults
        self.key = key
    }

    public struct Snapshot: Codable, Equatable, Sendable {
        public var policy = ResetReminderPolicy()
        public var states: [String: ResetReminderState] = [:]
        public var accounts: [ResetAccount] = []
        public init() {}
    }

    public func load() -> Snapshot {
        guard let data = defaults.data(forKey: key), data.count <= 2_097_152,
              let value = try? JSONDecoder().decode(Snapshot.self, from: data) else { return Snapshot() }
        return value
    }

    public func save(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot), data.count <= 2_097_152 else { return }
        defaults.set(data, forKey: key)
    }
}
