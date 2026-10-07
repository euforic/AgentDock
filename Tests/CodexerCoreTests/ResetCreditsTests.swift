import Foundation
import XCTest
@testable import CodexerCore

final class ResetCreditsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func account(credits: [ResetCredit]?, count: Int = 1, source: String = "first", checked: Date? = nil) -> ResetAccount {
        ResetAccount(id: ResetAccount.identity(accountID: "synthetic-account", sourceID: source),
                     sourceIDs: [source], names: [source], summary: ResetCreditsSummary(availableCount: count, credits: credits),
                     checkedAt: checked ?? now)
    }

    private func credit(hours: Double = 72, status: String = "available", type: String = "codexRateLimits") -> ResetCredit {
        ResetCredit(id: "synthetic-credit", resetType: type, status: status, grantedAt: now.addingTimeInterval(-86400),
                    expiresAt: now.addingTimeInterval(hours * 3600))
    }

    func testParserPreservesProviderResetMetadataAndUnixDates() throws {
        let json = Data("""
        {"result":{"accountId":"synthetic-account","rateLimits":{"limitId":"codex"},
          "rateLimitResetCredits":{"availableCount":4,"credits":[
            {"id":"synthetic-credit","resetType":"codexRateLimits","status":"available",
             "grantedAt":1999900000,"expiresAt":2000100000,"title":"Full reset","description":"Weekly and five-hour"},
            {"id":"future","resetType":"futureType","status":"futureStatus","grantedAt":1999900000,"expiresAt":null}
          ]}}}
        """.utf8)
        let parsed = try RateLimitParser.parseResponse(json, fetchedAt: now)
        XCTAssertEqual(parsed.accountID, "synthetic-account")
        XCTAssertEqual(parsed.resetCredits?.availableCount, 4)
        XCTAssertEqual(parsed.resetCredits?.credits?.first?.expiresAt, Date(timeIntervalSince1970: 2_000_100_000))
        XCTAssertEqual(parsed.resetCredits?.credits?.last?.status, "futureStatus")
        XCTAssertEqual(parsed.resetCredits?.credits?.last?.resetType, "futureType")
        XCTAssertNil(parsed.resetCredits?.credits?.last?.expiresAt)
        XCTAssertEqual(parsed.fetchedAt, now)
    }

    func testUnknownCountIsDifferentFromConfirmedZeroAndMissingDetails() throws {
        for (suffix, expected) in [("", nil), (",\"rateLimitResetCredits\":null", nil),
            (",\"rateLimitResetCredits\":{\"availableCount\":0,\"credits\":[]}", 0),
            (",\"rateLimitResetCredits\":{\"availableCount\":4,\"credits\":null}", 4)] {
            let json = Data("{\"result\":{\"rateLimits\":{},\"rateLimitsByLimitId\":null\(suffix)}}".utf8)
            XCTAssertEqual(try RateLimitParser.parseResponse(json).resetCredits?.availableCount, expected)
        }
        XCTAssertEqual(account(credits: nil, count: 4).missingDetailCount, 4)
        XCTAssertEqual(account(credits: [credit()], count: 4).missingDetailCount, 3)
    }

    func testVerifiedAccountsDeduplicateProfilesAndCreditRows() {
        let first = account(credits: [credit(), credit()], count: 4)
        let second = account(credits: [credit()], count: 3, source: "second", checked: now.addingTimeInterval(1))
        let result = ResetAccount.consolidated([first, second])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.summary.availableCount, 3)
        XCTAssertEqual(result.first?.summary.credits?.count, 1)
        XCTAssertEqual(result.first?.sourceIDs, ["first", "second"])
        XCTAssertNotEqual(ResetAccount.identity(accountID: nil, sourceID: "first"),
                          ResetAccount.identity(accountID: nil, sourceID: "second"))
    }

    func testFiniteDefaultScheduleAndStableIDs() {
        let credit = credit()
        let account = account(credits: [credit])
        var policy = ResetReminderPolicy(); policy.enabled = true
        let result = ResetReminderPlanner.reminders(account: account, credit: credit, policy: policy, state: .init(), now: now)
        XCTAssertEqual(result.first?.fireAt, now.addingTimeInterval(2))
        XCTAssertEqual(result.filter { $0.milestone <= now }.count, 1)
        XCTAssertTrue(result.allSatisfy { $0.fireAt < credit.expiresAt! })
        XCTAssertEqual(Set(result.map(\.id)).count, result.count)
        let next = ResetReminderPlanner.reminders(account: account, credit: credit, policy: policy, state: .init(), now: now.addingTimeInterval(1))
        XCTAssertEqual(result.map(\.id), next.map(\.id))
        var state = ResetReminderState(); state.scheduledThrough = result.last?.milestone
        let repeated = ResetReminderPlanner.reminders(account: account, credit: credit, policy: policy, state: state, now: now)
        XCTAssertFalse(repeated.contains { $0.milestone <= now })
    }

    func testSingleReminderAndNoAlertsForUnsupportedOrUnavailableCredits() {
        var policy = ResetReminderPolicy(); policy.enabled = true
        policy.warningMinutes = [10080]; policy.repeatHours = 0
        let one = credit(hours: 240)
        XCTAssertEqual(ResetReminderPlanner.reminders(account: account(credits: [one]), credit: one, policy: policy, state: .init(), now: now).count, 1)
        for item in [credit(hours: -1), credit(status: "redeemed"), credit(status: "redeeming"), credit(type: "futureType")] {
            XCTAssertTrue(ResetReminderPlanner.reminders(account: account(credits: [item]), credit: item, policy: policy, state: .init(), now: now).isEmpty)
        }
        var noExpiry = one; noExpiry.expiresAt = nil
        XCTAssertTrue(ResetReminderPlanner.reminders(account: account(credits: [noExpiry]), credit: noExpiry, policy: policy, state: .init(), now: now).isEmpty)
        policy.enabled = false
        XCTAssertTrue(ResetReminderPlanner.reminders(account: account(credits: [one]), credit: one, policy: policy, state: .init(), now: now).isEmpty)
    }

    func testMultipleSelectedTimesCustomOffsetAndOptionalRepeats() {
        let item = credit(hours: 48)
        let account = account(credits: [item])
        var policy = ResetReminderPolicy(); policy.enabled = true
        policy.warningMinutes = [1440, 60, 90, 60, 0, -1, 525601]
        let result = ResetReminderPlanner.reminders(account: account, credit: item, policy: policy, state: .init(), now: now)
        let selectedHours: [Double] = [24, 46.5, 47]
        XCTAssertEqual(result.map(\.fireAt), selectedHours.map { now.addingTimeInterval($0 * 3600) })

        policy.repeatHours = 12
        let repeated = ResetReminderPlanner.reminders(account: account, credit: item, policy: policy, state: .init(), now: now)
        let repeatingHours: [Double] = [24, 36, 46.5, 47]
        XCTAssertEqual(repeated.map(\.fireAt), repeatingHours.map { now.addingTimeInterval($0 * 3600) })
        XCTAssertTrue(repeated.allSatisfy { $0.fireAt < item.expiresAt! })

        policy.warningMinutes = []
        XCTAssertTrue(ResetReminderPlanner.reminders(account: account, credit: item, policy: policy, state: .init(), now: now).isEmpty)
    }

    func testSnoozeResumesAtChosenTimeWithoutEarlierAlertsAndStopSuppressesEverything() {
        let item = credit()
        var policy = ResetReminderPolicy(); policy.enabled = true
        var state = ResetReminderState(); state.snoozedUntil = now.addingTimeInterval(4 * 3600)
        let result = ResetReminderPlanner.reminders(account: account(credits: [item]), credit: item, policy: policy, state: state, now: now)
        XCTAssertEqual(result.first?.fireAt, state.snoozedUntil)
        XCTAssertTrue(result.allSatisfy { $0.fireAt >= state.snoozedUntil! })
        state.stopped = true
        XCTAssertTrue(ResetReminderPlanner.reminders(account: account(credits: [item]), credit: item, policy: policy, state: state, now: now).isEmpty)
    }

    func testQuietHoursNeverDeferReminderBeyondExpiry() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let current = calendar.date(from: DateComponents(year: 2030, month: 1, day: 1, hour: 18))!
        let expiry = calendar.date(from: DateComponents(year: 2030, month: 1, day: 2, hour: 6))!
        let item = ResetCredit(id: "quiet", grantedAt: current, expiresAt: expiry)
        var policy = ResetReminderPolicy(); policy.enabled = true
        policy.warningMinutes = [240]; policy.repeatHours = 0
        policy.quietHours = true
        let result = ResetReminderPlanner.reminders(account: account(credits: [item]), credit: item, policy: policy, state: .init(), now: current, calendar: calendar)
        XCTAssertEqual(result.first?.fireAt, calendar.date(from: DateComponents(year: 2030, month: 1, day: 1, hour: 21, minute: 59)))
    }

    func testPartialDetailsRetainOnlyTheSameAccountsLastKnownRows() {
        let previous = account(credits: [credit()], count: 3)
        var partial = account(credits: nil, count: 2)
        partial.retainUnavailableDetails(from: previous)
        XCTAssertEqual(partial.summary.availableCount, 2)
        XCTAssertEqual(partial.summary.credits, previous.summary.credits)
        XCTAssertTrue(partial.detailsAreStale)
        var zero = account(credits: nil, count: 0)
        zero.retainUnavailableDetails(from: previous)
        XCTAssertNil(zero.summary.credits)
        var different = account(credits: nil, count: 2); different.id = "different"
        different.retainUnavailableDetails(from: previous)
        XCTAssertNil(different.summary.credits)
    }

    func testCatchUpSurvivesImmediateRefreshButHonorsSnoozeStopAndChangedExpiry() {
        let item = credit()
        var policy = ResetReminderPolicy(); policy.enabled = true
        var state = ResetReminderState()
        let milestone = now.addingTimeInterval(-3600)
        let fireAt = now.addingTimeInterval(2)
        state.scheduledThrough = milestone
        func keep(_ item: ResetCredit, _ state: ResetReminderState) -> Bool {
            ResetReminderPlanner.shouldKeepCatchUp(milestone: milestone, fireAt: fireAt, expiresAt: credit().expiresAt!,
                credit: item, policy: policy, state: state, now: now)
        }
        XCTAssertTrue(keep(item, state))
        state.snoozedUntil = now.addingTimeInterval(3600)
        XCTAssertFalse(keep(item, state))
        state = .init(); state.stopped = true
        XCTAssertFalse(keep(item, state))
        XCTAssertFalse(keep(credit(hours: 12), .init()))
        XCTAssertFalse(keep(credit(status: "redeemed"), .init()))
        // Timing changes clear the submission marker and cancel the old catch-up.
        state.stopped = false; state.scheduledThrough = nil
        XCTAssertFalse(keep(item, state))
        policy.enabled = false
        XCTAssertFalse(keep(item, .init()))
    }

    func testPreferencesSnoozesAndCachedInventorySurviveRestart() throws {
        let name = "ResetCreditsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ResetReminderStore(defaults: defaults)
        var snapshot = ResetReminderStore.Snapshot()
        snapshot.policy.enabled = true; snapshot.policy.warningMinutes = [2880, 60]
        snapshot.accounts = [account(credits: [credit()])]
        var state = ResetReminderState(); state.snoozedUntil = now.addingTimeInterval(3600); state.stopped = true
        snapshot.states["synthetic-key"] = state
        store.save(snapshot)
        XCTAssertEqual(ResetReminderStore(defaults: defaults).load(), snapshot)
    }
}
