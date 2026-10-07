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

    func testUsageResetCountdownUsesItsOwnWindowAndNeverGoesNegative() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func window(after seconds: TimeInterval?) -> HomeUsageWindow {
            HomeUsageWindow(id: "codex.secondary", title: "Weekly", usage: RateLimitWindowUsage(
                usedPercent: 8, windowDurationMins: 10080,
                resetsAt: seconds.map { now.addingTimeInterval($0) }))
        }
        XCTAssertEqual(window(after: nil).timeRemaining(at: now), "Reset time unavailable")
        XCTAssertEqual(window(after: .infinity).timeRemaining(at: now), "Reset time unavailable")
        XCTAssertEqual(window(after: -60).timeRemaining(at: now), "Reset due · Refresh usage")
        XCTAssertEqual(window(after: 0).timeRemaining(at: now), "Reset due · Refresh usage")
        XCTAssertEqual(window(after: 1).timeRemaining(at: now), "1m left")
        XCTAssertEqual(window(after: 59 * 60).timeRemaining(at: now), "59m left")
        XCTAssertEqual(window(after: 3 * 3600 + 15 * 60).timeRemaining(at: now), "3h 15m left")
        let weekly = window(after: 2 * 86400 + 3 * 3600)
        XCTAssertEqual(weekly.timeRemaining(at: now), "2d 3h left")
        XCTAssertEqual(weekly.timeRemaining(at: now.addingTimeInterval(3600)), "2d 2h left")
    }

    func testUsageWindowSummaryPreservesProviderBucketsAndDurations() throws {
        let data = Data("""
        {"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":32,"windowDurationMins":300,"resetsAt":1800000300},"secondary":{"usedPercent":58,"windowDurationMins":10080,"resetsAt":1800259200}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":32,"windowDurationMins":300,"resetsAt":1800000300},"secondary":{"usedPercent":58,"windowDurationMins":10080,"resetsAt":1800259200}},"custom":{"limitId":"custom","limitName":"Research","primary":{"usedPercent":17,"windowDurationMins":1440}}}}}
        """.utf8)
        let limits = try RateLimitParser.parseResponse(data)
        let windows = HomeUsageWindow.windows(in: limits)
        XCTAssertEqual(windows.map(\.title), ["5-hour", "Weekly", "Research · 1-day"])
        XCTAssertEqual(windows.map(\.usage.usedPercent), [32, 58, 17])
        XCTAssertEqual(windows.map(\.usage.resetsAt), [
            Date(timeIntervalSince1970: 1_800_000_300),
            Date(timeIntervalSince1970: 1_800_259_200), nil
        ])
        XCTAssertEqual(Set(windows.map(\.id)).count, 3)
    }
}
