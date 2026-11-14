import Foundation
import Security

public struct ClaudeLoginAccount: Equatable, Sendable {
    public var label: String
    public var subscriptionType: String?

    public init(label: String, subscriptionType: String?) {
        self.label = label
        self.subscriptionType = subscriptionType
    }
}

public enum ClaudeCodeLoginStatus: Equatable, Sendable {
    case unknown
    case keychainAccessRequired
    case signedOut(expired: Bool)
    case signedIn(ClaudeLoginAccount)
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
    public static let notSignedIn = "Sign in to Claude to show Claude Code live limits."
    public static let signInExpired = "Your Claude sign-in expired. Sign in again."
    public static let keychainAccessRequired = "Click Refresh to let AgentDock read its Claude sign-in from the Keychain. Choose Always Allow to keep access."
    public static let renewalUnavailable = "AgentDock couldn't renew the Claude sign-in. It will try again on the next refresh."
    public static let identityMismatch = "The Claude sign-in no longer matches its account. Sign in again."
}

/// AgentDock's own Claude sign-in for Claude Code limits. It owns the stored
/// tokens: one renewal at a time, written back without prompting, and deleted
/// when Claude refuses them. Tokens, codes, the verifier, the email, and the
/// account identifiers are never logged.
public actor ClaudeCodeLogin {
    private let store: any ClaudeLoginTokenStoring
    private let transport: any ClaudeHTTPTransport

    private var tokens: ClaudeLoginTokens?
    /// A missing item is cached; a load that needed Keychain access is not.
    private var loaded = false
    private var expiredNotice = false
    /// A renewal the Keychain refused to save; saving it is retried first.
    private var unsavedTokens: ClaudeLoginTokens?
    private var renewal: Task<ClaudeLoginTokenOutcome, Never>?
    /// Bumped by sign-in and sign-out; a renewal that started earlier is discarded.
    private var generation = 0
    private var signInInProgress = false

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

    // MARK: - Sign in and out

    /// Runs one PKCE sign-in through claude.ai. The code arrives at the loopback
    /// listener or as the first value of `pastedCodes`, whichever comes first.
    public func signIn(
        progress: @escaping @Sendable (ClaudeSignInProgress) async -> Void,
        pastedCodes: AsyncStream<String>
    ) async throws(ClaudeSignInError) -> ClaudeLoginAccount {
        guard !signInInProgress else { throw ClaudeSignInError.alreadyInProgress }
        signInInProgress = true
        defer { signInInProgress = false }

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
        try Self.checkCancellation()

        await progress(.exchangingCode)
        let token = try await exchange(
            code: code,
            state: state,
            redirectURI: redirectURI,
            verifier: pkce.verifier
        )
        let profile = try await readProfile(accessToken: token.accessToken)
        try Self.checkCancellation()

        let grantedScopes = Self.scopeList(token.scope)
        let signedIn = ClaudeLoginTokens(
            accessToken: token.accessToken,
            refreshToken: Self.nonEmpty(token.refreshToken),
            expiresAt: Self.expiry(token.expiresIn, now: Date()),
            scopes: grantedScopes.isEmpty ? Self.scopeList(ClaudeOAuth.scopes) : grantedScopes,
            accountUUID: profile.identity.accountUUID,
            organizationUUID: profile.identity.organizationUUID,
            accountLabel: profile.label,
            subscriptionType: profile.subscriptionType
        )
        do {
            try store.save(signedIn, allowInteraction: true)
        } catch {
            throw ClaudeSignInError.keychain(Self.storeError(error))
        }

        generation += 1
        renewal?.cancel()
        renewal = nil
        tokens = signedIn
        unsavedTokens = nil
        loaded = true
        expiredNotice = false
        return Self.account(for: signedIn)
    }

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
            tokens = renewed
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

    /// The tokens are useless now; deleting them stops repeat requests.
    private func signOutAfterRejection() {
        generation += 1
        renewal?.cancel()
        renewal = nil
        try? store.delete(allowInteraction: false)
        tokens = nil
        unsavedTokens = nil
        loaded = true
        expiredNotice = true
    }

    private func currentOutcome() -> ClaudeLoginTokenOutcome {
        if let tokens { return .tokens(tokens) }
        return .signedOut(expired: expiredNotice)
    }

    private func loadIfNeeded(allowInteraction: Bool) -> Bool {
        guard !loaded else { return true }
        do {
            tokens = try store.load(allowInteraction: allowInteraction)
            loaded = true
            return true
        } catch ClaudeLoginStoreError.unreadable {
            // Not a sign-in AgentDock can use; signing in again replaces it.
            tokens = nil
            loaded = true
            return true
        } catch {
            return false
        }
    }

    // MARK: - Sign-in requests

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
              Self.nonEmpty(token.accessToken) != nil
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
        let label = Self.nonEmpty(profile.account.email)
            ?? Self.nonEmpty(profile.email)
            ?? "Claude account"
        let plan = Self.nonEmpty(organization.organizationType).map { type in
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

    // MARK: - Helpers

    private static func checkCancellation() throws(ClaudeSignInError) {
        if Task.isCancelled { throw ClaudeSignInError.cancelled }
    }

    private static func account(for tokens: ClaudeLoginTokens) -> ClaudeLoginAccount {
        ClaudeLoginAccount(label: tokens.accountLabel, subscriptionType: tokens.subscriptionType)
    }

    private static func scopeList(_ value: String?) -> [String] {
        (value ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func expiry(_ seconds: Double?, now: Date) -> Date? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return now.addingTimeInterval(seconds)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func storeError(_ error: any Error) -> ClaudeLoginStoreError {
        (error as? ClaudeLoginStoreError) ?? .failed(errSecInternalComponent)
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
