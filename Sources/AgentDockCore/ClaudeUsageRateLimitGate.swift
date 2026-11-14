import Foundation
import Synchronization

/// The decision made before a live Claude usage request is sent.
enum ClaudeUsageGate: Equatable, Sendable {
    case fetch
    case reuseCached
    case backingOff
    case rateLimited(until: Date)
}

/// Provider 429 cooldowns that survive relaunch. Keys are SHA-256 digests of
/// account identity, or of the token when there is no identity; never raw
/// identifiers. Only those digests and expiry timestamps are stored; tokens,
/// identities, and paths never are. This is operational state rather than a
/// preference, so restoring defaults keeps it.
struct ClaudeUsageCooldownStore: @unchecked Sendable {
    static let maximumEntries = 32
    static let maximumBytes = 16 * 1_024

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "AgentDock.claudeUsage.rateLimitCooldowns"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func blockedUntil(key digest: String, now: Date) -> Date? {
        guard Self.isDigest(digest) else { return nil }
        let (entries, changed) = load(now: now)
        if changed { save(entries) }
        return entries[digest].map(Date.init(timeIntervalSince1970:))
    }

    func record(key digest: String, until: Date, now: Date) {
        guard Self.isDigest(digest) else { return }
        let ceiling = now.addingTimeInterval(ClaudeUsageRefreshPolicy.maximumRateLimitCooldown)
        let deadline = min(until, ceiling).timeIntervalSince1970
        guard deadline.isFinite, deadline > now.timeIntervalSince1970 else { return }
        var entries = load(now: now).entries
        let value = max(entries[digest] ?? 0, deadline)
        entries[digest] = value
        if entries.count > Self.maximumEntries {
            // Keep the new deadline and drop the soonest-expiring others.
            let others = entries
                .filter { $0.key != digest }
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(Self.maximumEntries - 1)
            entries = Dictionary(uniqueKeysWithValues: others.map { ($0.key, $0.value) })
            entries[digest] = value
        }
        save(entries)
    }

    func clear(key digest: String) {
        guard Self.isDigest(digest) else { return }
        var entries = load(now: Date()).entries
        guard entries.removeValue(forKey: digest) != nil else { return }
        save(entries)
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    /// Returns unexpired, clamped entries and whether they differ from storage.
    /// Invalid keys and values are never carried forward.
    private func load(now: Date) -> (entries: [String: Double], changed: Bool) {
        guard let data = defaults.data(forKey: key) else { return ([:], false) }
        guard data.count <= Self.maximumBytes,
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data)
        else { return ([:], true) }
        let current = now.timeIntervalSince1970
        let ceiling = current + ClaudeUsageRefreshPolicy.maximumRateLimitCooldown
        var entries: [String: Double] = [:]
        for (digest, deadline) in decoded
        where Self.isDigest(digest) && deadline.isFinite && deadline > current {
            entries[digest] = min(deadline, ceiling)
        }
        return (entries, entries != decoded)
    }

    private func save(_ entries: [String: Double]) {
        var entries = entries
        while entries.count > Self.maximumEntries,
              let soonest = entries.min(by: { $0.value < $1.value })?.key
        {
            entries.removeValue(forKey: soonest)
        }
        while !entries.isEmpty {
            guard let data = try? JSONEncoder().encode(entries) else { return }
            if data.count <= Self.maximumBytes {
                defaults.set(data, forKey: key)
                return
            }
            if let soonest = entries.min(by: { $0.value < $1.value })?.key {
                entries.removeValue(forKey: soonest)
            }
        }
        defaults.removeObject(forKey: key)
    }
}

/// Credential keys (identity and token digest) whose account identity has already
/// been verified with the provider in this process.
struct ClaudeIdentityVerificationLedger: Sendable {
    static let capacity = 64

    private var keys: Set<String> = []

    init() {}

    func isVerified(_ key: String) -> Bool {
        keys.contains(key)
    }

    mutating func markVerified(_ key: String) {
        if !keys.contains(key), keys.count >= Self.capacity {
            keys.removeAll()
        }
        keys.insert(key)
    }

    mutating func invalidate(_ key: String) {
        keys.remove(key)
    }
}

/// At most `limit` Claude Code usage fetches per account in any rolling hour,
/// on top of the freshness, backoff, and cooldown gates. Keys are the same
/// account-identity digests the 429 cooldowns use. In memory only.
struct ClaudeUsageRequestBudget: Sendable {
    static let limit = 30
    static let window: TimeInterval = 60 * 60
    static let maximumAccounts = 64

    private var sent: [String: [Date]] = [:]

    init() {}

    /// Records one fetch for `key` and returns true, or returns false when the
    /// account has already used its budget for the past hour.
    mutating func reserve(key: String, now: Date) -> Bool {
        prune(now: now)
        var times = sent[key] ?? []
        guard times.count < Self.limit else { return false }
        if sent[key] == nil, sent.count >= Self.maximumAccounts,
           let oldest = sent.min(by: { ($0.value.last ?? .distantPast) < ($1.value.last ?? .distantPast) })?.key
        {
            sent.removeValue(forKey: oldest)
        }
        times.append(now)
        sent[key] = times
        return true
    }

    /// When the next fetch for `key` is allowed; nil while budget remains.
    func nextAvailable(key: String, now: Date) -> Date? {
        let times = (sent[key] ?? []).filter { now.timeIntervalSince($0) < Self.window }
        guard times.count >= Self.limit, let oldest = times.first else { return nil }
        return oldest.addingTimeInterval(Self.window)
    }

    func used(key: String, now: Date) -> Int {
        (sent[key] ?? []).filter { now.timeIntervalSince($0) < Self.window }.count
    }

    private mutating func prune(now: Date) {
        for (key, times) in sent {
            let recent = times.filter { now.timeIntervalSince($0) < Self.window }
            sent[key] = recent.isEmpty ? nil : recent
        }
    }
}

/// Bounds Claude Code usage fetches across accounts: at most
/// `maximumConcurrent` at once, and starts spaced `spacing` apart so accounts
/// are not polled together. Slots are granted in arrival order.
final class ClaudeRequestThrottle: Sendable {
    private struct State {
        var active = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
        var nextStart: ContinuousClock.Instant?
    }

    let maximumConcurrent: Int
    let spacing: Duration
    private let state = Mutex(State())

    init(maximumConcurrent: Int, spacing: Duration) {
        self.maximumConcurrent = max(1, maximumConcurrent)
        self.spacing = max(.zero, spacing)
    }

    /// Waits for a slot, then for this start's turn. Pair with `release()`.
    func acquire() async {
        let limit = maximumConcurrent
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let granted: Bool = state.withLock { current in
                if current.active < limit {
                    current.active += 1
                    return true
                }
                current.waiters.append(continuation)
                return false
            }
            if granted { continuation.resume() }
        }
        let gap = spacing
        let delay: Duration = state.withLock { current in
            let now = ContinuousClock.now
            let start = max(now, current.nextStart ?? now)
            current.nextStart = start.advanced(by: gap)
            return start - now
        }
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
    }

    func release() {
        let next: CheckedContinuation<Void, Never>? = state.withLock { current in
            // A waiting caller takes over the slot, so `active` stays the same.
            if !current.waiters.isEmpty { return current.waiters.removeFirst() }
            current.active = max(0, current.active - 1)
            return nil
        }
        next?.resume()
    }
}

/// One holder per key at a time; later callers for the same key wait in order.
/// Keeps each account to a single in-flight Claude Code request.
final class ClaudeKeyedExclusion<Key: Hashable & Sendable>: Sendable {
    private struct State {
        var busy: Set<Key> = []
        var waiters: [Key: [CheckedContinuation<Void, Never>]] = [:]
    }

    private let state = Mutex(State())

    init() {}

    func acquire(_ key: Key) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let granted: Bool = state.withLock { current in
                guard current.busy.contains(key) else {
                    current.busy.insert(key)
                    return true
                }
                current.waiters[key, default: []].append(continuation)
                return false
            }
            if granted { continuation.resume() }
        }
    }

    func release(_ key: Key) {
        let next: CheckedContinuation<Void, Never>? = state.withLock { current in
            if var queue = current.waiters[key], !queue.isEmpty {
                let first = queue.removeFirst()
                current.waiters[key] = queue.isEmpty ? nil : queue
                // The key stays busy for the waiter that takes over.
                return first
            }
            current.busy.remove(key)
            return nil
        }
        next?.resume()
    }
}
