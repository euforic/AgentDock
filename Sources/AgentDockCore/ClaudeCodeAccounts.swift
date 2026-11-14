import Foundation

/// The Claude Code sign-in of one AgentDock profile, as that profile's page
/// shows it. `limits` is nil until its first fetch finishes.
public struct ClaudeCodeAccountUsage: Identifiable, Equatable, Sendable {
    /// The profile this sign-in belongs to; each profile has at most one.
    public var profile: ClaudeCodeProfileID
    /// The key of the Claude account last seen on this profile's sign-in; see
    /// `ClaudeLoginAccountKey`. Nil before it has been read.
    public var accountKey: String?
    /// The last account seen; nil when the item could not be read.
    public var account: ClaudeLoginAccount?
    public var status: ClaudeCodeLoginStatus
    /// The profile's item exists but is not a sign-in AgentDock can use.
    public var signInUnreadable: Bool
    public var limits: ProfileRateLimits?
    /// When a provider cooldown or the hourly request budget ends, if one is active.
    public var rateLimitedUntil: Date?

    public var id: ClaudeCodeProfileID { profile }

    /// The user's name for the account, or else its email.
    public var title: String {
        account?.displayName ?? "Claude account"
    }

    public init(
        profile: ClaudeCodeProfileID,
        accountKey: String? = nil,
        account: ClaudeLoginAccount?,
        status: ClaudeCodeLoginStatus,
        signInUnreadable: Bool = false,
        limits: ProfileRateLimits? = nil,
        rateLimitedUntil: Date? = nil
    ) {
        self.profile = profile
        self.accountKey = accountKey
        self.account = account
        self.status = status
        self.signInUnreadable = signInUnreadable
        self.limits = limits
        self.rateLimitedUntil = rateLimitedUntil
    }

    /// A profile whose sign-in has not been read yet.
    public static func checking(_ profile: ClaudeCodeProfileID) -> Self {
        Self(profile: profile, account: nil, status: .unknown)
    }

    /// What the profile's Claude Code card shows.
    public func phase(now: Date = Date()) -> ClaudeCodeUsagePhase {
        switch status {
        case .unknown:
            return .checking
        case .keychainAccessRequired:
            return .keychainAccessRequired
        case let .signedOut(expired):
            if expired { return .reauthenticationRequired(ClaudeCodeUsageMessage.signInExpired) }
            if signInUnreadable { return .reauthenticationRequired(ClaudeCodeUsageMessage.unreadableSignIn) }
            return .signedOut
        case .signedIn:
            guard let limits else { return .loading }
            let reauthentication = [
                ClaudeCodeUsageMessage.signInExpired,
                ClaudeCodeUsageMessage.identityMismatch,
                ClaudeCodeUsageMessage.unreadableSignIn,
                ClaudeCodeUsageMessage.missingProfileScope
            ]
            if let error = limits.errorMessage, reauthentication.contains(error) {
                return .reauthenticationRequired(error)
            }
            if limits.errorMessage == ClaudeCodeUsageMessage.keychainAccessRequired {
                return .keychainAccessRequired
            }
            if let until = rateLimitedUntil, until > now {
                let budget = limits.errorMessage == ClaudeUsageClient.budgetError
                    || limits.warningMessage == ClaudeUsageClient.budgetWarning
                return budget ? .budgetExhausted(until: until) : .rateLimited(until: until)
            }
            if let error = limits.errorMessage { return .error(error) }
            return .ok
        }
    }
}

/// The states of one profile's Claude Code card.
public enum ClaudeCodeUsagePhase: Equatable, Sendable {
    /// The sign-in has not been read yet.
    case checking
    /// Reading the sign-in needs a Keychain prompt; a manual refresh can show it.
    case keychainAccessRequired
    /// The profile has no sign-in.
    case signedOut
    /// The stored sign-in can no longer be used; signing in again fixes it.
    case reauthenticationRequired(String)
    /// Signed in; the first fetch has not finished.
    case loading
    /// Signed in with live limits (possibly the last successful update with a warning).
    case ok
    /// A provider 429 cooldown is active.
    case rateLimited(until: Date)
    /// The account spent AgentDock's hourly request budget.
    case budgetExhausted(until: Date)
    /// The last fetch failed for another reason.
    case error(String)
}

/// The account controls a profile's Claude Code card offers. A profile stays
/// with one Claude account, so a working sign-in offers no Sign In.
public struct ClaudeCodeAccountControls: Equatable, Sendable {
    public enum SignIn: Equatable, Sendable {
        /// The profile has no sign-in; any Claude account may sign in.
        case anyAccount
        /// The sign-in must be renewed; only the profile's own account may sign in.
        case sameAccount
    }

    /// Nil: the card shows no Sign In.
    public var signIn: SignIn?
    public var rename: Bool
    public var signOut: Bool

    public init(signIn: SignIn? = nil, rename: Bool = false, signOut: Bool = false) {
        self.signIn = signIn
        self.rename = rename
        self.signOut = signOut
    }

    /// No controls.
    public static let empty = Self()
}

extension ClaudeCodeUsagePhase {
    /// The controls the card shows in this phase.
    public var accountControls: ClaudeCodeAccountControls {
        switch self {
        case .checking, .keychainAccessRequired:
            return .empty
        case .signedOut:
            return ClaudeCodeAccountControls(signIn: .anyAccount)
        case let .reauthenticationRequired(message) where message == ClaudeCodeUsageMessage.unreadableSignIn:
            // Its account is unknown, so no sign-in can replace it.
            return ClaudeCodeAccountControls(signOut: true)
        case .reauthenticationRequired:
            return ClaudeCodeAccountControls(signIn: .sameAccount, signOut: true)
        case .loading, .ok, .rateLimited, .budgetExhausted, .error:
            return ClaudeCodeAccountControls(rename: true, signOut: true)
        }
    }
}

/// The Claude Code sign-ins of the requested profiles, in the requested order.
public struct ClaudeCodeUsageReport: Equatable, Sendable {
    /// At least one profile's sign-in needs a Keychain prompt that was not allowed.
    public var keychainAccessRequired: Bool
    public var accounts: [ClaudeCodeAccountUsage]

    public init(keychainAccessRequired: Bool = false, accounts: [ClaudeCodeAccountUsage] = []) {
        self.keychainAccessRequired = keychainAccessRequired
        self.accounts = accounts
    }
}

/// A Claude profile that sign-ins from earlier versions can be placed on.
public struct ClaudeCodeMigrationTarget: Equatable, Sendable {
    public var profile: ClaudeCodeProfileID
    /// The profile's name in AgentDock. A managed profile matches a sign-in
    /// whose AgentDock name or email equals it, ignoring case and outer spaces.
    public var name: String

    public init(profile: ClaudeCodeProfileID, name: String) {
        self.profile = profile
        self.name = name
    }
}

/// What one migration run did.
public struct ClaudeCodeMigrationResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Every step that was attempted succeeded.
        case complete
        /// A Keychain prompt was needed and not allowed; nothing was changed
        /// after that point, and the run can be repeated with interaction.
        case keychainAccessRequired
        /// A step failed. The earlier item involved is kept; the next run retries.
        case failed
    }

    public var outcome: Outcome
    /// Sign-ins placed in this run: profile to account key.
    public var placed: [ClaudeCodeProfileID: String]
    /// Account keys of earlier sign-ins that are kept because no profile could
    /// take them, sorted. They are retried on every launch.
    public var unplacedAccountKeys: [String]

    public init(
        outcome: Outcome,
        placed: [ClaudeCodeProfileID: String] = [:],
        unplacedAccountKeys: [String] = []
    ) {
        self.outcome = outcome
        self.placed = placed
        self.unplacedAccountKeys = unplacedAccountKeys
    }
}

/// The Claude Code sign-ins of AgentDock's Claude profiles: exactly one item
/// and one `ClaudeCodeLogin` per profile, so renewal, renaming, sign-out, and
/// a new sign-in touch only that profile. Sign-ins are added only by an
/// explicit sign-in on a profile's page or by migrating AgentDock's own
/// earlier items; nothing is discovered from other apps.
///
/// A profile is bound to the Claude account it signed in with: signing in
/// again is accepted only for that account (renewing its tokens), and another
/// account is refused until the profile signs out. Migration never places a
/// sign-in on a profile that already has an item, readable or not.
public actor ClaudeCodeAccounts {
    private let store: any ClaudeLoginAccountStoring
    private let transport: any ClaudeHTTPTransport
    private var logins: [ClaudeCodeProfileID: ClaudeCodeLogin] = [:]
    private var signInInProgress = false

    public init(
        store: any ClaudeLoginAccountStoring,
        transport: any ClaudeHTTPTransport = URLSessionClaudeHTTPTransport()
    ) {
        self.store = store
        self.transport = transport
    }

    /// Each profile's sign-in status, without limits, in the given order.
    public func list(
        profiles: [ClaudeCodeProfileID],
        allowKeychainInteraction: Bool = false
    ) async -> ClaudeCodeUsageReport {
        var accounts: [ClaudeCodeAccountUsage] = []
        for profile in profiles {
            accounts.append(await Self.usage(
                for: profile,
                login: login(for: profile),
                allowKeychainInteraction: allowKeychainInteraction
            ))
        }
        return ClaudeCodeUsageReport(
            keychainAccessRequired: accounts.contains { $0.status == .keychainAccessRequired },
            accounts: accounts
        )
    }

    // MARK: - Sign in, rename, and sign out

    /// Runs one PKCE sign-in through claude.ai and stores it as this profile's
    /// sign-in. A profile without a sign-in takes any account; a profile bound
    /// to an account accepts only that account again, which renews its tokens.
    /// Another account is refused with `.differentAccount` and the profile's
    /// item is kept. A sign-in that cannot be read refuses every account
    /// before the browser opens. Other profiles, even ones signed in to the
    /// same account, are untouched.
    public func signIn(
        profile: ClaudeCodeProfileID,
        progress: @escaping @Sendable (ClaudeSignInProgress) async -> Void,
        pastedCodes: AsyncStream<String>
    ) async throws(ClaudeSignInError) -> ClaudeCodeAccountUsage {
        guard !signInInProgress else { throw ClaudeSignInError.alreadyInProgress }
        signInInProgress = true
        defer { signInInProgress = false }

        try await login(for: profile).checkCanSignIn()
        let signedIn = try await ClaudeSignInFlow(transport: transport).run(
            progress: progress,
            pastedCodes: pastedCodes
        )
        // Fetched again: the login may have been replaced meanwhile, and the
        // binding is checked as it is now.
        let profileLogin = self.login(for: profile)
        let account = try await profileLogin.adopt(signedIn)
        return ClaudeCodeAccountUsage(
            profile: profile,
            accountKey: signedIn.accountKey,
            account: account,
            status: .signedIn(account)
        )
    }

    /// Sets or clears the user's name for this profile's account.
    public func rename(
        profile: ClaudeCodeProfileID,
        to name: String?
    ) async throws(ClaudeSignInError) -> ClaudeLoginAccount {
        guard let login = logins[profile] else { throw ClaudeSignInError.accountNotFound }
        return try await login.rename(to: name)
    }

    /// Deletes only this profile's item; other profiles are untouched. Used
    /// for Sign Out and when the profile itself is removed from AgentDock.
    public func signOut(profile: ClaudeCodeProfileID) async throws(ClaudeSignInError) {
        let login = logins[profile] ?? makeLogin(profile)
        let account = await login.knownIdentity()?.accountKey
            ?? (try? store.tokenStore(forProfile: profile).load(allowInteraction: false))?.accountKey
        try await login.signOut()
        // A fresh login next time, so no account from before is remembered.
        logins[profile] = nil
        // An earlier item of the same account whose delete failed after
        // migration must not bring this sign-in back on the next launch.
        if let account {
            try? store.tokenStore(forAccountKey: account).delete(allowInteraction: false)
            let legacy = store.legacyTokenStore
            if (try? legacy.load(allowInteraction: false))?.accountKey == account {
                try? legacy.delete(allowInteraction: false)
            }
        }
    }

    /// Deletes the items of managed profiles that no longer exist, for
    /// example when deleting a removed profile's sign-in failed earlier. The
    /// Official Claude item and the items of `existing` profiles are kept.
    @discardableResult
    public func removeSignIns(
        keeping existing: Set<ClaudeCodeProfileID>,
        allowKeychainInteraction: Bool = false
    ) -> Bool {
        guard let stored = try? store.profileIDs(allowInteraction: allowKeychainInteraction) else {
            return false
        }
        var removedAll = true
        for profile in stored where profile != .official && !existing.contains(profile) {
            do {
                try store.tokenStore(forProfile: profile).delete(allowInteraction: allowKeychainInteraction)
                logins[profile] = nil
            } catch {
                removedAll = false
            }
        }
        return removedAll
    }

    // MARK: - Profiles for live limits

    struct Entry: Sendable {
        var profile: ClaudeCodeProfileID
        var login: ClaudeCodeLogin
    }

    /// Pairs each profile with its login. A profile's item is read lazily by
    /// its login, so no listing of the Keychain is needed.
    func entries(for profiles: [ClaudeCodeProfileID]) -> [Entry] {
        profiles.map { Entry(profile: $0, login: login(for: $0)) }
    }

    func login(for profile: ClaudeCodeProfileID) -> ClaudeCodeLogin {
        if let existing = logins[profile] { return existing }
        let created = makeLogin(profile)
        logins[profile] = created
        return created
    }

    /// One profile's card without limits.
    static func usage(
        for profile: ClaudeCodeProfileID,
        login: ClaudeCodeLogin,
        allowKeychainInteraction: Bool
    ) async -> ClaudeCodeAccountUsage {
        let summary = await login.summary(allowKeychainInteraction: allowKeychainInteraction)
        let unreadable = await login.isUnreadable()
        let identity = await login.knownIdentity()
        return ClaudeCodeAccountUsage(
            profile: profile,
            accountKey: identity?.accountKey,
            account: summary.account,
            status: summary.status,
            signInUnreadable: unreadable
        )
    }

    // MARK: - Migration

    private enum Source: Equatable {
        case legacy
        case keyed(String)
    }

    private struct Candidate {
        var source: Source
        var tokens: ClaudeLoginTokens
    }

    private enum PlacementFailure: Error {
        case keychainAccessRequired
        case failed
    }

    /// Places the sign-ins earlier versions stored (one item per account key,
    /// and the single item before that) on profiles. Run once at startup;
    /// running it again with the same profiles changes nothing.
    ///
    /// - A sign-in goes to the first managed profile, in `targets` order,
    ///   whose name equals the sign-in's AgentDock name, else to the first
    ///   whose name equals its email (ignoring case and outer spaces), else to
    ///   Official Claude, the default profile. Only data in AgentDock's own
    ///   items and profile list is compared; nothing else is read.
    /// - Each profile gets at most one. When several would land on the same
    ///   profile, the one added to AgentDock first wins (a missing date counts
    ///   as earliest), then the lower account key. A profile that already has
    ///   a sign-in keeps it.
    /// - A placed sign-in is written to the profile's item, read back and
    ///   compared, and only then is the earlier item deleted. Any failure keeps
    ///   the earlier item.
    /// - Sign-ins that cannot be placed keep their earlier item untouched and
    ///   are reported. An earlier item whose account is already signed in on a
    ///   profile is redundant and deleted, as is a single legacy item whose
    ///   account also has an account-keyed item (the keyed one is newer).
    public func migrateEarlierSignIns(
        to targets: [ClaudeCodeMigrationTarget],
        allowKeychainInteraction: Bool = false
    ) -> ClaudeCodeMigrationResult {
        let allow = allowKeychainInteraction
        var targets = targets
        if !targets.contains(where: { $0.profile == .official }) {
            targets.insert(ClaudeCodeMigrationTarget(profile: .official, name: ""), at: 0)
        }
        var seen: Set<ClaudeCodeProfileID> = []
        targets = targets.filter { seen.insert($0.profile).inserted }
        var failed = false

        // 1. The earlier items.
        var candidates: [Candidate] = []
        let keys: [String]
        do {
            keys = try store.accountKeys(allowInteraction: allow)
        } catch ClaudeLoginStoreError.interactionRequired {
            return ClaudeCodeMigrationResult(outcome: .keychainAccessRequired)
        } catch {
            return ClaudeCodeMigrationResult(outcome: .failed)
        }
        for key in keys {
            switch Self.read(store.tokenStore(forAccountKey: key), allowInteraction: allow) {
            case let .success(tokens?):
                candidates.append(Candidate(source: .keyed(key), tokens: tokens))
            case .success(nil):
                break
            case .failure(.keychainAccessRequired):
                return ClaudeCodeMigrationResult(outcome: .keychainAccessRequired)
            case .failure(.failed):
                failed = true
            }
        }
        switch Self.read(store.legacyTokenStore, allowInteraction: allow) {
        case let .success(tokens?):
            candidates.append(Candidate(source: .legacy, tokens: tokens))
        case .success(nil):
            break
        case .failure(.keychainAccessRequired):
            return ClaudeCodeMigrationResult(outcome: .keychainAccessRequired)
        case .failure(.failed):
            failed = true
        }
        guard !candidates.isEmpty else {
            return ClaudeCodeMigrationResult(outcome: failed ? .failed : .complete)
        }

        // 2. Which profiles already have a sign-in. One that cannot be read
        // for another reason is treated as taken, so it is never overwritten.
        var taken: Set<ClaudeCodeProfileID> = []
        var signedInAccounts: Set<String> = []
        for target in targets {
            do {
                if let tokens = try store.tokenStore(forProfile: target.profile).load(allowInteraction: allow) {
                    taken.insert(target.profile)
                    signedInAccounts.insert(tokens.accountKey)
                }
            } catch ClaudeLoginStoreError.unreadable {
                // Its account is unknown, but it still binds the profile until
                // Sign Out, so migration never overwrites it.
                taken.insert(target.profile)
            } catch ClaudeLoginStoreError.interactionRequired {
                return ClaudeCodeMigrationResult(outcome: .keychainAccessRequired)
            } catch {
                taken.insert(target.profile)
                failed = true
            }
        }

        // 3. Redundant earlier items.
        let keyedAccounts = Set(candidates.compactMap { candidate -> String? in
            if case .keyed = candidate.source { return candidate.tokens.accountKey }
            return nil
        })
        var remaining: [Candidate] = []
        for candidate in candidates {
            let account = candidate.tokens.accountKey
            let redundant = signedInAccounts.contains(account)
                || (candidate.source == .legacy && keyedAccounts.contains(account))
            guard redundant else {
                remaining.append(candidate)
                continue
            }
            do {
                try sourceStore(candidate.source).delete(allowInteraction: allow)
            } catch ClaudeLoginStoreError.interactionRequired {
                return ClaudeCodeMigrationResult(outcome: .keychainAccessRequired)
            } catch {
                failed = true
            }
        }

        // 4. Place the rest, at most one per profile.
        let groups = Dictionary(grouping: remaining) { candidate in
            Self.matchingProfile(for: candidate.tokens, in: targets) ?? .official
        }
        var placed: [ClaudeCodeProfileID: String] = [:]
        var unplaced: [String] = []
        for target in targets {
            guard let group = groups[target.profile], !group.isEmpty else { continue }
            let ordered = group.sorted(by: Self.placementOrder)
            guard !taken.contains(target.profile) else {
                unplaced.append(contentsOf: ordered.map(\.tokens.accountKey))
                continue
            }
            let winner = ordered[0]
            unplaced.append(contentsOf: ordered.dropFirst().map(\.tokens.accountKey))
            switch place(winner, on: target.profile, allowInteraction: allow) {
            case .success:
                placed[target.profile] = winner.tokens.accountKey
            case .failure(.keychainAccessRequired):
                return ClaudeCodeMigrationResult(
                    outcome: .keychainAccessRequired,
                    placed: placed,
                    unplacedAccountKeys: unplaced.sorted()
                )
            case .failure(.failed):
                failed = true
                unplaced.append(winner.tokens.accountKey)
            }
        }
        return ClaudeCodeMigrationResult(
            outcome: failed ? .failed : .complete,
            placed: placed,
            unplacedAccountKeys: Array(Set(unplaced)).sorted()
        )
    }

    /// Deletes earlier items that migration could not place, at the user's
    /// request. Profile items are never touched.
    public func discardUnplacedSignIns(accountKeys: [String]) throws(ClaudeSignInError) {
        let discarded = Set(accountKeys)
        do {
            for key in accountKeys where ClaudeLoginAccountKey.isValid(key) {
                try store.tokenStore(forAccountKey: key).delete(allowInteraction: true)
            }
            if let legacy = try? store.legacyTokenStore.load(allowInteraction: true),
               discarded.contains(legacy.accountKey)
            {
                try store.legacyTokenStore.delete(allowInteraction: true)
            }
        } catch {
            throw ClaudeSignInError.keychain(ClaudeCodeLogin.storeError(error))
        }
    }

    /// The managed profile a sign-in matches, by AgentDock name first and
    /// then by email; nil means the default profile.
    static func matchingProfile(
        for tokens: ClaudeLoginTokens,
        in targets: [ClaudeCodeMigrationTarget]
    ) -> ClaudeCodeProfileID? {
        let managed = targets.filter { target in
            if case .managed = target.profile { return true }
            return false
        }
        for value in [tokens.customName, tokens.accountLabel] {
            guard let wanted = normalizedName(value) else { continue }
            if let match = managed.first(where: { normalizedName($0.name) == wanted }) {
                return match.profile
            }
        }
        return nil
    }

    private static func normalizedName(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }

    /// Earliest added first (a missing date counts as earliest), then the lower account key.
    private static func placementOrder(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        let left = lhs.tokens.addedAt ?? .distantPast
        let right = rhs.tokens.addedAt ?? .distantPast
        if left != right { return left < right }
        return lhs.tokens.accountKey < rhs.tokens.accountKey
    }

    /// Reads an earlier item. An unreadable one is left untouched and skipped.
    private static func read(
        _ item: any ClaudeLoginTokenStoring,
        allowInteraction: Bool
    ) -> Result<ClaudeLoginTokens?, PlacementFailure> {
        do {
            return .success(try item.load(allowInteraction: allowInteraction))
        } catch ClaudeLoginStoreError.unreadable {
            return .success(nil)
        } catch ClaudeLoginStoreError.interactionRequired {
            return .failure(.keychainAccessRequired)
        } catch {
            return .failure(.failed)
        }
    }

    /// Writes the profile's item, reads it back, and only then deletes the
    /// earlier item. An unverified copy is removed so it is never trusted.
    private func place(
        _ candidate: Candidate,
        on profile: ClaudeCodeProfileID,
        allowInteraction: Bool
    ) -> Result<Void, PlacementFailure> {
        let target = store.tokenStore(forProfile: profile)
        var copy = candidate.tokens
        if copy.addedAt == nil {
            copy.addedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        }
        do {
            try target.save(copy, allowInteraction: allowInteraction)
        } catch ClaudeLoginStoreError.interactionRequired {
            return .failure(.keychainAccessRequired)
        } catch {
            return .failure(.failed)
        }
        let written = try? target.load(allowInteraction: allowInteraction)
        guard let written, written.matchesStoredCopy(copy) else {
            try? target.delete(allowInteraction: allowInteraction)
            return .failure(.failed)
        }
        // The profile's login reads the new item on its next use.
        logins[profile] = nil
        // If this delete fails, the earlier item is redundant from now on and
        // the next run deletes it.
        try? sourceStore(candidate.source).delete(allowInteraction: allowInteraction)
        return .success(())
    }

    private func sourceStore(_ source: Source) -> any ClaudeLoginTokenStoring {
        switch source {
        case .legacy: store.legacyTokenStore
        case let .keyed(key): store.tokenStore(forAccountKey: key)
        }
    }

    private func makeLogin(_ profile: ClaudeCodeProfileID) -> ClaudeCodeLogin {
        ClaudeCodeLogin(store: store.tokenStore(forProfile: profile), transport: transport)
    }
}

/// One PKCE sign-in through claude.ai, ending with the tokens and the account
/// they belong to. Nothing is stored here. Tokens, codes, the verifier, the
/// email, and the account identifiers are never logged.
struct ClaudeSignInFlow: Sendable {
    let transport: any ClaudeHTTPTransport

    /// The code arrives at the loopback listener or as the first value of
    /// `pastedCodes`, whichever comes first.
    func run(
        progress: @escaping @Sendable (ClaudeSignInProgress) async -> Void,
        pastedCodes: AsyncStream<String>,
        now: Date = Date()
    ) async throws(ClaudeSignInError) -> ClaudeLoginTokens {
        let pkce = ClaudePKCE.generate()
        let state = UUID().uuidString
        let server = try await ClaudeLoopbackCallbackServer.start(expectedState: state)
        defer { server.cancel() }
        let redirectURI = server.redirectURI

        await progress(.waitingForBrowser(ClaudeOAuth.authorizeURL(
            redirectURI: redirectURI,
            challenge: pkce.challenge,
            state: state
        )))
        let input = try await Self.authorization(from: server, pastedCodes: pastedCodes)
        let code = try ClaudeOAuth.authorizationCode(from: input, expectedState: state)
        server.cancel()
        try ClaudeCodeLogin.checkCancellation()

        await progress(.exchangingCode)
        let token = try await exchange(
            code: code,
            state: state,
            redirectURI: redirectURI,
            verifier: pkce.verifier
        )
        let profile = try await readProfile(accessToken: token.accessToken)
        try ClaudeCodeLogin.checkCancellation()

        let grantedScopes = ClaudeCodeLogin.scopeList(token.scope)
        return ClaudeLoginTokens(
            accessToken: token.accessToken,
            refreshToken: ClaudeCodeLogin.nonEmpty(token.refreshToken),
            expiresAt: ClaudeCodeLogin.expiry(token.expiresIn, now: now),
            scopes: grantedScopes.isEmpty ? ClaudeCodeLogin.scopeList(ClaudeOAuth.scopes) : grantedScopes,
            accountUUID: profile.identity.accountUUID,
            organizationUUID: profile.identity.organizationUUID,
            accountLabel: profile.label,
            subscriptionType: profile.subscriptionType,
            customName: nil,
            addedAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        )
    }

    private static func authorization(
        from server: ClaudeLoopbackCallbackServer,
        pastedCodes: AsyncStream<String>
    ) async throws(ClaudeSignInError) -> ClaudeAuthorizationInput {
        do {
            return try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: ClaudeAuthorizationInput.self) { group in
                    group.addTask {
                        let code = try await server.waitForCode()
                        return .callback(code)
                    }
                    group.addTask {
                        for await code in pastedCodes {
                            return .pasted(code)
                        }
                        throw ClaudeSignInError.cancelled
                    }
                    defer {
                        // Unblocks whichever source lost the race.
                        server.cancel()
                        group.cancelAll()
                    }
                    guard let first = try await group.next() else {
                        throw ClaudeSignInError.cancelled
                    }
                    return first
                }
            } onCancel: {
                server.cancel()
            }
        } catch let error as ClaudeSignInError {
            throw error
        } catch {
            throw ClaudeSignInError.cancelled
        }
    }

    private func exchange(
        code: String,
        state: String,
        redirectURI: String,
        verifier: String
    ) async throws(ClaudeSignInError) -> ClaudeTokenResponse {
        let (data, response) = try await send(ClaudeOAuth.codeExchangeRequest(
            code: code,
            state: state,
            redirectURI: redirectURI,
            verifier: verifier
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw ClaudeSignInError.requestFailed(response.statusCode)
        }
        guard let token = try? JSONDecoder().decode(ClaudeTokenResponse.self, from: data),
              ClaudeCodeLogin.nonEmpty(token.accessToken) != nil
        else { throw ClaudeSignInError.invalidResponse }
        return token
    }

    private func readProfile(
        accessToken: String
    ) async throws(ClaudeSignInError) -> (identity: ClaudeAccountIdentity, label: String, subscriptionType: String?) {
        let (data, response) = try await send(
            ClaudeAPIRequest.get(ClaudeOAuth.profileURL, bearer: accessToken)
        )
        guard (200..<300).contains(response.statusCode),
              let profile = try? JSONDecoder().decode(ClaudeSignInProfile.self, from: data),
              let organization = profile.organization,
              let identity = ClaudeAccountIdentity.desktop(
                  accountUUID: profile.account.uuid,
                  organizationUUID: organization.uuid
              )
        else { throw ClaudeSignInError.profileUnavailable }
        let label = ClaudeCodeLogin.nonEmpty(profile.account.email)
            ?? ClaudeCodeLogin.nonEmpty(profile.email)
            ?? "Claude account"
        let plan = ClaudeCodeLogin.nonEmpty(organization.organizationType).map { type in
            type.hasPrefix("claude_") ? String(type.dropFirst("claude_".count)) : type
        }
        return (identity, label, plan)
    }

    private func send(_ request: URLRequest) async throws(ClaudeSignInError) -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request, maximumResponseBytes: ClaudeOAuth.maximumResponseBytes)
        } catch {
            throw Task.isCancelled ? ClaudeSignInError.cancelled : ClaudeSignInError.connectionFailed
        }
    }
}

/// The fields AgentDock reads from `/api/oauth/profile` at sign-in.
private struct ClaudeSignInProfile: Decodable {
    struct Account: Decodable {
        var uuid: String
        var email: String?
    }

    struct Organization: Decodable {
        var uuid: String
        var organizationType: String?

        private enum CodingKeys: String, CodingKey {
            case uuid
            case organizationType = "organization_type"
        }
    }

    var account: Account
    var organization: Organization?
    var email: String?
}
