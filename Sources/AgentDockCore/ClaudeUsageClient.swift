import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security

public protocol ClaudeUsageFetching: Sendable {
    func fetchOfficialUsage(
        claudeUserDataURL: URL,
        allowKeychainInteraction: Bool,
        forceRefresh: Bool
    ) async -> ProfileRateLimits

    func fetchManagedUsage(
        claudeUserDataURL: URL,
        allowKeychainInteraction: Bool,
        forceRefresh: Bool
    ) async -> ProfileRateLimits

    /// Live limits for every Claude account signed in to AgentDock. One
    /// account's failure is reported on its own entry and never hides another.
    func fetchClaudeCodeUsage(
        allowKeychainInteraction: Bool,
        forceRefresh: Bool
    ) async -> ClaudeCodeUsageReport

    /// Live limits for one account; nil when it is no longer signed in here.
    func fetchClaudeCodeUsage(
        accountKey: String,
        allowKeychainInteraction: Bool,
        forceRefresh: Bool
    ) async -> ClaudeCodeAccountUsage?

    /// Drops every cached Claude Code result.
    func forgetClaudeCodeUsage() async

    /// Drops one account's cached Claude Code results after a sign-in or sign-out.
    func forgetClaudeCodeUsage(accountKey: String) async
}

enum ClaudeUsageRefreshPolicy {
    static let freshnessInterval: TimeInterval = 5 * 60
    static let failureRetryBackoff: TimeInterval = 60
    static let defaultRateLimitCooldown: TimeInterval = 5 * 60
    /// Repeated manual refreshes within this interval reuse the last success.
    static let manualRefreshFloor: TimeInterval = 30
    static let maximumRateLimitCooldown: TimeInterval = 60 * 60
    /// At most this many Claude Code accounts fetch at once.
    static let maximumConcurrentClaudeCodeRequests = 2
    /// Claude Code fetch starts are spaced this far apart across accounts.
    static let claudeCodeRequestSpacing: Duration = .seconds(1)

    static func canReuse(_ limits: ProfileRateLimits, now: Date) -> Bool {
        let age = now.timeIntervalSince(limits.fetchedAt)
        return age >= 0 && age < freshnessInterval
    }

    static func rateLimitCooldown(retryAfter: TimeInterval?) -> TimeInterval {
        min(
            max(failureRetryBackoff, retryAfter ?? defaultRateLimitCooldown),
            maximumRateLimitCooldown
        )
    }

    /// Parses `Retry-After` as delta seconds or an HTTP-date.
    static func retryAfter(_ header: String?, now: Date) -> TimeInterval? {
        guard let value = header?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        if let seconds = TimeInterval(value) {
            return seconds.isFinite && seconds >= 0 ? seconds : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    /// A manual refresh skips freshness (down to a short floor) and non-429
    /// backoff, but never an active provider rate-limit cooldown.
    static func gate(
        now: Date,
        lastSuccessAt: Date?,
        failureRetryAt: Date?,
        rateLimitedUntil: Date?,
        forceRefresh: Bool
    ) -> ClaudeUsageGate {
        if let rateLimitedUntil, rateLimitedUntil > now {
            return .rateLimited(until: rateLimitedUntil)
        }
        if let lastSuccessAt {
            let age = now.timeIntervalSince(lastSuccessAt)
            if age >= 0, age < (forceRefresh ? manualRefreshFloor : freshnessInterval) {
                return .reuseCached
            }
        }
        if !forceRefresh, let failureRetryAt, failureRetryAt > now {
            return .backingOff
        }
        return .fetch
    }
}

enum ClaudeUsageProjection: String, Sendable {
    case desktop
    case claudeCode
}

public actor ClaudeUsageClient: ClaudeUsageFetching {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let profileURL = ClaudeOAuth.profileURL
    private static let maximumResponseBytes = 1 * 1_024 * 1_024
    private static let claudeCodeKeyPrefix = "\(ClaudeUsageProjection.claudeCode.rawValue)|"
    private static let rateLimitedWarning = "Live usage is rate limited; showing the last successful update."
    private static let rateLimitedError = "Live usage is rate limited. Try again later."
    static let budgetWarning = "This account reached AgentDock's hourly refresh limit; showing the last successful update."
    static let budgetError = "This account reached AgentDock's hourly refresh limit. Try again later."
    private struct CachedUsage {
        var limits: ProfileRateLimits
        var retryAfter: Date?
    }

    private enum UsageRead {
        case response(Data, HTTPURLResponse)
        case unauthorized
    }

    private let transport: any ClaudeHTTPTransport
    private let claudeCodeAccounts: ClaudeCodeAccounts?
    private var credentialReader: ClaudeCredentialReader
    private let cooldowns: ClaudeUsageCooldownStore
    private var verifiedIdentities = ClaudeIdentityVerificationLedger()
    private var cache: [String: CachedUsage] = [:]
    private var refreshWaiters: [String: [CheckedContinuation<ProfileRateLimits, Never>]] = [:]
    /// Per-account hourly budget for Claude Code fetches.
    private var claudeCodeBudget = ClaudeUsageRequestBudget()
    /// At most two Claude Code fetches at once, with staggered starts.
    private let claudeCodeThrottle: ClaudeRequestThrottle
    /// One Claude Code fetch per account at a time.
    private let claudeCodeAccountLocks = ClaudeKeyedExclusion<ObjectIdentifier>()

    /// `claudeCodeAccounts` nil means Claude Code limits list no accounts.
    public init(claudeCodeAccounts: ClaudeCodeAccounts? = nil) {
        self.init(
            cooldowns: ClaudeUsageCooldownStore(),
            keychain: nil,
            claudeCodeAccounts: claudeCodeAccounts
        )
    }

    init(
        cooldowns: ClaudeUsageCooldownStore,
        keychain: SecKeychain? = nil,
        transport: any ClaudeHTTPTransport = URLSessionClaudeHTTPTransport(),
        claudeCodeAccounts: ClaudeCodeAccounts? = nil,
        maximumConcurrentClaudeCodeRequests: Int = ClaudeUsageRefreshPolicy.maximumConcurrentClaudeCodeRequests,
        claudeCodeRequestSpacing: Duration = ClaudeUsageRefreshPolicy.claudeCodeRequestSpacing
    ) {
        self.transport = transport
        self.claudeCodeAccounts = claudeCodeAccounts
        credentialReader = ClaudeCredentialReader(keychain: keychain)
        self.cooldowns = cooldowns
        claudeCodeThrottle = ClaudeRequestThrottle(
            maximumConcurrent: maximumConcurrentClaudeCodeRequests,
            spacing: claudeCodeRequestSpacing
        )
    }

    public func fetchOfficialUsage(
        claudeUserDataURL: URL,
        allowKeychainInteraction: Bool,
        forceRefresh: Bool = false
    ) async -> ProfileRateLimits {
        // The official row represents Desktop, whose account can differ from Claude Code.
        let credential = credentialReader.readDesktopCredential(
            userDataURL: claudeUserDataURL,
            allowKeychainInteraction: allowKeychainInteraction
        )
        return await fetch(credential, projection: .desktop, forceRefresh: forceRefresh)
    }

    public func fetchManagedUsage(
        claudeUserDataURL: URL,
        allowKeychainInteraction: Bool,
        forceRefresh: Bool = false
    ) async -> ProfileRateLimits {
        let credential = credentialReader.readDesktopCredential(
            userDataURL: claudeUserDataURL,
            allowKeychainInteraction: allowKeychainInteraction
        )
        return await fetch(credential, projection: .desktop, forceRefresh: forceRefresh)
    }

    /// Live limits for every Claude account signed in to AgentDock, each of
    /// which can differ from Desktop. Claude Code's own login is never read.
    /// Accounts are fetched independently: each has its own gate, cooldown,
    /// and budget, and one account's failure never blocks another.
    public func fetchClaudeCodeUsage(
        allowKeychainInteraction: Bool,
        forceRefresh: Bool = false
    ) async -> ClaudeCodeUsageReport {
        guard let claudeCodeAccounts else { return ClaudeCodeUsageReport() }
        let listing = await claudeCodeAccounts.entries(allowKeychainInteraction: allowKeychainInteraction)
        let entries = listing.entries
        let accounts = await withTaskGroup(
            of: (Int, ClaudeCodeAccountUsage).self,
            returning: [ClaudeCodeAccountUsage].self
        ) { group in
            for (index, entry) in entries.enumerated() {
                group.addTask {
                    let usage = await self.claudeCodeAccountUsage(
                        key: entry.key,
                        login: entry.login,
                        allowKeychainInteraction: allowKeychainInteraction,
                        forceRefresh: forceRefresh
                    )
                    return (index, usage)
                }
            }
            var collected = [ClaudeCodeAccountUsage?](repeating: nil, count: entries.count)
            for await (index, usage) in group {
                collected[index] = usage
            }
            return collected.compactMap { $0 }
        }
        return ClaudeCodeUsageReport(
            keychainAccessRequired: listing.keychainAccessRequired,
            accounts: accounts
        )
    }

    public func fetchClaudeCodeUsage(
        accountKey: String,
        allowKeychainInteraction: Bool,
        forceRefresh: Bool = false
    ) async -> ClaudeCodeAccountUsage? {
        guard let login = await claudeCodeAccounts?.login(forAccountKey: accountKey) else { return nil }
        return await claudeCodeAccountUsage(
            key: accountKey,
            login: login,
            allowKeychainInteraction: allowKeychainInteraction,
            forceRefresh: forceRefresh
        )
    }

    /// Live limits for one signed-in account. Only one fetch per account runs
    /// at a time; a second caller waits and then normally reuses the result.
    func fetchClaudeCodeUsage(
        login: ClaudeCodeLogin,
        allowKeychainInteraction: Bool,
        forceRefresh: Bool = false
    ) async -> ProfileRateLimits {
        let lock = ObjectIdentifier(login)
        await claudeCodeAccountLocks.acquire(lock)
        defer { claudeCodeAccountLocks.release(lock) }

        switch await login.usableTokens(allowKeychainInteraction: allowKeychainInteraction) {
        case let .tokens(tokens):
            return await fetch(
                tokens.usageCredential,
                projection: .claudeCode,
                forceRefresh: forceRefresh,
                login: login
            )
        case let .signedOut(expired):
            if !expired, await login.isUnreadable() {
                return ProfileRateLimits(errorMessage: ClaudeCodeUsageMessage.unreadableSignIn)
            }
            return ProfileRateLimits(
                errorMessage: expired
                    ? ClaudeCodeUsageMessage.signInExpired
                    : ClaudeCodeUsageMessage.notSignedIn
            )
        case .keychainAccessRequired:
            return ProfileRateLimits(errorMessage: ClaudeCodeUsageMessage.keychainAccessRequired)
        case .renewalUnavailable:
            // No usage request is sent with a token that could not be renewed.
            let identity = await login.knownIdentity()
            let latest = latestClaudeCodeLimits(accountKey: identity?.accountKey)
            return latest.flatMap {
                cachedLimits(for: $0, warning: ClaudeCodeUsageMessage.renewalUnavailable)
            } ?? ProfileRateLimits(
                planType: latest.flatMap { cache[$0]?.limits.planType },
                errorMessage: ClaudeCodeUsageMessage.renewalUnavailable
            )
        }
    }

    public func forgetClaudeCodeUsage() async {
        cache = cache.filter { !$0.key.hasPrefix(Self.claudeCodeKeyPrefix) }
    }

    public func forgetClaudeCodeUsage(accountKey: String) async {
        let prefix = "\(Self.claudeCodeKeyPrefix)\(accountKey)|"
        cache = cache.filter { !$0.key.hasPrefix(prefix) }
    }

    private func claudeCodeAccountUsage(
        key: String,
        login: ClaudeCodeLogin,
        allowKeychainInteraction: Bool,
        forceRefresh: Bool
    ) async -> ClaudeCodeAccountUsage {
        let limits = await fetchClaudeCodeUsage(
            login: login,
            allowKeychainInteraction: allowKeychainInteraction,
            forceRefresh: forceRefresh
        )
        let summary = await login.summary()
        let identity = await login.knownIdentity()
        return ClaudeCodeAccountUsage(
            key: key,
            account: summary.account,
            status: summary.status,
            limits: limits,
            rateLimitedUntil: identity.flatMap { claudeCodeRetryAt($0, now: Date()) }
        )
    }

    /// The later of an active 429 cooldown and the end of a spent hourly budget.
    private func claudeCodeRetryAt(_ identity: ClaudeAccountIdentity, now: Date) -> Date? {
        let digest = ClaudeUsageCredential.cooldownKey(identity: identity, projection: .claudeCode)
        return [
            cooldowns.blockedUntil(key: digest, now: now),
            claudeCodeBudget.nextAvailable(key: digest, now: now)
        ].compactMap { $0 }.max()
    }

    /// The cache key of an account's newest Claude Code result, if any; any
    /// account's when the key is unknown.
    private func latestClaudeCodeLimits(accountKey: String?) -> String? {
        let prefix = accountKey.map { "\(Self.claudeCodeKeyPrefix)\($0)|" } ?? Self.claudeCodeKeyPrefix
        return cache
            .filter { $0.key.hasPrefix(prefix) }
            .max { $0.value.limits.fetchedAt < $1.value.limits.fetchedAt }?
            .key
    }

    /// Claude Code entries start with the account key, so one account's
    /// results can be dropped without touching another's.
    private static func cacheKey(
        _ credential: ClaudeUsageCredential,
        projection: ClaudeUsageProjection
    ) -> String {
        guard projection == .claudeCode, let identity = credential.identity else {
            return "\(projection.rawValue)|\(credential.cacheKey)"
        }
        return "\(claudeCodeKeyPrefix)\(identity.accountKey)|\(credential.cacheKey)"
    }

    private func fetch(
        _ credential: ClaudeUsageCredential?,
        projection: ClaudeUsageProjection,
        forceRefresh: Bool,
        login: ClaudeCodeLogin? = nil
    ) async -> ProfileRateLimits {
        guard let credential else {
            return ProfileRateLimits(
                errorMessage: "Live usage is unavailable. Open Claude and sign in, then refresh. If macOS asks for Keychain access, choose Always Allow to retain access."
            )
        }
        guard credential.scopes.isEmpty || credential.scopes.contains("user:profile") else {
            return ProfileRateLimits(
                planType: credential.subscriptionType,
                errorMessage: "This login cannot read live usage. Sign in again to grant profile access."
            )
        }

        let key = Self.cacheKey(credential, projection: projection)
        let cooldownKey = credential.cooldownKey(for: projection)
        let now = Date()
        let cached = cache[key]
        // Matches the previous reuse rule: only a success with no cooldown is fresh.
        var lastSuccessAt: Date?
        if let cached, cached.retryAfter == nil {
            lastSuccessAt = cached.limits.fetchedAt
        }
        switch ClaudeUsageRefreshPolicy.gate(
            now: now,
            lastSuccessAt: lastSuccessAt,
            failureRetryAt: cached?.retryAfter,
            rateLimitedUntil: cooldowns.blockedUntil(key: cooldownKey, now: now),
            forceRefresh: forceRefresh
        ) {
        case .rateLimited, .backingOff:
            return rateLimitedLimits(for: key, credential: credential)
        case .reuseCached:
            if let cached { return cached.limits }
        case .fetch:
            break
        }

        if refreshWaiters[key] != nil {
            return await withCheckedContinuation { continuation in
                refreshWaiters[key, default: []].append(continuation)
            }
        }

        // Claude Code accounts also have an hourly budget each.
        if projection == .claudeCode, !claudeCodeBudget.reserve(key: cooldownKey, now: now) {
            return budgetLimitedLimits(for: key, credential: credential)
        }

        refreshWaiters[key] = []
        // At most two Claude Code accounts fetch at once, with staggered starts.
        if projection == .claudeCode { await claudeCodeThrottle.acquire() }
        let limits = await fetchUncached(credential, key: key, projection: projection, login: login)
        if projection == .claudeCode { claudeCodeThrottle.release() }
        let waiters = refreshWaiters.removeValue(forKey: key) ?? []
        waiters.forEach { $0.resume(returning: limits) }
        return limits
    }

    private func fetchUncached(
        _ credential: ClaudeUsageCredential,
        key: String,
        projection: ClaudeUsageProjection,
        login: ClaudeCodeLogin?
    ) async -> ProfileRateLimits {
        var credential = credential
        var key = key
        do {
            var read = try await readUsage(credential)
            if case .unauthorized = read {
                // Desktop tokens belong to Claude Desktop and are never renewed here.
                guard projection == .claudeCode, let login else {
                    return recordRequestFailure(401, key: key, credential: credential)
                }
                verifiedIdentities.invalidate(credential.cacheKey)
                switch await login.renewAfterUnauthorized(
                    rejectedAccessToken: credential.accessToken
                ) {
                case let .tokens(renewed):
                    // Renew once, retry once. Waiters on the old key still get
                    // this result; the old key's cache entry is dropped.
                    cache.removeValue(forKey: key)
                    credential = renewed.usageCredential
                    key = Self.cacheKey(credential, projection: projection)
                    read = try await readUsage(credential)
                    if case .unauthorized = read {
                        verifiedIdentities.invalidate(credential.cacheKey)
                        await login.markSignedOutAfterRepeatedUnauthorized()
                        cache.removeValue(forKey: key)
                        return ProfileRateLimits(errorMessage: ClaudeCodeUsageMessage.signInExpired)
                    }
                case .signedOut:
                    cache.removeValue(forKey: key)
                    return ProfileRateLimits(errorMessage: ClaudeCodeUsageMessage.signInExpired)
                case .renewalUnavailable, .keychainAccessRequired:
                    let failure = ProfileRateLimits(
                        planType: credential.subscriptionType,
                        errorMessage: ClaudeCodeUsageMessage.renewalUnavailable
                    )
                    recordFailureCooldown(
                        for: key,
                        fallback: failure,
                        retryAt: Date().addingTimeInterval(ClaudeUsageRefreshPolicy.failureRetryBackoff)
                    )
                    return cachedLimits(
                        for: key,
                        warning: ClaudeCodeUsageMessage.renewalUnavailable
                    ) ?? failure
                }
            }
            guard case let .response(data, response) = read else {
                return recordRequestFailure(401, key: key, credential: credential)
            }
            let cooldownKey = credential.cooldownKey(for: projection)
            if response.statusCode == 429 {
                return recordRateLimit(
                    key: key,
                    cooldownKey: cooldownKey,
                    retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
                    credential: credential
                )
            }
            guard (200..<300).contains(response.statusCode) else {
                return recordRequestFailure(
                    response.statusCode,
                    key: key,
                    credential: credential
                )
            }
            var limits: ProfileRateLimits
            if projection == .claudeCode {
                limits = try ClaudeUsageResponseParser.parseClaudeCode(
                    data,
                    planType: credential.subscriptionType
                )
            } else {
                limits = try ClaudeUsageResponseParser.parse(
                    data,
                    planType: credential.subscriptionType
                )
            }
            limits.fetchedAt = Date()
            cache[key] = CachedUsage(limits: limits, retryAfter: nil)
            cooldowns.clear(key: cooldownKey)
            return limits
        } catch ClaudeUsageClientError.identityMismatch {
            cache.removeValue(forKey: key)
            verifiedIdentities.invalidate(credential.cacheKey)
            return ProfileRateLimits(
                errorMessage: projection == .claudeCode
                    ? ClaudeCodeUsageMessage.identityMismatch
                    : "The Claude login no longer matches this account. Open Claude and sign in, then refresh."
            )
        } catch ClaudeUsageClientError.rateLimited(let retryAfter) {
            return recordRateLimit(
                key: key,
                cooldownKey: credential.cooldownKey(for: projection),
                retryAfter: retryAfter,
                credential: credential
            )
        } catch ClaudeUsageClientError.requestFailed(let statusCode) {
            return recordRequestFailure(
                statusCode,
                key: key,
                credential: credential
            )
        } catch {
            recordFailureCooldown(
                for: key,
                fallback: ProfileRateLimits(planType: credential.subscriptionType),
                retryAt: Date().addingTimeInterval(ClaudeUsageRefreshPolicy.failureRetryBackoff)
            )
            return cachedLimits(
                for: key,
                warning: "Live usage could not be refreshed; showing the last successful update."
            ) ?? ProfileRateLimits(
                planType: credential.subscriptionType,
                errorMessage: "Live usage could not be loaded. Check the connection and refresh."
            )
        }
    }

    /// Handles a 429 from either the usage or profile endpoint. The cooldown is
    /// persisted under a digest of the account identity (or of the token when
    /// there is none), so it survives relaunch, token renewal, and manual refresh.
    private func recordRateLimit(
        key: String,
        cooldownKey: String,
        retryAfter header: String?,
        credential: ClaudeUsageCredential
    ) -> ProfileRateLimits {
        let now = Date()
        let retryAt = now.addingTimeInterval(
            ClaudeUsageRefreshPolicy.rateLimitCooldown(
                retryAfter: ClaudeUsageRefreshPolicy.retryAfter(header, now: now)
            )
        )
        cooldowns.record(key: cooldownKey, until: retryAt, now: now)
        recordFailureCooldown(
            for: key,
            fallback: ProfileRateLimits(planType: credential.subscriptionType),
            retryAt: retryAt
        )
        return rateLimitedLimits(for: key, credential: credential)
    }

    private func recordRequestFailure(
        _ statusCode: Int,
        key: String,
        credential: ClaudeUsageCredential
    ) -> ProfileRateLimits {
        let unauthorized = statusCode == 401 || statusCode == 403
        if unauthorized {
            verifiedIdentities.invalidate(credential.cacheKey)
        }
        let failure = requestFailure(statusCode, credential: credential)
        let retryDelay = unauthorized
            ? ClaudeUsageRefreshPolicy.defaultRateLimitCooldown
            : ClaudeUsageRefreshPolicy.failureRetryBackoff
        recordFailureCooldown(
            for: key,
            fallback: failure,
            retryAt: Date().addingTimeInterval(retryDelay)
        )
        return cachedLimits(
            for: key,
            warning: failure.errorMessage ?? "Live usage could not be refreshed."
        ) ?? failure
    }

    private func rateLimitedLimits(
        for key: String,
        credential: ClaudeUsageCredential
    ) -> ProfileRateLimits {
        cachedLimits(for: key, warning: Self.rateLimitedWarning) ?? ProfileRateLimits(
            planType: credential.subscriptionType,
            errorMessage: Self.rateLimitedError
        )
    }

    private func budgetLimitedLimits(
        for key: String,
        credential: ClaudeUsageCredential
    ) -> ProfileRateLimits {
        cachedLimits(for: key, warning: Self.budgetWarning) ?? ProfileRateLimits(
            planType: credential.subscriptionType,
            errorMessage: Self.budgetError
        )
    }

    private func recordFailureCooldown(
        for key: String,
        fallback: ProfileRateLimits,
        retryAt: Date
    ) {
        if var existing = cache[key] {
            existing.retryAfter = retryAt
            cache[key] = existing
        } else {
            cache[key] = CachedUsage(limits: fallback, retryAfter: retryAt)
        }
    }

    /// Checks the identity once per credential key, then reads usage. A 401
    /// from either endpoint is reported as `.unauthorized`.
    private func readUsage(_ credential: ClaudeUsageCredential) async throws -> UsageRead {
        // Identity is verified once per (identity, token) pair, not per request.
        if let identity = credential.identity,
           !verifiedIdentities.isVerified(credential.cacheKey)
        {
            do {
                try await verifyIdentity(identity, accessToken: credential.accessToken)
            } catch ClaudeUsageClientError.unauthorized {
                return .unauthorized
            }
            verifiedIdentities.markVerified(credential.cacheKey)
        }
        let (data, response) = try await request(Self.usageURL, token: credential.accessToken)
        if response.statusCode == 401 { return .unauthorized }
        return .response(data, response)
    }

    private func verifyIdentity(_ expected: ClaudeAccountIdentity, accessToken: String) async throws {
        let (data, response) = try await request(Self.profileURL, token: accessToken)
        if response.statusCode == 401 {
            throw ClaudeUsageClientError.unauthorized
        }
        if response.statusCode == 429 {
            throw ClaudeUsageClientError.rateLimited(
                retryAfter: response.value(forHTTPHeaderField: "Retry-After")
            )
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ClaudeUsageClientError.requestFailed(response.statusCode)
        }
        let profile = try JSONDecoder().decode(ClaudeAccountProfile.self, from: data)
        guard profile.account.uuid.caseInsensitiveCompare(expected.accountUUID) == .orderedSame,
              profile.organization?.uuid.caseInsensitiveCompare(expected.organizationUUID) == .orderedSame
        else {
            throw ClaudeUsageClientError.identityMismatch
        }
    }

    private func request(_ url: URL, token: String) async throws -> (Data, HTTPURLResponse) {
        try await transport.send(
            ClaudeAPIRequest.get(url, bearer: token),
            maximumResponseBytes: Self.maximumResponseBytes
        )
    }

    private func requestFailure(
        _ statusCode: Int,
        credential: ClaudeUsageCredential
    ) -> ProfileRateLimits {
        let message = switch statusCode {
        case 401: "The Claude session expired. Sign in again, then refresh."
        case 403: "This Claude login is not permitted to read live usage."
        default: "Live usage request failed (HTTP \(statusCode))."
        }
        return ProfileRateLimits(planType: credential.subscriptionType, errorMessage: message)
    }

    private func cachedLimits(for key: String, warning: String) -> ProfileRateLimits? {
        guard var limits = cache[key]?.limits, !limits.buckets.isEmpty else { return nil }
        limits.warningMessage = warning
        return limits
    }
}

struct ClaudeAccountIdentity: Equatable, Sendable {
    var accountUUID: String
    var organizationUUID: String

    static func desktop(accountUUID: String?, organizationUUID: String) -> Self? {
        guard let accountUUID,
              let account = UUID(uuidString: accountUUID),
              let organization = UUID(uuidString: organizationUUID)
        else { return nil }
        return Self(
            accountUUID: account.uuidString.lowercased(),
            organizationUUID: organization.uuidString.lowercased()
        )
    }

    /// The key of AgentDock's own sign-in for this account and organization.
    var accountKey: String {
        ClaudeLoginAccountKey.make(accountUUID: accountUUID, organizationUUID: organizationUUID)
    }
}

struct ClaudeUsageCredential: Equatable, Sendable {
    var accessToken: String
    var expiresAt: Double?
    var subscriptionType: String?
    var scopes: Set<String>
    var identity: ClaudeAccountIdentity?

    /// The SHA-256 hex digest of the access token; safe to persist and compare.
    var tokenDigest: String {
        Self.digest(accessToken)
    }

    static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The persisted 429 cooldown key: a digest of the projection and account
    /// identity, so it survives token renewal; the token digest without identity.
    func cooldownKey(for projection: ClaudeUsageProjection) -> String {
        guard let identity else { return tokenDigest }
        return Self.cooldownKey(identity: identity, projection: projection)
    }

    /// Depends only on the account identity, so the cooldown saved before
    /// multiple accounts were supported still applies to the migrated account.
    static func cooldownKey(identity: ClaudeAccountIdentity, projection: ClaudeUsageProjection) -> String {
        digest(
            "claude-usage-cooldown|\(projection.rawValue)|\(identity.accountUUID)/\(identity.organizationUUID)"
        )
    }

    var cacheKey: String {
        if let identity {
            return "\(identity.accountUUID.lowercased())|\(identity.organizationUUID.lowercased())|\(tokenDigest)"
        }
        return tokenDigest
    }
}

enum ClaudeUsageResponseParser {
    static func parse(
        _ data: Data,
        planType: String? = nil,
        fetchedAt: Date = Date()
    ) throws -> ProfileRateLimits {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeUsageClientError.invalidResponse
        }

        var buckets: [RateLimitBucket] = []
        let session = window(root["five_hour"], minutes: 300)
        let weekly = window(root["seven_day"], minutes: 10_080)
        if session != nil || weekly != nil {
            buckets.append(RateLimitBucket(
                id: "claude",
                name: "Claude",
                primary: session,
                secondary: weekly
            ))
        }
        if let sonnet = window(root["seven_day_sonnet"], minutes: 10_080) {
            buckets.append(RateLimitBucket(
                id: "sonnet",
                name: "Sonnet",
                primary: sonnet,
                secondary: nil
            ))
        }
        if let limits = root["limits"] as? [[String: Any]] {
            for limit in limits where limit["kind"] as? String == "weekly_scoped" {
                guard let scope = limit["scope"] as? [String: Any],
                      let model = scope["model"] as? [String: Any],
                      let name = nonempty(model["display_name"] as? String),
                      let percent = number(limit["percent"])
                else { continue }
                let reset = date(limit["resets_at"])
                buckets.append(RateLimitBucket(
                    id: "model-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))",
                    name: name,
                    primary: RateLimitWindowUsage(
                        usedPercent: percent,
                        windowDurationMins: 10_080,
                        resetsAt: reset
                    ),
                    secondary: nil
                ))
            }
        }

        return ProfileRateLimits(
            planType: planType,
            buckets: buckets,
            credits: credits(root["extra_usage"]),
            fetchedAt: fetchedAt
        )
    }

    private static func window(_ value: Any?, minutes: Int) -> RateLimitWindowUsage? {
        guard let object = value as? [String: Any],
              let percent = number(object["utilization"])
        else { return nil }
        return RateLimitWindowUsage(
            usedPercent: percent,
            windowDurationMins: minutes,
            resetsAt: date(object["resets_at"])
        )
    }

    private static func credits(_ value: Any?) -> CreditsUsage? {
        guard let object = value as? [String: Any], object["is_enabled"] as? Bool == true,
              let usedCents = number(object["used_credits"])
        else { return nil }
        let used = usedCents / 100
        if let limitCents = number(object["monthly_limit"]), limitCents > 0 {
            return CreditsUsage(
                hasCredits: true,
                unlimited: false,
                balance: String(format: "$%.2f of $%.2f used", used, limitCents / 100)
            )
        }
        return CreditsUsage(
            hasCredits: true,
            unlimited: true,
            balance: String(format: "$%.2f used", used)
        )
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let number as Double: number
        case let number as Int: Double(number)
        default: nil
        }
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = nonempty(value as? String) else { return nil }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(text)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

extension ClaudeUsageResponseParser {
    /// The Claude Code projection: the 5-hour and weekly windows plus Fable's
    /// separate weekly allowance. No other model rows and no extra usage.
    static func parseClaudeCode(
        _ data: Data,
        planType: String? = nil,
        fetchedAt: Date = Date()
    ) throws -> ProfileRateLimits {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeUsageClientError.invalidResponse
        }

        var buckets: [RateLimitBucket] = []
        let session = strictWindow(root["five_hour"], minutes: 300)
        let weekly = strictWindow(root["seven_day"], minutes: 10_080)
        if session != nil || weekly != nil {
            buckets.append(RateLimitBucket(
                id: "claude",
                name: "Claude",
                primary: session,
                secondary: weekly
            ))
        }
        if let fable = fableWeekly(in: root) {
            buckets.append(RateLimitBucket(
                id: "model-fable",
                name: "Fable",
                primary: fable,
                secondary: nil
            ))
        }

        return ProfileRateLimits(
            planType: planType,
            buckets: buckets,
            credits: nil,
            fetchedAt: fetchedAt
        )
    }

    /// Fable's weekly window from `limits[]`, falling back to `seven_day_fable`.
    static func fableWeekly(in root: [String: Any]) -> RateLimitWindowUsage? {
        let legacy = strictWindow(root["seven_day_fable"], minutes: 10_080)
        let limits = (root["limits"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        var best: (percent: Double, resetsAt: Date?)?
        for limit in limits where limit["kind"] as? String == "weekly_scoped" {
            let group = limit["group"]
            guard group == nil || group is NSNull || group as? String == "weekly",
                  let percent = strictNumber(limit["percent"]),
                  let scope = limit["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  isFableModel(model)
            else { continue }
            // The highest matching percentage wins; the first one wins a tie.
            if let current = best, percent <= current.percent { continue }
            best = (percent, date(limit["resets_at"]))
        }
        guard let best else { return legacy }
        return RateLimitWindowUsage(
            usedPercent: best.percent,
            windowDurationMins: 10_080,
            resetsAt: best.resetsAt
        )
    }

    static func isFableModel(_ model: [String: Any]) -> Bool {
        if (model["id"] as? String)?.lowercased().contains("fable") == true {
            return true
        }
        guard let name = (model["display_name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else { return false }
        return name == "fable" || name.hasPrefix("fable ")
    }

    private static func strictWindow(_ value: Any?, minutes: Int) -> RateLimitWindowUsage? {
        guard let object = value as? [String: Any],
              let percent = strictNumber(object["utilization"])
        else { return nil }
        return RateLimitWindowUsage(
            usedPercent: percent,
            windowDurationMins: minutes,
            resetsAt: date(object["resets_at"])
        )
    }

    /// A finite, non-negative JSON number. Booleans and strings are rejected.
    private static func strictNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let result = number.doubleValue
        guard result.isFinite, result >= 0 else { return nil }
        return result
    }
}

struct ClaudeCredentialReader {
    private static let safeStorageService = "Claude Safe Storage"
    private static let safeStorageAccount = "Claude Key"
    private static let cacheKeys = ["oauth:tokenCacheV2", "oauth:tokenCache"]
    // One reader lives on ClaudeUsageClient's actor and shares this Desktop key
    // across profiles. Tokens and account identity are still reread for each root.
    private var desktopKey: Data?
    private let keychain: SecKeychain?

    init(keychain: SecKeychain? = nil) {
        self.keychain = keychain
    }

    mutating func readDesktopCredential(
        userDataURL: URL,
        allowKeychainInteraction: Bool
    ) -> ClaudeUsageCredential? {
        let configURL = userDataURL.appendingPathComponent("config.json")
        guard let data = try? BoundedFileReader.data(
                  at: configURL,
                  maximumBytes: LocalControlFileLimit.providerCredentialState
              ),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Self.cacheKeys.contains(where: { root[$0] is String }),
              let key = safeStorageKey(allowKeychainInteraction: allowKeychainInteraction)
        else { return nil }

        let caches = Self.cacheKeys.compactMap { cacheKey -> [String: Any]? in
            guard let encoded = root[cacheKey] as? String,
                  let encrypted = Data(base64Encoded: encoded),
                  let plaintext = try? decrypt(encrypted, key: key)
            else { return nil }
            return try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any]
        }
        let organizations = Set(caches.flatMap(desktopOrganizations))
        guard let activeOrganization = activeOrganization(userDataURL: userDataURL, key: key)
            ?? (organizations.count == 1 ? organizations.first : nil)
        else { return nil }

        guard let identity = ClaudeAccountIdentity.desktop(
            accountUUID: root["lastKnownAccountUuid"] as? String,
            organizationUUID: activeOrganization
        ) else { return nil }
        for cache in caches {
            guard let credential = selectDesktopCredential(
                cache,
                organization: activeOrganization,
                identity: identity
            ) else { continue }
            return credential
        }
        return nil
    }

    private func selectDesktopCredential(
        _ cache: [String: Any],
        organization: String,
        identity: ClaudeAccountIdentity?
    ) -> ClaudeUsageCredential? {
        let now = Date().timeIntervalSince1970 * 1_000
        var candidates: [(rank: Int, expiry: Double, credential: ClaudeUsageCredential)] = []
        for (key, raw) in cache {
            guard let metadata = desktopCacheMetadata(key),
                  metadata.organization.caseInsensitiveCompare(organization) == .orderedSame,
                  metadata.host == "https://api.anthropic.com",
                  metadata.scopes.contains("user:profile"),
                  let entry = raw as? [String: Any],
                  let token = nonempty(entry["token"] as? String),
                  let expiry = number(entry["expiresAt"]),
                  expiry > now + 120_000
            else { continue }
            let fullScope = metadata.scopes.contains("user:inference")
            let productionClient = metadata.clientID == "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
            let rank = (productionClient && fullScope ? 10_000 : 0)
                + (fullScope ? 1_000 : 0) + metadata.scopes.count
            candidates.append((
                rank,
                expiry,
                ClaudeUsageCredential(
                    accessToken: token,
                    expiresAt: expiry,
                    subscriptionType: nonempty(entry["subscriptionType"] as? String),
                    scopes: Set(metadata.scopes),
                    identity: identity
                )
            ))
        }
        return candidates.max {
            $0.rank == $1.rank ? $0.expiry < $1.expiry : $0.rank < $1.rank
        }?.credential
    }

    private func desktopCacheMetadata(
        _ value: String
    ) -> (clientID: String, organization: String, host: String, scopes: [String])? {
        let marker = ":https://api.anthropic.com:"
        guard let range = value.range(of: marker) else { return nil }
        let prefix = value[..<range.lowerBound]
        guard let separator = prefix.firstIndex(of: ":") else { return nil }
        return (
            String(prefix[..<separator]),
            String(prefix[prefix.index(after: separator)...]).lowercased(),
            "https://api.anthropic.com",
            value[range.upperBound...].split(whereSeparator: \.isWhitespace).map(String.init)
        )
    }

    private func desktopOrganizations(_ cache: [String: Any]) -> [String] {
        cache.keys.compactMap { desktopCacheMetadata($0)?.organization }
    }

    func activeOrganization(userDataURL: URL, key: Data) -> String? {
        let cookieURLs = [
            userDataURL.appendingPathComponent("Cookies"),
            userDataURL.appendingPathComponent("Network/Cookies")
        ]
        // A non-empty plain value wins; otherwise the encrypted value is used.
        let query = """
        SELECT host_key, CAST(value AS TEXT), CAST(encrypted_value AS BLOB)
        FROM cookies
        WHERE name = 'lastActiveOrg' AND host_key IN ('.claude.ai', 'claude.ai')
        ORDER BY last_update_utc DESC LIMIT 1;
        """
        for cookieURL in cookieURLs where FileManager.default.fileExists(atPath: cookieURL.path) {
            guard let row = (try? SQLiteReadOnly.query(
                database: cookieURL,
                under: userDataURL,
                sql: query,
                timeout: 2,
                maximumOutputBytes: 4_096,
                maximumRows: 1
            ))?.first,
                  row.count == 3,
                  case let .text(host) = row[0]
            else { continue }
            let value: Data
            if case let .text(plain) = row[1], !plain.isEmpty {
                value = Data(plain.utf8)
            } else if case let .blob(stored) = row[2],
                      let decrypted = try? decrypt(stored, key: key)
            {
                let hostHash = Data(SHA256.hash(data: Data(host.utf8)))
                guard decrypted.starts(with: hostHash) else { continue }
                value = decrypted.dropFirst(hostHash.count)
            } else {
                continue
            }
            guard let organization = String(data: value, encoding: .utf8),
                  UUID(uuidString: organization) != nil
            else { continue }
            return organization.lowercased()
        }
        return nil
    }

    private mutating func safeStorageKey(allowKeychainInteraction: Bool) -> Data? {
        if let desktopKey { return desktopKey }
        guard let password = readKeychainPassword(
            service: Self.safeStorageService,
            account: Self.safeStorageAccount,
            allowKeychainInteraction: allowKeychainInteraction
        ), let key = try? deriveKey(password: password) else { return nil }
        desktopKey = key
        return key
    }

    private func readKeychainPassword(
        service: String,
        account: String?,
        allowKeychainInteraction: Bool
    ) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        if !allowKeychainInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        return ClaudeKeychainAccess.withInteractionAllowed(allowKeychainInteraction) {
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data,
                  let value = String(data: data, encoding: .utf8)
            else { return nil }
            return nonempty(value)
        }
    }

    private func deriveKey(password: String) throws -> Data {
        let password = Data(password.utf8)
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let count = key.count
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1_003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        count
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw ClaudeUsageClientError.invalidCredential }
        return key
    }

    private func decrypt(_ encrypted: Data, key: Data) throws -> Data {
        guard encrypted.count > 3,
              encrypted.prefix(3) == Data("v10".utf8),
              key.count == kCCKeySizeAES128
        else { throw ClaudeUsageClientError.invalidCredential }
        let payload = encrypted.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: payload.count + kCCBlockSizeAES128)
        var outputLength = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            payload.withUnsafeBytes { payloadBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            payloadBytes.baseAddress,
                            payload.count,
                            outputBytes.baseAddress,
                            capacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw ClaudeUsageClientError.invalidCredential }
        output.count = outputLength
        return output
    }

    private func number(_ value: Any?) -> Double? {
        switch value {
        case let value as NSNumber: value.doubleValue
        case let value as Double: value
        case let value as Int: Double(value)
        default: nil
        }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

private struct ClaudeAccountProfile: Decodable {
    struct Identity: Decodable { var uuid: String }
    var account: Identity
    var organization: Identity?
}

enum ClaudeUsageClientError: Error {
    case invalidResponse
    case responseTooLarge
    case invalidCredential
    case identityMismatch
    case unauthorized
    case rateLimited(retryAfter: String?)
    case requestFailed(Int)
}

// Claude uses the file-based login Keychain. LAContext only suppresses UI for
// Data Protection items; legacy Keychain access needs the process-level flag.
// Serialize the synchronous read and restore the prior flag before returning.
enum ClaudeKeychainAccess {
    private static let lock = NSLock()

    static func withInteractionAllowed<T>(_ allowed: Bool, operation: () -> T?) -> T? {
        lock.lock()
        defer { lock.unlock() }
        var previous = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess else { return nil }
        guard SecKeychainSetUserInteractionAllowed(allowed) == errSecSuccess else { return nil }
        defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return operation()
    }
}
