import Foundation
import LocalAuthentication
import Security

/// AgentDock's own Claude sign-in: tokens plus the account they belong to.
public struct ClaudeLoginTokens: Codable, Equatable, Sendable {
    public static let refreshMargin: TimeInterval = 5 * 60

    public var version = 1
    public var accessToken: String
    public var refreshToken: String?
    /// Encoded as seconds since 1970.
    public var expiresAt: Date?
    public var scopes: [String]
    /// Lowercased and validated with `ClaudeAccountIdentity.desktop`.
    public var accountUUID: String
    public var organizationUUID: String
    /// The profile email, or "Claude account".
    public var accountLabel: String
    /// `organization_type` without its `claude_` prefix, for example "max".
    public var subscriptionType: String?

    public init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?,
        scopes: [String],
        accountUUID: String,
        organizationUUID: String,
        accountLabel: String,
        subscriptionType: String?
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.accountUUID = accountUUID
        self.organizationUUID = organizationUUID
        self.accountLabel = accountLabel
        self.subscriptionType = subscriptionType
    }

    /// Renew within five minutes of expiry, when a refresh token exists.
    public func needsRenewal(at now: Date) -> Bool {
        guard refreshToken != nil, let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(Self.refreshMargin)
    }

    var identity: ClaudeAccountIdentity {
        ClaudeAccountIdentity(accountUUID: accountUUID, organizationUUID: organizationUUID)
    }

    var usageCredential: ClaudeUsageCredential {
        ClaudeUsageCredential(
            accessToken: accessToken,
            expiresAt: expiresAt.map { $0.timeIntervalSince1970 * 1_000 },
            subscriptionType: subscriptionType,
            scopes: Set(scopes),
            identity: identity
        )
    }

    /// Stored values must still name a valid account and carry a token.
    var isWellFormed: Bool {
        !accessToken.isEmpty
            && ClaudeAccountIdentity.desktop(
                accountUUID: accountUUID,
                organizationUUID: organizationUUID
            ) == identity
    }
}

public enum ClaudeLoginStoreError: Error, Equatable, Sendable {
    /// The Keychain would have to prompt, and prompting was not allowed.
    case interactionRequired
    /// The item exists but is too large or not a sign-in AgentDock wrote.
    case unreadable
    case failed(OSStatus)
}

public protocol ClaudeLoginTokenStoring: Sendable {
    /// Returns nil when no sign-in is stored.
    func load(allowInteraction: Bool) throws -> ClaudeLoginTokens?
    func save(_ tokens: ClaudeLoginTokens, allowInteraction: Bool) throws
    /// Deleting a missing item succeeds.
    func delete(allowInteraction: Bool) throws
}

/// One generic password in the legacy file-based login Keychain. It is not
/// synchronizable, and calls made without interaction never prompt.
///
/// `@unchecked Sendable`: the only non-Sendable member is an immutable
/// `SecKeychain` reference, used only by tests to target a temporary keychain.
public struct ClaudeLoginKeychainStore: ClaudeLoginTokenStoring, @unchecked Sendable {
    public static let service = "dev.euforic.agentdock.claude-login"
    public static let account = "claude-code"
    static let label = "AgentDock Claude Sign-In"
    static let maximumBytes = 64 * 1_024

    private let keychain: SecKeychain?
    private let service: String

    /// The user's default keychain.
    public init() {
        self.init(keychain: nil)
    }

    init(keychain: SecKeychain?, service: String = ClaudeLoginKeychainStore.service) {
        self.keychain = keychain
        self.service = service
    }

    public func load(allowInteraction: Bool) throws -> ClaudeLoginTokens? {
        var query = baseQuery(searchingKeychain: true)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let request = withInteractionPolicy(query, allowInteraction: allowInteraction)
        let (status, result) = try perform(allowInteraction) { () -> (OSStatus, CFTypeRef?) in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            return (status, result)
        }
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            return nil
        default:
            throw Self.error(for: status)
        }
        guard let data = result as? Data,
              data.count <= Self.maximumBytes,
              let tokens = try? Self.decoder.decode(ClaudeLoginTokens.self, from: data),
              tokens.isWellFormed
        else { throw ClaudeLoginStoreError.unreadable }
        return tokens
    }

    public func save(_ tokens: ClaudeLoginTokens, allowInteraction: Bool) throws {
        guard let data = try? Self.encoder.encode(tokens), data.count <= Self.maximumBytes else {
            throw ClaudeLoginStoreError.unreadable
        }
        let match = withInteractionPolicy(
            baseQuery(searchingKeychain: true),
            allowInteraction: allowInteraction
        )
        let changes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: Self.label
        ]
        var addition = baseQuery(searchingKeychain: false)
        if let keychain { addition[kSecUseKeychain as String] = keychain }
        addition[kSecValueData as String] = data
        addition[kSecAttrLabel as String] = Self.label
        let insert = withInteractionPolicy(addition, allowInteraction: allowInteraction)

        let status = try perform(allowInteraction) { () -> OSStatus in
            let updated = SecItemUpdate(match as CFDictionary, changes as CFDictionary)
            guard updated == errSecItemNotFound else { return updated }
            return SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Self.error(for: status) }
    }

    public func delete(allowInteraction: Bool) throws {
        let query = withInteractionPolicy(
            baseQuery(searchingKeychain: true),
            allowInteraction: allowInteraction
        )
        let status = try perform(allowInteraction) { () -> OSStatus in
            SecItemDelete(query as CFDictionary)
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.error(for: status)
        }
    }

    // MARK: - Helpers

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    private func baseQuery(searchingKeychain: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account
        ]
        if searchingKeychain, let keychain {
            query[kSecMatchSearchList as String] = [keychain]
        }
        return query
    }

    private func withInteractionPolicy(_ query: [String: Any], allowInteraction: Bool) -> [String: Any] {
        guard !allowInteraction else { return query }
        var query = query
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    /// Runs a Sec call with the process-wide legacy interaction flag set, so
    /// background reads and writes never show a Keychain prompt.
    private func perform<T>(_ allowInteraction: Bool, _ operation: () -> T) throws -> T {
        let result: T? = ClaudeKeychainAccess.withInteractionAllowed(allowInteraction) {
            Optional(operation())
        }
        guard let value = result else {
            throw ClaudeLoginStoreError.failed(errSecInternalComponent)
        }
        return value
    }

    private static func error(for status: OSStatus) -> ClaudeLoginStoreError {
        switch status {
        case errSecInteractionNotAllowed, errSecAuthFailed: .interactionRequired
        default: .failed(status)
        }
    }
}
