import Foundation

/// Where the Claude Code CLI keeps its login and account metadata.
public struct ClaudeCodeLocation: Equatable, Sendable {
    public static let defaultKeychainService = "Claude Code-credentials"

    /// `$CLAUDE_CONFIG_DIR` or `~/.claude`.
    public var homeURL: URL
    /// `$CLAUDE_CONFIG_DIR/.claude.json` or `~/.claude.json`.
    public var globalConfigURL: URL
    /// The Keychain service to query; nil reads only the credentials file.
    public var keychainService: String?

    public init(homeURL: URL, globalConfigURL: URL, keychainService: String?) {
        self.homeURL = homeURL
        self.globalConfigURL = globalConfigURL
        self.keychainService = keychainService
    }

    public static func resolve(environment: [String: String], homeDirectory: URL) -> ClaudeCodeLocation {
        // Only a non-empty absolute directory is honored; relative values are ignored.
        if let configured = environment["CLAUDE_CONFIG_DIR"], configured.hasPrefix("/") {
            let home = URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
            return ClaudeCodeLocation(
                homeURL: home,
                globalConfigURL: home.appendingPathComponent(".claude.json", isDirectory: false),
                keychainService: defaultKeychainService
            )
        }
        return ClaudeCodeLocation(
            homeURL: homeDirectory.appendingPathComponent(".claude", isDirectory: true),
            globalConfigURL: homeDirectory.appendingPathComponent(".claude.json", isDirectory: false),
            keychainService: defaultKeychainService
        )
    }
}

enum ClaudeCodeCredentialLookup: Equatable, Sendable {
    case usable(ClaudeUsageCredential)
    case notSignedIn
    case keychainAccessRequired
    case expired(subscriptionType: String?)
    case missingProfileScope(subscriptionType: String?)

    /// Failure precedence when neither credential store is usable.
    fileprivate var failurePriority: Int {
        switch self {
        case .usable: 4
        case .keychainAccessRequired: 3
        case .expired: 2
        case .missingProfileScope: 1
        case .notSignedIn: 0
        }
    }
}

enum ClaudeCodeUsageMessage {
    static let notSignedIn = "Claude Code live limits are unavailable. Sign in with Claude Code, then refresh."
    static let keychainAccessRequired = "Click Refresh to let AgentDock read Claude Code's login from the Keychain. Choose Always Allow to keep access."
    static let expired = "Claude Code's login has expired. Run Claude Code to refresh its login, then refresh."
    static let missingProfileScope = "This Claude Code login cannot read live usage. Run /login in Claude Code, then refresh."
    static let identityMismatch = "The Claude Code login no longer matches its saved account. Run Claude Code to refresh its login, then refresh."
}

extension ClaudeCredentialReader {
    static let claudeCodeMaximumKeychainBytes = 1 * 1_024 * 1_024

    /// Reads Claude Code's own login: the Keychain item first, then
    /// `.credentials.json`. Tokens are never refreshed, copied, or persisted.
    mutating func readClaudeCodeCredential(
        location: ClaudeCodeLocation,
        allowKeychainInteraction: Bool,
        now: Date = Date()
    ) -> ClaudeCodeCredentialLookup {
        var outcome = ClaudeCodeCredentialLookup.notSignedIn

        if let service = location.keychainService {
            switch keychainLookup(
                service: service,
                account: nil,
                allowKeychainInteraction: allowKeychainInteraction
            ) {
            case let .found(value):
                let data = Data(value.utf8)
                if data.count <= Self.claudeCodeMaximumKeychainBytes {
                    let decoded = Self.decodeClaudeCode(data, now: now)
                    if case let .usable(credential) = decoded {
                        return .usable(attachingClaudeCodeIdentity(
                            to: credential,
                            globalConfigURL: location.globalConfigURL
                        ))
                    }
                    outcome = Self.preferredClaudeCodeFailure(outcome, decoded)
                }
            case .interactionRequired:
                outcome = Self.preferredClaudeCodeFailure(outcome, .keychainAccessRequired)
            case .notFound, .failed:
                break
            }
        }

        // O_NOFOLLOW: a symlinked credentials file is treated as absent.
        if let data = try? BoundedFileReader.data(
            at: location.homeURL.appendingPathComponent(".credentials.json", isDirectory: false),
            maximumBytes: LocalControlFileLimit.providerCredentialState
        ) {
            let decoded = Self.decodeClaudeCode(data, now: now)
            if case let .usable(credential) = decoded {
                return .usable(attachingClaudeCodeIdentity(
                    to: credential,
                    globalConfigURL: location.globalConfigURL
                ))
            }
            outcome = Self.preferredClaudeCodeFailure(outcome, decoded)
        }
        return outcome
    }

    /// The account and organization Claude Code recorded for its login, or nil
    /// when the file is unreadable, too large, or lacks two valid UUIDs.
    func claudeCodeIdentity(globalConfigURL: URL) -> ClaudeAccountIdentity? {
        guard let data = try? BoundedFileReader.data(
                  at: globalConfigURL,
                  maximumBytes: LocalControlFileLimit.claudeCodeGlobalConfig
              ),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any],
              let organization = account["organizationUuid"] as? String
        else { return nil }
        return ClaudeAccountIdentity.desktop(
            accountUUID: account["accountUuid"] as? String,
            organizationUUID: organization
        )
    }

    /// Parses `claudeAiOauth`. Refresh tokens and other fields are never read.
    static func decodeClaudeCode(_ data: Data, now: Date) -> ClaudeCodeCredentialLookup {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let accessToken = claudeCodeNonempty(oauth["accessToken"] as? String)
        else { return .notSignedIn }
        let subscriptionType = claudeCodeNonempty(oauth["subscriptionType"] as? String)

        var expiresAt: Double?
        if let rawExpiry = oauth["expiresAt"], !(rawExpiry is NSNull) {
            guard let value = claudeCodeStrictNumber(rawExpiry) else { return .notSignedIn }
            expiresAt = value
        }
        let scopes = oauth["scopes"] as? [String] ?? []
        guard scopes.contains("user:profile") else {
            return .missingProfileScope(subscriptionType: subscriptionType)
        }
        let earliestUsableExpiry = (now.timeIntervalSince1970
            + ClaudeUsageRefreshPolicy.credentialExpiryMargin) * 1_000
        if let expiresAt, expiresAt <= earliestUsableExpiry {
            return .expired(subscriptionType: subscriptionType)
        }
        return .usable(ClaudeUsageCredential(
            accessToken: accessToken,
            expiresAt: expiresAt,
            subscriptionType: subscriptionType,
            scopes: Set(scopes),
            identity: nil
        ))
    }

    /// Identity is reread only when the token changes.
    private mutating func attachingClaudeCodeIdentity(
        to credential: ClaudeUsageCredential,
        globalConfigURL: URL
    ) -> ClaudeUsageCredential {
        var credential = credential
        let digest = credential.tokenDigest
        if let cached = claudeCodeIdentityCache, cached.tokenDigest == digest {
            credential.identity = cached.identity
        } else {
            let identity = claudeCodeIdentity(globalConfigURL: globalConfigURL)
            claudeCodeIdentityCache = (tokenDigest: digest, identity: identity)
            credential.identity = identity
        }
        return credential
    }

    private static func preferredClaudeCodeFailure(
        _ current: ClaudeCodeCredentialLookup,
        _ candidate: ClaudeCodeCredentialLookup
    ) -> ClaudeCodeCredentialLookup {
        candidate.failurePriority > current.failurePriority ? candidate : current
    }
}

private func claudeCodeStrictNumber(_ value: Any) -> Double? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return nil }
    let result = number.doubleValue
    guard result.isFinite, result >= 0 else { return nil }
    return result
}

private func claudeCodeNonempty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    return value
}
