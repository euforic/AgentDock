import CodexerCore
import XCTest
@testable import Codexer

final class HomeDashboardTests: XCTestCase {
    func testResetDigestDeduplicatesAccountsAndExcludesExpiredOrUsedCredits() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = ResetAccount(id: "shared", sourceIDs: ["official"], names: ["Official"],
            summary: ResetCreditsSummary(availableCount: 4, credits: [
                ResetCredit(id: "soon", grantedAt: now, expiresAt: now.addingTimeInterval(3600)),
                ResetCredit(id: "expired", grantedAt: now, expiresAt: now),
                ResetCredit(id: "used", status: "used", grantedAt: now, expiresAt: now.addingTimeInterval(60)),
                ResetCredit(id: "unknown", grantedAt: now, expiresAt: nil)
            ]), checkedAt: now, identityVerified: true)
        var alias = account
        alias.sourceIDs = ["managed"]
        alias.names = ["Personal"]
        let digest = HomeResetDigest(accounts: [account, alias], sourceErrors: [:], now: now)
        XCTAssertEqual(digest.reportedCount, 4)
        XCTAssertEqual(digest.expirations.map(\.credit.id), ["soon"])
        XCTAssertTrue(digest.hasUnknownExpirations)
        XCTAssertFalse(digest.hasUnverifiedIdentity)
        XCTAssertFalse(digest.lastKnown)
    }

    func testUnknownInventoryIsDistinctFromConfirmedZeroAndStaleData() {
        let now = Date()
        let missing = HomeResetDigest(accounts: [], sourceErrors: [:], now: now)
        XCTAssertNil(missing.reportedCount)
        let zero = ResetAccount(id: "zero", sourceIDs: ["source"], names: ["Personal"],
            summary: ResetCreditsSummary(availableCount: 0, credits: []), checkedAt: now,
            identityVerified: true)
        XCTAssertEqual(HomeResetDigest(accounts: [zero], sourceErrors: [:], now: now).reportedCount, 0)
        XCTAssertTrue(HomeResetDigest(accounts: [zero], sourceErrors: ["source": "Unavailable"], now: now).lastKnown)
        XCTAssertTrue(HomeResetDigest(accounts: [zero], sourceErrors: [:], now: now.addingTimeInterval(601)).lastKnown)
        var unknown = zero
        unknown.identityVerified = false
        unknown.summary = ResetCreditsSummary(availableCount: 3, credits: nil)
        let digest = HomeResetDigest(accounts: [unknown], sourceErrors: [:], now: now)
        XCTAssertTrue(digest.hasUnknownExpirations)
        XCTAssertTrue(digest.hasUnverifiedIdentity)
    }

    func testProfileResetCountsFollowVerifiedAliasesWithoutBorrowingAnotherAccount() {
        let now = Date()
        let account = ResetAccount(id: "shared", sourceIDs: ["official", "personal"], names: ["Personal"],
            summary: ResetCreditsSummary(availableCount: 2, credits: [
                ResetCredit(id: "soon", grantedAt: now, expiresAt: now.addingTimeInterval(3600))
            ]), checkedAt: now, identityVerified: true)
        for source in ["official", "personal"] {
            let digest = HomeResetDigest(accounts: [account], sourceErrors: ["other": "Unavailable"], now: now, sourceID: source)
            XCTAssertEqual(digest.reportedCount, 2)
            XCTAssertEqual(digest.expirations.count, 1)
            XCTAssertFalse(digest.lastKnown)
        }
        let unrelated = HomeResetDigest(accounts: [account], sourceErrors: [:], now: now, sourceID: "research")
        XCTAssertNil(unrelated.reportedCount)
        XCTAssertTrue(unrelated.expirations.isEmpty)
    }

    func testResetUrgencyUsesOnlyAvailableCreditsWithinTheNext24Hours() {
        let now = Date()
        func digest(expiry: Date, status: String = "available") -> HomeResetDigest {
            let account = ResetAccount(id: "personal", sourceIDs: ["personal"], names: ["Personal"],
                summary: ResetCreditsSummary(availableCount: 1, credits: [
                    ResetCredit(id: "credit", status: status, grantedAt: now, expiresAt: expiry)
                ]), checkedAt: now, identityVerified: true)
            return HomeResetDigest(accounts: [account], sourceErrors: [:], now: now)
        }
        XCTAssertTrue(digest(expiry: now.addingTimeInterval(86400)).hasExpirationWithin24Hours)
        XCTAssertFalse(digest(expiry: now.addingTimeInterval(86401)).hasExpirationWithin24Hours)
        XCTAssertFalse(digest(expiry: now).hasExpirationWithin24Hours)
        XCTAssertFalse(digest(expiry: now.addingTimeInterval(3600), status: "used").hasExpirationWithin24Hours)
    }

    func testUsageWindowSummaryPreservesProviderBucketsAndDurations() throws {
        let data = Data("""
        {"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":32,"windowDurationMins":300},"secondary":{"usedPercent":58,"windowDurationMins":10080}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":32,"windowDurationMins":300},"secondary":{"usedPercent":58,"windowDurationMins":10080}},"custom":{"limitId":"custom","limitName":"Research","primary":{"usedPercent":17,"windowDurationMins":1440}}}}}
        """.utf8)
        let limits = try RateLimitParser.parseResponse(data)
        let windows = HomeUsageWindow.windows(in: limits)
        XCTAssertEqual(windows.map(\.title), ["5-hour", "Weekly", "Research · 1-day"])
        XCTAssertEqual(windows.map(\.usage.usedPercent), [32, 58, 17])
        XCTAssertEqual(Set(windows.map(\.id)).count, 3)
    }
}
