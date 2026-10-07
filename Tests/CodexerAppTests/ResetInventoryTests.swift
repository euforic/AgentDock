import CodexerCore
import XCTest
@testable import Codexer

final class ResetInventoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    private func account(_ id: String, expires: [TimeInterval?], sources: [String] = ["personal"]) -> ResetAccount {
        var account = ResetAccount(id: id, sourceIDs: sources, names: sources,
            summary: ResetCreditsSummary(availableCount: expires.count, credits: expires.enumerated().map {
                ResetCredit(id: "reset-\($0.offset)", grantedAt: now.addingTimeInterval(Double($0.offset)),
                    expiresAt: $0.element.map { now.addingTimeInterval($0) })
            }), checkedAt: now, identityVerified: true)
        account.accountEmail = "\(id)@example.com"
        account.sourceNames = Dictionary(uniqueKeysWithValues: sources.map { ($0, $0.capitalized) })
        return account
    }

    func testDateOrderInterleavesAccountsAndKeepsUndatedRowsLastInBothDirections() {
        let accounts = [account("alpha", expires: [500, nil, 200]), account("beta", expires: [100, 400])]
        let soonest = ResetInventory.sections(accounts: accounts, grouping: .date, sort: .soonest, now: now)
        let earliest = soonest.flatMap(\.rows)
        XCTAssertEqual(earliest.map { $0.credit.expiresAt?.timeIntervalSince(now) }, [100, 200, 400, 500, nil])
        XCTAssertEqual(earliest.first?.account.id, "beta")
        let latest = ResetInventory.sections(accounts: accounts, grouping: .date, sort: .latest, now: now)
        XCTAssertEqual(latest.flatMap(\.rows).map { $0.credit.expiresAt?.timeIntervalSince(now) }, [500, 400, 200, 100, nil])
        XCTAssertEqual(latest.last?.title, "No expiration reported")
    }

    func testSharedAccountIsOneInventoryButVisibleUnderEachProfileWithStableUniqueRows() {
        let shared = account("shared", expires: [100, 200], sources: ["personal", "research"])
        let accounts = [shared]
        XCTAssertEqual(ResetInventory.sections(accounts: accounts, grouping: .account, sort: .soonest, now: now).flatMap(\.rows).count, 2)
        let groups = ResetInventory.sections(accounts: accounts, profileNames: ["personal": "Renamed Personal"],
            grouping: .profile, sort: .soonest, now: now)
        XCTAssertEqual(groups.map(\.title), ["Renamed Personal", "Research"])
        XCTAssertEqual(groups.flatMap(\.rows).count, 4)
        XCTAssertEqual(Set(groups.flatMap(\.rows).map(\.id)).count, 4)
        XCTAssertEqual(Set(groups.flatMap(\.rows).map(\.key)).count, 2)
        XCTAssertEqual(groups[0].rows[0].accountToOpen.sourceIDs, ["personal"])
        XCTAssertEqual(groups[1].rows[0].accountToOpen.sourceIDs, ["research"])
        XCTAssertEqual(ResetInventory.expiringCount(accounts: accounts, within: 86400, now: now), 2)
    }

    func testUrgencyExcludesExpiredRedeemedAndUnknownDatesWithoutDroppingThemFromInventory() {
        var source = account("alpha", expires: [-10, 100, 86400 * 7, 86400 * 8, nil, 200])
        source.summary.credits?[5].status = "redeemed"
        let all = ResetInventory.sections(accounts: [source], grouping: .date, sort: .soonest, now: now)
        XCTAssertEqual(all.flatMap(\.rows).count, 6)
        let soon = ResetInventory.sections(accounts: [source], grouping: .date, sort: .soonest,
            onlyExpiringSoon: true, now: now)
        XCTAssertEqual(soon.flatMap(\.rows).map(\.credit.id), ["reset-1", "reset-2"])
        XCTAssertEqual(ResetInventory.expiringCount(accounts: [source], within: 86400, now: now), 1)
    }

    func testSearchMatchesAccountAndOnlyMatchingProfileGroup() {
        let shared = account("alpha", expires: [100], sources: ["personal", "research"])
        let accountMatch = ResetInventory.sections(accounts: [shared], grouping: .date, sort: .soonest,
            query: " ALPHA@EXAMPLE.COM ", now: now)
        XCTAssertEqual(accountMatch.flatMap(\.rows).count, 1)
        let profileMatch = ResetInventory.sections(accounts: [shared], grouping: .profile, sort: .soonest,
            query: "Research", now: now)
        XCTAssertEqual(profileMatch.map(\.title), ["Research"])
    }

    func testAccountsWithSameDisplayLabelStaySeparate() {
        var first = account("first", expires: [100])
        var second = account("second", expires: [200])
        first.accountEmail = "shared@example.com"; second.accountEmail = first.accountEmail
        let groups = ResetInventory.sections(accounts: [first, second], grouping: .account, sort: .soonest, now: now)
        XCTAssertEqual(groups.count, 2)
        XCTAssertNotEqual(groups[0].id, groups[1].id)
    }

    func testLargeInventoryKeepsEveryCreditAndDeterministicOrder() {
        let accounts = (0..<20).map { account("account-\($0)", expires: (0..<50).map { Double($0 * 60) + 1 }) }
        let groups = ResetInventory.sections(accounts: accounts, grouping: .date, sort: .soonest, now: now)
        let rows = groups.flatMap(\.rows)
        XCTAssertEqual(rows.count, 1000)
        XCTAssertEqual(Set(rows.map(\.id)).count, 1000)
        XCTAssertEqual(rows.map(\.id), ResetInventory.sections(accounts: accounts.reversed(), grouping: .date, sort: .soonest, now: now).flatMap(\.rows).map(\.id))
    }
}
