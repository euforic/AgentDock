import CodexerCore
import Foundation

enum ResetInventoryGrouping: String, CaseIterable, Identifiable {
    case date = "Date", account = "Account", profile = "Profile"
    var id: Self { self }
}

enum ResetInventorySort: String, CaseIterable, Identifiable {
    case soonest = "Soonest first", latest = "Latest first", granted = "Recently granted"
    var id: Self { self }
}

struct ResetInventoryRow: Identifiable {
    let account: ResetAccount
    let credit: ResetCredit
    var sourceID: String?
    var profileName: String
    let key: String
    var id: String { key + (sourceID.map { ":\($0)" } ?? "") }
    var accountToOpen: ResetAccount {
        guard let sourceID else { return account }
        var selected = account
        selected.sourceIDs = [sourceID]
        selected.names = [profileName]
        return selected
    }

    init(account: ResetAccount, credit: ResetCredit, sourceID: String?, profileName: String) {
        self.account = account
        self.credit = credit
        self.sourceID = sourceID
        self.profileName = profileName
        key = account.key(for: credit)
    }

    func expiresSoon(at now: Date) -> Bool {
        credit.isAvailable(at: now) && credit.expiresAt.map {
            $0 <= now.addingTimeInterval(7 * 86400)
        } == true
    }
}

struct ResetInventorySection: Identifiable {
    let id: String
    let title: String
    let rows: [ResetInventoryRow]
}

/// A display projection of provider inventory. Grouping never changes authoritative quota.
enum ResetInventory {
    static func sections(accounts: [ResetAccount], profileNames: [String: String] = [:],
                         grouping: ResetInventoryGrouping, sort: ResetInventorySort,
                         query: String = "", onlyExpiringSoon: Bool = false,
                         now: Date, calendar: Calendar = .current) -> [ResetInventorySection] {
        var rows: [ResetInventoryRow] = []
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        for account in accounts {
            let aliases = account.sourceNames ?? [:]
            for credit in account.summary.credits ?? [] {
                let sources: [String?] = grouping == .profile
                    ? account.sourceIDs.sorted().map { Optional($0) } : [nil]
                for source in sources {
                    let currentNames = account.sourceIDs.compactMap { profileNames[$0] ?? aliases[$0] }.sorted()
                    let name = source.map { profileNames[$0] ?? aliases[$0]
                        ?? (account.sourceIDs.count == 1 ? account.displayName : "Profile \($0.prefix(8))") }
                        ?? (currentNames.isEmpty ? account.displayName : currentNames.joined(separator: ", "))
                    let row = ResetInventoryRow(account: account, credit: credit,
                        sourceID: source, profileName: name)
                    guard !onlyExpiringSoon || row.expiresSoon(at: now) else { continue }
                    let searchable = [account.accountName, name, credit.title ?? "", credit.status,
                        credit.description ?? ""].joined(separator: " ")
                    guard query.isEmpty || searchable.localizedCaseInsensitiveContains(query) else { continue }
                    rows.append(row)
                }
            }
        }
        rows.sort { lhs, rhs in
            if sort == .granted, lhs.credit.grantedAt != rhs.credit.grantedAt {
                return lhs.credit.grantedAt > rhs.credit.grantedAt
            }
            if lhs.credit.expiresAt != rhs.credit.expiresAt {
                guard let first = lhs.credit.expiresAt else { return false }
                guard let second = rhs.credit.expiresAt else { return true }
                return sort == .latest ? first > second : first < second
            }
            return lhs.id < rhs.id
        }
        var order: [String] = []
        var grouped: [String: [ResetInventoryRow]] = [:]
        var titles: [String: String] = [:]
        for row in rows {
            let id: String
            let title: String
            switch grouping {
            case .date:
                if let expiry = row.credit.expiresAt {
                    let day = calendar.startOfDay(for: expiry)
                    id = "date:\(day.timeIntervalSince1970)"
                    let prefix = calendar.isDate(expiry, inSameDayAs: now) ? "Today · "
                        : calendar.isDate(expiry, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now) ?? now)
                            ? "Tomorrow · " : ""
                    title = prefix + expiry.formatted(.dateTime.year().month(.abbreviated).day())
                } else {
                    id = "undated"; title = "No expiration reported"
                }
            case .account:
                id = row.account.id; title = row.account.accountName
            case .profile:
                id = row.sourceID ?? row.account.id; title = row.profileName
            }
            if grouped[id] == nil { order.append(id); titles[id] = title }
            grouped[id, default: []].append(row)
        }
        if grouping != .date {
            order.sort {
                let comparison = (titles[$0] ?? "").localizedStandardCompare(titles[$1] ?? "")
                return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
            }
        }
        return order.map { ResetInventorySection(id: $0, title: titles[$0] ?? "", rows: grouped[$0] ?? []) }
    }

    static func expiringCount(accounts: [ResetAccount], within interval: TimeInterval, now: Date) -> Int {
        accounts.reduce(0) { count, account in
            count + (account.summary.credits ?? []).filter {
                $0.isAvailable(at: now) && $0.expiresAt.map { $0 <= now.addingTimeInterval(interval) } == true
            }.count
        }
    }
}
