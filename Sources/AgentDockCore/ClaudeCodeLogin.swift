import Foundation
import Security

public struct ClaudeLoginAccount: Equatable, Sendable {
    /// The profile email, or "Claude account".
    public var label: String
    public var subscriptionType: String?
    /// The name the user chose for this account, if any.
    public var customName: String?
    public var addedAt: Date?

    public init(
        label: String,
        subscriptionType: String?,
        customName: String? = nil,
        addedAt: Date? = nil
    ) {
        self.label = label
        self.subscriptionType = subscriptionType
        self.customName = customName
        self.addedAt = addedAt
    }

    /// The user's name for the account, or else its email.
    public var displayName: String {
        customName ?? label
    }
}

public enum ClaudeCodeLoginStatus: Equatable, Sendable {
    case unknown
    case keychainAccessRequired
    case signedOut(expired: Bool)
    case signedIn(ClaudeLoginAccount)

    public var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }
}

public enum ClaudeSignInProgress: Equatable, Sendable {
    case waitingForBrowser(URL)
    case exchangingCode
}

public enum ClaudeSignInError: Error, Equatable, Sendable {
    case cancelled
    case alreadyInProgress
    case listenerFailed
    case invalidCallback
    case invalidState
    case invalidCode
    case authorizationFailed(String)
    case requestFailed(Int)
    case connectionFailed
    case invalidResponse
    case profileUnavailable
    case keychain(ClaudeLoginStoreError)
    case accountNotFound
    /// The profile is bound to another Claude account, named by its email.
    case differentAccount(String)
    /// The profile's item cannot be read, so its account is unknown.
    case unreadableSignIn

    public var message: String {
        switch self {
        case .cancelled:
            "Sign-in was cancelled."
        case .alreadyInProgress:
            "A Claude sign-in is already in progress."
        case .listenerFailed:
            "AgentDock couldn't start its local sign-in listener. Try again."
        case .invalidCallback:
            "Claude's sign-in response was incomplete. Try again."
        case .invalidState:
            "The sign-in response didn't match this request. Try again."
        case .invalidCode:
            "That code isn't valid. Copy the whole code from claude.ai and try again."
        case let .authorizationFailed(reason):
            "Claude didn't complete the sign-in (\(reason)). Try again."
        case let .requestFailed(status):
            "Claude sign-in failed (HTTP \(status)). Try again."
        case .connectionFailed:
            "AgentDock couldn't reach Claude. Check the connection and try again."
        case .invalidResponse:
            "Claude returned an invalid sign-in response. Try again."
        case .profileUnavailable:
            "Claude didn't return your account. Try signing in again."
        case .keychain(.interactionRequired):
            "AgentDock couldn't update its Keychain item. Allow Keychain access and try again."
        case .keychain:
            "AgentDock couldn't update its Keychain item. Try again."
        case .accountNotFound:
            "This profile is no longer signed in to Claude."
        case let .differentAccount(label):
            "This profile is signed in to \(label). Sign out first to use a different Claude account."
        case .unreadableSignIn:
            "AgentDock couldn't read this profile's Claude sign-in, so it can't tell which account it belongs to. Sign out to remove it, then sign in again."
        }
    }
}

/// What the Claude Code limits path can use right now.
enum ClaudeLoginTokenOutcome: Equatable, Sendable {
    case tokens(ClaudeLoginTokens)
    case signedOut(expired: Bool)
    case keychainAccessRequired
    case renewalUnavailable
}

public enum ClaudeCodeUsageMessage {
    public static let notSignedIn = "Sign in to Claude to show this profile's Claude Code live limits."
    public static let signInExpired = "Your Claude sign-in expired. Sign in again."
    public static let keychainAccessRequired = "Click Refresh to let AgentDock read its Claude sign-in from the Keychain. Choose Always Allow to keep access."
    public static let renewalUnavailable = "AgentDock couldn't renew the Claude sign-in. It will try again on the next refresh."
    public static let identityMismatch = "The Claude sign-in no longer matches its account. Sign in again."
    public static let unreadableSignIn = "AgentDock couldn't read this Claude sign-in. Sign out to remove it, then sign in again."
    /// The sign-in lacks the `user:profile` scope that live usage needs.
    public static let missingProfileScope = "This login cannot read live usage. Sign in again to grant profile access."
}

/// One Claude account signed in to AgentDock for Claude Code limits. It owns
/// that account's stored tokens: one renewal at a time, written back to the
/// account's own item without prompting, and deleted when Claude refuses them.
/// A login stays with the account it signed in with: a sign-in of another
/// account is refused until the profile signs out. Tokens, the email, and the
/// account identifiers are never logged.
public actor ClaudeCodeLogin {
    private let store: any ClaudeLoginTokenStoring
    private let transport: any ClaudeHTTPTransport

    private var tokens: ClaudeLoginTokens?
    /// A missing item is cached; a load that needed Keychain access is not.
    private var loaded = false
    private var expiredNotice = false
    /// The item exists but is not a sign-in AgentDock can use.
    private var unreadable = false
    /// The last account seen, kept after a refusal so its card can say so.
    private var lastKnownAccount: ClaudeLoginAccount?
    private var lastKnownIdentity: ClaudeAccountIdentity?
    /// A renewal the Keychain refused to save; saving it is retried first.
    private var unsavedTokens: ClaudeLoginTokens?
    private var renewal: Task<ClaudeLoginTokenOutcome, Never>?
    /// Bumped by sign-in and sign-out; a renewal that started earlier is discarded.
    private var generation = 0

    public init(
        store: any ClaudeLoginTokenStoring,
        transport: any ClaudeHTTPTransport = URLSessionClaudeHTTPTransport()
    ) {
        self.store = store
        self.transport = transport
    }

    public func status(allowKeychainInteraction: Bool = false) -> ClaudeCodeLoginStatus {
        guard loadIfNeeded(allowInteraction: allowKeychainInteraction) else {
            return .keychainAccessRequired
        }
        if let tokens { return .signedIn(Self.account(for: tokens)) }
        return .signedOut(expired: expiredNotice)
    }

    /// The status plus the last account seen, for an account's card.
    func summary(allowKeychainInteraction: Bool = false) -> (status: ClaudeCodeLoginStatus, account: ClaudeLoginAccount?) {
        let current = self.status(allowKeychainInteraction: allowKeychainInteraction)
        return (current, lastKnownAccount)
    }

    /// The account identity last seen, used to key its rate-limit state.
    func knownIdentity() -> ClaudeAccountIdentity? {
        lastKnownIdentity
    }

    /// True once Claude refused the sign-in and its item was deleted.
    func showsExpiryNotice() -> Bool {
        tokens == nil && expiredNotice
    }

    /// True when the item exists but is not a sign-in AgentDock can use.
    func isUnreadable() -> Bool {
        tokens == nil && unreadable
    }

    // MARK: - Sign in, rename, and sign out

    /// The account this login is bound to, if any.
    private enum Binding {
        /// No sign-in: any account may sign in.
        case none
        /// Bound to this account: its stored sign-in, or, after Claude
        /// refused the sign-in, the account it had until Sign Out or relaunch.
        case account(ClaudeAccountIdentity, ClaudeLoginAccount)
        /// An item exists but cannot be read, so its account is unknown.
        case unreadable
    }

    private func binding() throws(ClaudeSignInError) -> Binding {
        guard loadIfNeeded(allowInteraction: true) else {
            throw ClaudeSignInError.keychain(.interactionRequired)
        }
        if let tokens { return .account(tokens.identity, Self.account(for: tokens)) }
        if unreadable { return .unreadable }
        if expiredNotice, let identity = lastKnownIdentity, let account = lastKnownAccount {
            return .account(identity, account)
        }
        return .none
    }

    /// Throws when no sign-in can complete here before one is started: the
    /// item cannot be read, or reading it needs Keychain access that was refused.
    func checkCanSignIn() throws(ClaudeSignInError) {
        if case .unreadable = try binding() {
            throw ClaudeSignInError.unreadableSignIn
        }
    }

    /// Saves a fresh sign-in. A profile stays with one Claude account: when it
    /// is bound to an account, only that account (by account UUID) may sign
    /// in again, which replaces the tokens and keeps the user's name and the
    /// added date. Another account is refused and nothing is written.
    func adopt(_ signedIn: ClaudeLoginTokens) throws(ClaudeSignInError) -> ClaudeLoginAccount {
        var replacement = signedIn
        switch try binding() {
        case .none:
            break
        case .unreadable:
            throw ClaudeSignInError.unreadableSignIn
        case let .account(identity, account):
            guard identity.accountUUID.caseInsensitiveCompare(replacement.accountUUID) == .orderedSame else {
                throw ClaudeSignInError.differentAccount(account.label)
            }
            replacement.customName = account.customName
            replacement.addedAt = account.addedAt ?? replacement.addedAt
        }
        do {
            try store.save(replacement, allowInteraction: true)
        } catch {
            throw ClaudeSignInError.keychain(Self.storeError(error))
        }
        generation += 1
        renewal?.cancel()
        renewal = nil
        remember(replacement)
        unsavedTokens = nil
        loaded = true
        expiredNotice = false
        unreadable = false
        return Self.account(for: replacement)
    }

    /// Sets or clears the user's name for this account and saves it.
    func rename(to name: String?) throws(ClaudeSignInError) -> ClaudeLoginAccount {
        guard loadIfNeeded(allowInteraction: true) else {
            throw ClaudeSignInError.keychain(.interactionRequired)
        }
        guard var updated = tokens else { throw ClaudeSignInError.accountNotFound }
        updated.customName = ClaudeLoginTokens.normalizedCustomName(name)
        do {
            try store.save(updated, allowInteraction: true)
        } catch {
            throw ClaudeSignInError.keychain(Self.storeError(error))
        }
        remember(updated)
        unsavedTokens = nil
        return Self.account(for: updated)
    }

    /// Deletes only this account's item.
    public func signOut() async throws(ClaudeSignInError) {
        generation += 1
        renewal?.cancel()
        renewal = nil
        do {
            try store.delete(allowInteraction: true)
        } catch {
            throw ClaudeSignInError.keychain(Self.storeError(error))
        }
        tokens = nil
        unsavedTokens = nil
        loaded = true
        expiredNotice = false
        unreadable = false
    }

    // MARK: - Tokens for live limits

    func usableTokens(
        allowKeychainInteraction: Bool,
        now: Date = Date()
    ) async -> ClaudeLoginTokenOutcome {
        if let pending = unsavedTokens, (try? store.save(pending, allowInteraction: false)) != nil {
            unsavedTokens = nil
        }
        guard loadIfNeeded(allowInteraction: allowKeychainInteraction) else {
            return .keychainAccessRequired
        }
        guard let current = tokens else { return .signedOut(expired: expiredNotice) }
        guard current.needsRenewal(at: now) else { return .tokens(current) }

        switch await renew(now: now) {
        case let .tokens(renewed):
            return .tokens(renewed)
        case let .signedOut(expired):
            return .signedOut(expired: expired)
        case .keychainAccessRequired:
            return .keychainAccessRequired
        case .renewalUnavailable:
            // An outage keeps a token that has not expired yet.
            if let tokens, let expiresAt = tokens.expiresAt, expiresAt > now {
                return .tokens(tokens)
            }
            return .renewalUnavailable
        }
    }

    /// Renews after the provider rejected `rejectedAccessToken` with a 401.
    func renewAfterUnauthorized(rejectedAccessToken: String) async -> ClaudeLoginTokenOutcome {
        guard let current = tokens else { return .signedOut(expired: expiredNotice) }
        // Another path already replaced the rejected token.
        guard current.accessToken == rejectedAccessToken else { return .tokens(current) }
        return await renew(now: Date())
    }

    func markSignedOutAfterRepeatedUnauthorized() {
        signOutAfterRejection()
    }

    // MARK: - Renewal

    private func renew(now: Date) async -> ClaudeLoginTokenOutcome {
        if let renewal { return await renewal.value }
        let expected = generation
        // Assigned before the first suspension so concurrent callers share it.
        let task = Task { await self.performRenewal(generation: expected, now: now) }
        renewal = task
        let outcome = await task.value
        if renewal == task { renewal = nil }
        return outcome
    }

    private func performRenewal(generation expected: Int, now: Date) async -> ClaudeLoginTokenOutcome {
        guard let current = tokens else { return currentOutcome() }
        guard let refreshToken = current.refreshToken else {
            signOutAfterRejection()
            return .signedOut(expired: true)
        }
        let result = await requestRenewal(refreshToken: refreshToken)
        // A sign-in or sign-out while the request ran wins over its answer.
        guard generation == expected, let latest = tokens else { return currentOutcome() }

        switch result {
        case let .granted(response):
            var renewed = latest
            renewed.accessToken = response.accessToken
            if let refreshToken = Self.nonEmpty(response.refreshToken) {
                renewed.refreshToken = refreshToken
            }
            renewed.expiresAt = Self.expiry(response.expiresIn, now: now)
            let scopes = Self.scopeList(response.scope)
            if !scopes.isEmpty { renewed.scopes = scopes }
            remember(renewed)
            do {
                try store.save(renewed, allowInteraction: false)
                unsavedTokens = nil
            } catch {
                unsavedTokens = renewed
            }
            return .tokens(renewed)
        case .refused:
            signOutAfterRejection()
            return .signedOut(expired: true)
        case .unavailable:
            return .renewalUnavailable
        }
    }

    /// Asks for both scopes; a sign-in Claude won't widen renews with profile only.
    private func requestRenewal(refreshToken: String) async -> ClaudeRenewalResult {
        do {
            var (data, response) = try await transport.send(
                ClaudeOAuth.refreshRequest(refreshToken: refreshToken, scope: ClaudeOAuth.scopes),
                maximumResponseBytes: ClaudeOAuth.maximumResponseBytes
            )
            if response.statusCode == 400, ClaudeOAuth.errorCode(data) == "invalid_scope" {
                (data, response) = try await transport.send(
                    ClaudeOAuth.refreshRequest(
                        refreshToken: refreshToken,
                        scope: ClaudeOAuth.profileOnlyScopes
                    ),
                    maximumResponseBytes: ClaudeOAuth.maximumResponseBytes
                )
            }
            return ClaudeOAuth.classifyRenewal(data, response)
        } catch {
            return .unavailable
        }
    }

    /// The tokens are useless now; deleting this account's item stops repeat requests.
    private func signOutAfterRejection() {
        generation += 1
        renewal?.cancel()
        renewal = nil
        try? store.delete(allowInteraction: false)
        tokens = nil
        unsavedTokens = nil
        loaded = true
        expiredNotice = true
        unreadable = false
    }

    private func currentOutcome() -> ClaudeLoginTokenOutcome {
        if let tokens { return .tokens(tokens) }
        return .signedOut(expired: expiredNotice)
    }

    private func remember(_ current: ClaudeLoginTokens) {
        tokens = current
        lastKnownAccount = Self.account(for: current)
        lastKnownIdentity = current.identity
    }

    private func loadIfNeeded(allowInteraction: Bool) -> Bool {
        guard !loaded else { return true }
        do {
            if let stored = try store.load(allowInteraction: allowInteraction) {
                remember(stored)
            } else {
                tokens = nil
            }
            loaded = true
            unreadable = false
            return true
        } catch ClaudeLoginStoreError.unreadable {
            // Not a sign-in AgentDock can use. Its account is unknown, so no
            // sign-in may replace it; Sign Out removes it.
            tokens = nil
            loaded = true
            unreadable = true
            return true
        } catch {
            return false
        }
    }

    // MARK: - Helpers

    static func checkCancellation() throws(ClaudeSignInError) {
        if Task.isCancelled { throw ClaudeSignInError.cancelled }
    }

    static func account(for tokens: ClaudeLoginTokens) -> ClaudeLoginAccount {
        ClaudeLoginAccount(
            label: tokens.accountLabel,
            subscriptionType: tokens.subscriptionType,
            customName: tokens.customName,
            addedAt: tokens.addedAt
        )
    }

    static func scopeList(_ value: String?) -> [String] {
        (value ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func expiry(_ seconds: Double?, now: Date) -> Date? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return now.addingTimeInterval(seconds)
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    static func storeError(_ error: any Error) -> ClaudeLoginStoreError {
        (error as? ClaudeLoginStoreError) ?? .failed(errSecInternalComponent)
    }
}
