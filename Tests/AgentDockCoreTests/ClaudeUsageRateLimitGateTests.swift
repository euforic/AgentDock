import Foundation
import XCTest
@testable import AgentDockCore

final class ClaudeUsageRateLimitGateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    func testCooldownPersistsAcrossStoreInstancesKeyedByDigest() throws {
        let defaults = try makeDefaults()
        let first = ClaudeUsageCredential.digest("synthetic-token-one")
        let second = ClaudeUsageCredential.digest("synthetic-token-two")

        ClaudeUsageCooldownStore(defaults: defaults).record(
            key: first,
            until: now.addingTimeInterval(600),
            now: now
        )

        let reopened = ClaudeUsageCooldownStore(defaults: defaults)
        XCTAssertEqual(reopened.blockedUntil(key: first, now: now), now.addingTimeInterval(600))
        XCTAssertNil(reopened.blockedUntil(key: second, now: now))

        reopened.clear(key: first)
        XCTAssertNil(ClaudeUsageCooldownStore(defaults: defaults).blockedUntil(key: first, now: now))

        // Only digests and timestamps are stored.
        let stored = String(describing: defaults.dictionaryRepresentation())
        XCTAssertFalse(stored.contains("synthetic-token-one"))
    }

    func testCooldownKeepsLaterDeadlineAndPurgesExpired() throws {
        let defaults = try makeDefaults()
        let store = ClaudeUsageCooldownStore(defaults: defaults)
        let digest = ClaudeUsageCredential.digest("synthetic-token")

        store.record(key: digest, until: now.addingTimeInterval(600), now: now)
        store.record(key: digest, until: now.addingTimeInterval(100), now: now)
        XCTAssertEqual(store.blockedUntil(key: digest, now: now), now.addingTimeInterval(600))

        // Reading after expiry removes the entry from storage.
        XCTAssertNil(store.blockedUntil(key: digest, now: now.addingTimeInterval(601)))
        XCTAssertNil(store.blockedUntil(key: digest, now: now))

        // A deadline already in the past is not recorded.
        store.record(key: digest, until: now.addingTimeInterval(-1), now: now)
        XCTAssertNil(store.blockedUntil(key: digest, now: now))

        // The store is bounded; the newest deadline is always kept.
        for index in 0..<40 {
            store.record(
                key: ClaudeUsageCredential.digest("synthetic-token-\(index)"),
                until: now.addingTimeInterval(1_000 + Double(index)),
                now: now
            )
        }
        store.record(key: digest, until: now.addingTimeInterval(500), now: now)
        XCTAssertEqual(store.blockedUntil(key: digest, now: now), now.addingTimeInterval(500))
        XCTAssertNil(store.blockedUntil(
            key: ClaudeUsageCredential.digest("synthetic-token-0"),
            now: now
        ))
        XCTAssertNotNil(store.blockedUntil(
            key: ClaudeUsageCredential.digest("synthetic-token-39"),
            now: now
        ))
    }

    func testCooldownClampsFarFutureAndRejectsNonDigestKeys() throws {
        let defaults = try makeDefaults()
        let key = "AgentDock.claudeUsage.rateLimitCooldowns"
        let store = ClaudeUsageCooldownStore(defaults: defaults, key: key)
        let digest = ClaudeUsageCredential.digest("synthetic-token")
        let ceiling = now.addingTimeInterval(ClaudeUsageRefreshPolicy.maximumRateLimitCooldown)

        store.record(key: digest, until: now.addingTimeInterval(30 * 86_400), now: now)
        XCTAssertEqual(store.blockedUntil(key: digest, now: now), ceiling)

        // A stored value from a skewed clock is clamped on read.
        let skewed = ClaudeUsageCredential.digest("synthetic-skewed-token")
        defaults.set(
            try JSONEncoder().encode([
                skewed: now.addingTimeInterval(365 * 86_400).timeIntervalSince1970,
                "synthetic-token": now.addingTimeInterval(600).timeIntervalSince1970,
                digest.uppercased(): now.addingTimeInterval(600).timeIntervalSince1970
            ]),
            forKey: key
        )
        XCTAssertEqual(store.blockedUntil(key: skewed, now: now), ceiling)
        XCTAssertNil(store.blockedUntil(key: "synthetic-token", now: now))
        XCTAssertNil(store.blockedUntil(key: digest.uppercased(), now: now))

        // Non-digest keys are never written.
        store.record(key: "synthetic-token", until: now.addingTimeInterval(600), now: now)
        store.record(key: String(digest.dropLast()), until: now.addingTimeInterval(600), now: now)
        let data = try XCTUnwrap(defaults.data(forKey: key))
        let stored = try JSONDecoder().decode([String: Double].self, from: data)
        XCTAssertEqual(Set(stored.keys), [skewed])
        XCTAssertTrue(stored.keys.allSatisfy(ClaudeUsageCooldownStore.isDigest))
    }

    func testCooldownKeyUsesAccountIdentityPerProjection() {
        let account = "00000000-0000-0000-0000-000000000001"
        let organization = "00000000-0000-0000-0000-000000000002"
        let identity = ClaudeAccountIdentity(accountUUID: account, organizationUUID: organization)
        let first = ClaudeUsageCredential(
            accessToken: "synthetic-token-a",
            scopes: ["user:profile"],
            identity: identity
        )
        var renewed = first
        renewed.accessToken = "synthetic-token-b"

        let key = first.cooldownKey(for: .claudeCode)
        XCTAssertEqual(key, renewed.cooldownKey(for: .claudeCode))
        XCTAssertNotEqual(key, first.tokenDigest)
        XCTAssertNotEqual(key, renewed.tokenDigest)
        XCTAssertNotEqual(key, first.cooldownKey(for: .desktop))
        XCTAssertTrue(ClaudeUsageCooldownStore.isDigest(key))
        XCTAssertTrue(ClaudeUsageCooldownStore.isDigest(first.cooldownKey(for: .desktop)))
        XCTAssertFalse(key.contains(account))
        XCTAssertFalse(key.contains(organization))

        var anonymous = first
        anonymous.identity = nil
        XCTAssertEqual(anonymous.cooldownKey(for: .claudeCode), anonymous.tokenDigest)
        XCTAssertEqual(anonymous.cooldownKey(for: .desktop), anonymous.tokenDigest)
    }

    func testRateLimitCooldownCapsAtOneHour() throws {
        XCTAssertEqual(ClaudeUsageRefreshPolicy.rateLimitCooldown(retryAfter: 7_200), 3_600)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let header = formatter.string(from: now.addingTimeInterval(7_200))
        XCTAssertEqual(
            ClaudeUsageRefreshPolicy.rateLimitCooldown(
                retryAfter: ClaudeUsageRefreshPolicy.retryAfter(header, now: now)
            ),
            3_600
        )

        let store = ClaudeUsageCooldownStore(defaults: try makeDefaults())
        let digest = ClaudeUsageCredential.digest("synthetic-token")
        store.record(key: digest, until: now.addingTimeInterval(7_200), now: now)
        XCTAssertEqual(store.blockedUntil(key: digest, now: now), now.addingTimeInterval(3_600))
    }

    func testIdentityLedgerVerifiesOncePerCredentialAndInvalidates() {
        let identity = ClaudeAccountIdentity(
            accountUUID: "00000000-0000-0000-0000-000000000001",
            organizationUUID: "00000000-0000-0000-0000-000000000002"
        )
        let credential = ClaudeUsageCredential(
            accessToken: "synthetic-token",
            scopes: ["user:profile"],
            identity: identity
        )
        var rotated = credential
        rotated.accessToken = "synthetic-rotated-token"
        var otherAccount = credential
        otherAccount.identity?.accountUUID = "00000000-0000-0000-0000-000000000003"

        var ledger = ClaudeIdentityVerificationLedger()
        XCTAssertFalse(ledger.isVerified(credential.cacheKey))
        ledger.markVerified(credential.cacheKey)
        XCTAssertTrue(ledger.isVerified(credential.cacheKey))
        // A new token or a new identity is checked again.
        XCTAssertFalse(ledger.isVerified(rotated.cacheKey))
        XCTAssertFalse(ledger.isVerified(otherAccount.cacheKey))

        ledger.invalidate(credential.cacheKey)
        XCTAssertFalse(ledger.isVerified(credential.cacheKey))

        // Overflow clears the ledger rather than growing without bound.
        ledger.markVerified(credential.cacheKey)
        for index in 1..<ClaudeIdentityVerificationLedger.capacity {
            ledger.markVerified("synthetic-key-\(index)")
        }
        XCTAssertTrue(ledger.isVerified(credential.cacheKey))
        ledger.markVerified("synthetic-key-overflow")
        XCTAssertFalse(ledger.isVerified(credential.cacheKey))
        XCTAssertTrue(ledger.isVerified("synthetic-key-overflow"))
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "AgentDockTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}
