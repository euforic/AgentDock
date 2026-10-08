import Foundation

public struct ProfileRateLimits: Equatable, Sendable {
    public var accountID: String?
    public var accountEmail: String?
    public var resetCredits: ResetCreditsSummary?
    public var planType: String?
    public var buckets: [RateLimitBucket]
    public var credits: CreditsUsage?
    public var fetchedAt: Date
    public var errorMessage: String?
    public var warningMessage: String?

    public init(
        accountID: String? = nil,
        accountEmail: String? = nil,
        resetCredits: ResetCreditsSummary? = nil,
        planType: String? = nil,
        buckets: [RateLimitBucket] = [],
        credits: CreditsUsage? = nil,
        fetchedAt: Date = Date(),
        errorMessage: String? = nil,
        warningMessage: String? = nil
    ) {
        self.accountID = accountID
        self.accountEmail = accountEmail
        self.resetCredits = resetCredits
        self.planType = planType
        self.buckets = buckets
        self.credits = credits
        self.fetchedAt = fetchedAt
        self.errorMessage = errorMessage
        self.warningMessage = warningMessage
    }
}

public struct RateLimitBucket: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var primary: RateLimitWindowUsage?
    public var secondary: RateLimitWindowUsage?
    public var reachedType: String?

    public init(
        id: String,
        name: String,
        primary: RateLimitWindowUsage?,
        secondary: RateLimitWindowUsage?,
        reachedType: String? = nil
    ) {
        self.id = id
        self.name = name
        self.primary = primary
        self.secondary = secondary
        self.reachedType = reachedType
    }
}

public struct RateLimitWindowUsage: Equatable, Sendable {
    public var usedPercent: Double
    public var windowDurationMins: Int?
    public var resetsAt: Date?

    public init(usedPercent: Double, windowDurationMins: Int?, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }
}

public struct CreditsUsage: Equatable, Sendable {
    public var hasCredits: Bool
    public var unlimited: Bool
    public var balance: String
}

public enum RateLimitParser {
    public static func parseResponse(_ data: Data, fetchedAt: Date = Date()) throws -> ProfileRateLimits {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let envelope = try decoder.decode(AppServerRateLimitEnvelope.self, from: data)
        guard let result = envelope.result else {
            throw RateLimitParserError.missingResult
        }

        let mappedSnapshots = result.rateLimitsByLimitId?.values.sorted { lhs, rhs in
            (lhs.limitId ?? lhs.limitName ?? "") < (rhs.limitId ?? rhs.limitName ?? "")
        } ?? []
        let snapshots = mappedSnapshots.isEmpty
            ? result.rateLimits.map { [$0] } ?? []
            : mappedSnapshots
        guard let primarySnapshot = result.rateLimits ?? snapshots.first else {
            throw RateLimitParserError.missingResult
        }

        let buckets = snapshots.compactMap { snapshot -> RateLimitBucket? in
            guard !snapshot.isSparkUsageLimit else { return nil }
            let id = snapshot.limitId ?? snapshot.limitName ?? "default"
            let name = snapshot.limitName ?? displayName(for: id)
            return RateLimitBucket(
                id: id,
                name: name,
                primary: snapshot.primary?.usage,
                secondary: snapshot.secondary?.usage,
                reachedType: snapshot.rateLimitReachedType
            )
        }

        return ProfileRateLimits(
            accountID: result.accountId,
            resetCredits: result.rateLimitResetCredits,
            planType: primarySnapshot.planType,
            buckets: buckets,
            credits: primarySnapshot.credits?.usage,
            fetchedAt: fetchedAt
        )
    }

    private static func displayName(for id: String) -> String {
        switch id {
        case "codex":
            "Codex"
        default:
            id
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        }
    }
}

public enum RateLimitParserError: Error, LocalizedError, Equatable {
    case missingResult

    public var errorDescription: String? {
        switch self {
        case .missingResult:
            "The Codex app-server response did not include rate-limit data."
        }
    }
}

private struct AppServerRateLimitEnvelope: Decodable {
    var id: Int?
    var result: AppServerRateLimitResult?
}

private struct AppServerRateLimitResult: Decodable {
    var accountId: String?
    var rateLimitResetCredits: ResetCreditsSummary?
    var rateLimits: AppServerRateLimitSnapshot?
    var rateLimitsByLimitId: [String: AppServerRateLimitSnapshot]?
}

private struct AppServerRateLimitSnapshot: Decodable {
    var limitId: String?
    var limitName: String?
    var primary: AppServerRateLimitWindow?
    var secondary: AppServerRateLimitWindow?
    var credits: AppServerCredits?
    var planType: String?
    var rateLimitReachedType: String?

    var isSparkUsageLimit: Bool {
        limitName?.localizedCaseInsensitiveContains("spark") == true
    }
}

private struct AppServerRateLimitWindow: Decodable {
    var usedPercent: Double
    var windowDurationMins: Int?
    var resetsAt: TimeInterval?

    var usage: RateLimitWindowUsage {
        RateLimitWindowUsage(
            usedPercent: usedPercent,
            windowDurationMins: windowDurationMins,
            resetsAt: resetsAt.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

private struct AppServerCredits: Decodable {
    var hasCredits: Bool
    var unlimited: Bool
    var balance: String?

    var usage: CreditsUsage {
        CreditsUsage(
            hasCredits: hasCredits,
            unlimited: unlimited,
            balance: balance ?? "0"
        )
    }
}
