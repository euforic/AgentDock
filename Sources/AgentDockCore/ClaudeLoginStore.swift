import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// AgentDock's own Claude sign-in: tokens plus the account they belong to.
public struct ClaudeLoginTokens: Codable, Equatable, Sendable {
    public static let refreshMargin: TimeInterval = 5 * 60
    /// The longest name a user can give an account.
    public static let maximumCustomNameLength = 64

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
    /// The name the user chose for this account; nil shows `accountLabel`.
    /// Absent from sign-ins saved before multiple accounts were supported.
    public var customName: String?
    /// When the account was first added to AgentDock. Encoded as seconds since 1970.
    public var addedAt: Date?

    public init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?,
        scopes: [String],
        accountUUID: String,
        organizationUUID: String,
        accountLabel: String,
        subscriptionType: String?,
        customName: String? = nil,
        addedAt: Date? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.accountUUID = accountUUID
        self.organizationUUID = organizationUUID
        self.accountLabel = accountLabel
        self.subscriptionType = subscriptionType
        self.customName = customName
        self.addedAt = addedAt
    }

    /// Renew within five minutes of expiry, when a refresh token exists.
    public func needsRenewal(at now: Date) -> Bool {
        guard refreshToken != nil, let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(Self.refreshMargin)
    }

    /// The stable key of this account and organization; names its Keychain item.
    public var accountKey: String {
        ClaudeLoginAccountKey.make(accountUUID: accountUUID, organizationUUID: organizationUUID)
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

    /// The same sign-in after a Keychain round trip. Dates are compared to the
    /// millisecond because seconds-since-1970 encoding can move the last bit.
    func matchesStoredCopy(_ other: ClaudeLoginTokens) -> Bool {
        func same(_ lhs: Date?, _ rhs: Date?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil): true
            case let (lhs?, rhs?): abs(lhs.timeIntervalSince(rhs)) < 0.001
            default: false
            }
        }
        return accessToken == other.accessToken
            && refreshToken == other.refreshToken
            && scopes == other.scopes
            && accountUUID == other.accountUUID
            && organizationUUID == other.organizationUUID
            && accountLabel == other.accountLabel
            && subscriptionType == other.subscriptionType
            && customName == other.customName
            && same(expiresAt, other.expiresAt)
            && same(addedAt, other.addedAt)
    }

    /// Trims a user-chosen name; an empty name clears it.
    static func normalizedCustomName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return String(trimmed.prefix(maximumCustomNameLength))
    }
}

/// The stable, non-reversible key of one Claude account and organization: the
/// first 16 bytes of a SHA-256 digest, as 32 lowercase hex characters. It names
/// the account's Keychain item and identifies it in the app; it never contains
/// the raw identifiers.
public enum ClaudeLoginAccountKey {
    public static let length = 32

    public static func make(accountUUID: String, organizationUUID: String) -> String {
        let material = "agentdock.claude-login|\(accountUUID.lowercased())|\(organizationUUID.lowercased())"
        return SHA256.hash(data: Data(material.utf8))
            .prefix(length / 2)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func isValid(_ key: String) -> Bool {
        key.utf8.count == length && key.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }
}

public enum ClaudeLoginStoreError: Error, Equatable, Sendable {
    /// The Keychain would have to prompt, and prompting was not allowed.
    case interactionRequired
    /// The item exists but is too large or not a sign-in AgentDock wrote.
    case unreadable
    case failed(OSStatus)
}

/// One stored sign-in.
public protocol ClaudeLoginTokenStoring: Sendable {
    /// Returns nil when no sign-in is stored.
    func load(allowInteraction: Bool) throws -> ClaudeLoginTokens?
    func save(_ tokens: ClaudeLoginTokens, allowInteraction: Bool) throws
    /// Deleting a missing item succeeds.
    func delete(allowInteraction: Bool) throws
}

/// Every stored sign-in, one item per account key, plus the single item
/// written before multiple accounts were supported.
public protocol ClaudeLoginAccountStoring: Sendable {
    /// The keys of stored accounts, sorted. The legacy item is never listed.
    func accountKeys(allowInteraction: Bool) throws -> [String]
    /// The item for one account. Loads and saves of another account fail.
    func tokenStore(forAccountKey accountKey: String) -> any ClaudeLoginTokenStoring
    /// The pre-multi-account item, read only to migrate it.
    var legacyTokenStore: any ClaudeLoginTokenStoring { get }
}

/// One generic password in the legacy file-based login Keychain. It is not
/// synchronizable, and calls made without interaction never prompt.
///
/// `@unchecked Sendable`: the only non-Sendable member is an immutable
/// `SecKeychain` reference, used only by tests to target a temporary keychain.
public struct ClaudeLoginKeychainStore: ClaudeLoginTokenStoring, @unchecked Sendable {
    public static let service = "dev.euforic.agentdock.claude-login"
    /// The single item written before multiple accounts were supported.
    public static let account = "claude-code"
    /// Each account's item is named `claude-code:<account key>`.
    public static let accountPrefix = "claude-code:"
    static let label = "AgentDock Claude Sign-In"
    static let maximumBytes = 64 * 1_024

    private let keychain: SecKeychain?
    private let service: String
    private let account: String
    /// Set for an account's item: what it loads and saves must be that account.
    private let accountKey: String?

    /// The legacy single item in the user's default keychain.
    public init() {
        self.init(keychain: nil)
    }

    init(
        keychain: SecKeychain?,
        service: String = ClaudeLoginKeychainStore.service,
        accountKey: String? = nil
    ) {
        self.keychain = keychain
        self.service = service
        self.accountKey = accountKey
        account = accountKey.map { Self.accountPrefix + $0 } ?? Self.account
    }

    public func load(allowInteraction: Bool) throws -> ClaudeLoginTokens? {
        var query = baseQuery(searchingKeychain: true)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let request = Self.withInteractionPolicy(query, allowInteraction: allowInteraction)
        let (status, result) = try Self.perform(allowInteraction) { () -> (OSStatus, CFTypeRef?) in
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
              tokens.isWellFormed,
              accountKey == nil || tokens.accountKey == accountKey
        else { throw ClaudeLoginStoreError.unreadable }
        return tokens
    }

    public func save(_ tokens: ClaudeLoginTokens, allowInteraction: Bool) throws {
        if let accountKey, tokens.accountKey != accountKey {
            throw ClaudeLoginStoreError.unreadable
        }
        guard let data = try? Self.encoder.encode(tokens), data.count <= Self.maximumBytes else {
            throw ClaudeLoginStoreError.unreadable
        }
        let match = Self.withInteractionPolicy(
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
        let insert = Self.withInteractionPolicy(addition, allowInteraction: allowInteraction)

        let status = try Self.perform(allowInteraction) { () -> OSStatus in
            let updated = SecItemUpdate(match as CFDictionary, changes as CFDictionary)
            guard updated == errSecItemNotFound else { return updated }
            return SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Self.error(for: status) }
    }

    public func delete(allowInteraction: Bool) throws {
        let query = Self.withInteractionPolicy(
            baseQuery(searchingKeychain: true),
            allowInteraction: allowInteraction
        )
        let status = try Self.perform(allowInteraction) { () -> OSStatus in
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
            kSecAttrAccount as String: account
        ]
        if searchingKeychain, let keychain {
            query[kSecMatchSearchList as String] = [keychain]
        }
        return query
    }

    static func withInteractionPolicy(_ query: [String: Any], allowInteraction: Bool) -> [String: Any] {
        guard !allowInteraction else { return query }
        var query = query
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    /// Runs a Sec call with the process-wide legacy interaction flag set, so
    /// background reads and writes never show a Keychain prompt.
    static func perform<T>(_ allowInteraction: Bool, _ operation: () -> T) throws -> T {
        let result: T? = ClaudeKeychainAccess.withInteractionAllowed(allowInteraction) {
            Optional(operation())
        }
        guard let value = result else {
            throw ClaudeLoginStoreError.failed(errSecInternalComponent)
        }
        return value
    }

    static func error(for status: OSStatus) -> ClaudeLoginStoreError {
        switch status {
        case errSecInteractionNotAllowed, errSecAuthFailed: .interactionRequired
        default: .failed(status)
        }
    }
}

/// Every AgentDock Claude sign-in in the login Keychain: one generic password
/// per account under the same service, named `claude-code:<account key>`.
/// Listing reads only item attributes, never another service's items.
///
/// `@unchecked Sendable`: the only non-Sendable member is an immutable
/// `SecKeychain` reference, used only by tests to target a temporary keychain.
public struct ClaudeLoginKeychainAccounts: ClaudeLoginAccountStoring, @unchecked Sendable {
    /// More items than this under AgentDock's service are not listed.
    static let maximumAccounts = 64

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

    public func accountKeys(allowInteraction: Bool) throws -> [String] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        let request = ClaudeLoginKeychainStore.withInteractionPolicy(query, allowInteraction: allowInteraction)
        let (status, result) = try ClaudeLoginKeychainStore.perform(allowInteraction) {
            () -> (OSStatus, CFTypeRef?) in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            return (status, result)
        }
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            return []
        default:
            throw ClaudeLoginKeychainStore.error(for: status)
        }
        let items = (result as? [[String: Any]]) ?? []
        let keys = items.compactMap { item -> String? in
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix(ClaudeLoginKeychainStore.accountPrefix)
            else { return nil }
            let key = String(account.dropFirst(ClaudeLoginKeychainStore.accountPrefix.count))
            return ClaudeLoginAccountKey.isValid(key) ? key : nil
        }
        return Array(Set(keys).sorted().prefix(Self.maximumAccounts))
    }

    public func tokenStore(forAccountKey accountKey: String) -> any ClaudeLoginTokenStoring {
        ClaudeLoginKeychainStore(keychain: keychain, service: service, accountKey: accountKey)
    }

    public var legacyTokenStore: any ClaudeLoginTokenStoring {
        ClaudeLoginKeychainStore(keychain: keychain, service: service)
    }
}
