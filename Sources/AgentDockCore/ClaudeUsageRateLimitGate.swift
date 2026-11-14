import Foundation

/// The decision made before a live Claude usage request is sent.
enum ClaudeUsageGate: Equatable, Sendable {
    case fetch
    case reuseCached
    case backingOff
    case rateLimited(until: Date)
}

/// Provider 429 cooldowns that survive relaunch. Only SHA-256 token digests and
/// expiry timestamps are stored; tokens, identities, and paths never are. This is
/// operational state rather than a preference, so restoring defaults keeps it.
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

    func blockedUntil(tokenDigest: String, now: Date) -> Date? {
        guard Self.isDigest(tokenDigest) else { return nil }
        let (entries, changed) = load(now: now)
        if changed { save(entries) }
        return entries[tokenDigest].map(Date.init(timeIntervalSince1970:))
    }

    func record(tokenDigest: String, until: Date, now: Date) {
        guard Self.isDigest(tokenDigest) else { return }
        let ceiling = now.addingTimeInterval(ClaudeUsageRefreshPolicy.maximumRateLimitCooldown)
        let deadline = min(until, ceiling).timeIntervalSince1970
        guard deadline.isFinite, deadline > now.timeIntervalSince1970 else { return }
        var entries = load(now: now).entries
        let value = max(entries[tokenDigest] ?? 0, deadline)
        entries[tokenDigest] = value
        if entries.count > Self.maximumEntries {
            // Keep the new deadline and drop the soonest-expiring others.
            let others = entries
                .filter { $0.key != tokenDigest }
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(Self.maximumEntries - 1)
            entries = Dictionary(uniqueKeysWithValues: others.map { ($0.key, $0.value) })
            entries[tokenDigest] = value
        }
        save(entries)
    }

    func clear(tokenDigest: String) {
        guard Self.isDigest(tokenDigest) else { return }
        var entries = load(now: Date()).entries
        guard entries.removeValue(forKey: tokenDigest) != nil else { return }
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
