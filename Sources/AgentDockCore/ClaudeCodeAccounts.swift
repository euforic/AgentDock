import Foundation

/// One Claude account signed in to AgentDock, as the Claude Code limits
/// section shows it. `limits` is nil until its first fetch finishes.
public struct ClaudeCodeAccountUsage: Identifiable, Equatable, Sendable {
    /// The account key; see `ClaudeLoginAccountKey`.
    public var key: String
    /// The last account seen; nil when the item could not be read.
    public var account: ClaudeLoginAccount?
    public var status: ClaudeCodeLoginStatus
    public var limits: ProfileRateLimits?
    /// When a provider cooldown or the hourly request budget ends, if one is active.
    public var rateLimitedUntil: Date?

    public var id: String { key }

    /// The user's name for the account, or else its email.
    public var title: String {
        account?.displayName ?? "Claude account"
    }

    public init(
        key: String,
        account: ClaudeLoginAccount?,
        status: ClaudeCodeLoginStatus,
        limits: ProfileRateLimits? = nil,
        rateLimitedUntil: Date? = nil
    ) {
        self.key = key
        self.account = account
        self.status = status
        self.limits = limits
        self.rateLimitedUntil = rateLimitedUntil
    }
}

/// Every Claude Code account, in the order they were added.
public struct ClaudeCodeUsageReport: Equatable, Sendable {
    /// Listing or migrating needed a Keychain prompt that was not allowed.
    public var keychainAccessRequired: Bool
    public var accounts: [ClaudeCodeAccountUsage]

    public init(keychainAccessRequired: Bool = false, accounts: [ClaudeCodeAccountUsage] = []) {
        self.keychainAccessRequired = keychainAccessRequired
        self.accounts = accounts
    }
}

/// The Claude accounts signed in to AgentDock for Claude Code limits. Each
/// account has its own Keychain item and its own `ClaudeCodeLogin`, so renewal,
/// renaming, and sign-out touch only that account. Accounts are added only by
/// an explicit sign-in; nothing is discovered from other apps.
public actor ClaudeCodeAccounts {
    enum MigrationResult: Equatable {
        /// Nothing left to migrate.
        case complete
        case keychainAccessRequired
        /// The legacy item is kept; migration is retried on the next listing.
        case failed
    }

    private let store: any ClaudeLoginAccountStoring
    private let transport: any ClaudeHTTPTransport
    private var logins: [String: ClaudeCodeLogin] = [:]
    private var migrated = false
    private var signInInProgress = false

    public init(
        store: any ClaudeLoginAccountStoring,
        transport: any ClaudeHTTPTransport = URLSessionClaudeHTTPTransport()
    ) {
        self.store = store
        self.transport = transport
    }

    /// Every account and its sign-in status, without limits.
    public func list(allowKeychainInteraction: Bool = false) async -> ClaudeCodeUsageReport {
        let listing = await entries(allowKeychainInteraction: allowKeychainInteraction)
        var accounts: [ClaudeCodeAccountUsage] = []
        for entry in listing.entries {
            let summary = await entry.login.summary(allowKeychainInteraction: allowKeychainInteraction)
            accounts.append(ClaudeCodeAccountUsage(
                key: entry.key,
                account: summary.account,
                status: summary.status
            ))
        }
        return ClaudeCodeUsageReport(
            keychainAccessRequired: listing.keychainAccessRequired,
            accounts: accounts
        )
    }

    // MARK: - Sign in, rename, and sign out

    /// Runs one PKCE sign-in through claude.ai and stores it under its account
    /// key. Signing in to an account that is already here replaces its item.
    public func addAccount(
        progress: @escaping @Sendable (ClaudeSignInProgress) async -> Void,
        pastedCodes: AsyncStream<String>
    ) async throws(ClaudeSignInError) -> ClaudeCodeAccountUsage {
        guard !signInInProgress else { throw ClaudeSignInError.alreadyInProgress }
        signInInProgress = true
        defer { signInInProgress = false }

        let signedIn = try await ClaudeSignInFlow(transport: transport).run(
            progress: progress,
            pastedCodes: pastedCodes
        )
        let key = signedIn.accountKey
        let login = logins[key] ?? makeLogin(key)
        let account = try await login.adopt(signedIn)
        logins[key] = login
        return ClaudeCodeAccountUsage(key: key, account: account, status: .signedIn(account))
    }

    /// Sets or clears the user's name for one account.
    public func rename(
        accountKey: String,
        to name: String?
    ) async throws(ClaudeSignInError) -> ClaudeLoginAccount {
        guard let login = logins[accountKey] else { throw ClaudeSignInError.accountNotFound }
        return try await login.rename(to: name)
    }

    /// Deletes only this account's item; other accounts are untouched.
    public func signOut(accountKey: String) async throws(ClaudeSignInError) {
        let login = logins[accountKey] ?? makeLogin(accountKey)
        try await login.signOut()
        logins[accountKey] = nil
        // A legacy item that failed to delete after migrating must not bring
        // this account back on the next listing.
        let legacy = store.legacyTokenStore
        if !migrated,
           let stored = try? legacy.load(allowInteraction: false),
           stored.accountKey == accountKey
        {
            try? legacy.delete(allowInteraction: false)
        }
    }

    // MARK: - Accounts for live limits

    struct Entry: Sendable {
        var key: String
        var login: ClaudeCodeLogin
    }

    /// Migrates the legacy item if needed, then pairs each stored account with
    /// its login. An account Claude refused stays listed so its card can ask
    /// for a new sign-in; an item deleted elsewhere is dropped.
    func entries(
        allowKeychainInteraction: Bool
    ) async -> (keychainAccessRequired: Bool, entries: [Entry]) {
        var accessRequired = false
        if !migrated {
            switch migrateLegacyIfNeeded(allowInteraction: allowKeychainInteraction) {
            case .complete: migrated = true
            case .keychainAccessRequired: accessRequired = true
            case .failed: break
            }
        }

        do {
            let keys = try store.accountKeys(allowInteraction: allowKeychainInteraction)
            for key in keys where logins[key] == nil {
                logins[key] = makeLogin(key)
            }
            let stored = Set(keys)
            for (key, login) in logins where !stored.contains(key) {
                let refused = await login.showsExpiryNotice()
                if !refused { logins[key] = nil }
            }
        } catch {
            // Keep the accounts already known; their own items still answer.
            accessRequired = true
        }

        var ordered: [(entry: Entry, addedAt: Date?, label: String)] = []
        for (key, login) in logins {
            let summary = await login.summary()
            ordered.append((
                entry: Entry(key: key, login: login),
                addedAt: summary.account?.addedAt,
                label: summary.account?.label ?? ""
            ))
        }
        ordered.sort { lhs, rhs in
            switch (lhs.addedAt, rhs.addedAt) {
            case let (left?, right?) where left != right: return left < right
            case (nil, _?): return true
            case (_?, nil): return false
            default:
                if lhs.label != rhs.label {
                    return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
                }
                return lhs.entry.key < rhs.entry.key
            }
        }
        return (accessRequired, ordered.map { $0.entry })
    }

    func login(forAccountKey accountKey: String) -> ClaudeCodeLogin? {
        logins[accountKey]
    }

    // MARK: - Migration

    /// Moves the single pre-multi-account item to its account-keyed item:
    /// write the new item, read it back, and only then delete the old one.
    /// Running it again is harmless, and a failure keeps the old item.
    func migrateLegacyIfNeeded(allowInteraction: Bool) -> MigrationResult {
        let legacyStore = store.legacyTokenStore
        let legacy: ClaudeLoginTokens?
        do {
            legacy = try legacyStore.load(allowInteraction: allowInteraction)
        } catch ClaudeLoginStoreError.unreadable {
            // Not a sign-in AgentDock can use; it is left in place, untouched.
            return .complete
        } catch ClaudeLoginStoreError.interactionRequired {
            return .keychainAccessRequired
        } catch {
            return .failed
        }
        guard let legacy else { return .complete }

        let target = store.tokenStore(forAccountKey: legacy.accountKey)
        do {
            let existing: ClaudeLoginTokens?
            do {
                existing = try target.load(allowInteraction: allowInteraction)
            } catch ClaudeLoginStoreError.unreadable {
                existing = nil
            }
            // An account-keyed item already written, or renewed since, wins.
            if existing == nil {
                var copy = legacy
                if copy.addedAt == nil {
                    copy.addedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
                }
                try target.save(copy, allowInteraction: allowInteraction)
                guard let written = try target.load(allowInteraction: allowInteraction),
                      written.matchesStoredCopy(copy)
                else {
                    // Never trust an unverified copy on the next attempt.
                    try? target.delete(allowInteraction: allowInteraction)
                    return .failed
                }
            }
            try legacyStore.delete(allowInteraction: allowInteraction)
            return .complete
        } catch ClaudeLoginStoreError.interactionRequired {
            return .keychainAccessRequired
        } catch {
            return .failed
        }
    }

    private func makeLogin(_ key: String) -> ClaudeCodeLogin {
        ClaudeCodeLogin(store: store.tokenStore(forAccountKey: key), transport: transport)
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
