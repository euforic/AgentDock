import Foundation
import Security
import XCTest
@testable import AgentDockCore

/// A real, isolated Keychain with synthetic data; never the login Keychain.
final class ClaudeLoginKeychainStoreTests: XCTestCase {
    func testKeychainStoreRoundTripInTemporaryKeychain() throws {
        let keychain = try makeKeychain()
        defer { _ = SecKeychainDelete(keychain) }
        let service = "\(ClaudeLoginKeychainStore.service).test-\(UUID().uuidString)"
        let store = ClaudeLoginKeychainStore(keychain: keychain, service: service)

        XCTAssertNil(try store.load(allowInteraction: false))

        let first = ClaudeLoginTokens(
            accessToken: "synthetic-access-a",
            refreshToken: "synthetic-refresh-a",
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            scopes: ["user:profile", "user:inference"],
            accountUUID: "00000000-0000-0000-0000-000000000001",
            organizationUUID: "00000000-0000-0000-0000-000000000002",
            accountLabel: "synthetic@example.invalid",
            subscriptionType: "max"
        )
        try store.save(first, allowInteraction: false)
        XCTAssertEqual(try store.load(allowInteraction: false), first)

        var second = first
        second.accessToken = "synthetic-access-b"
        second.refreshToken = "synthetic-refresh-b"
        second.expiresAt = nil
        try store.save(second, allowInteraction: false)
        XCTAssertEqual(try store.load(allowInteraction: false), second)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchSearchList as String: [keychain],
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let items = try XCTUnwrap(result as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?[kSecAttrLabel as String] as? String, "AgentDock Claude Sign-In")
        XCTAssertEqual(items.first?[kSecAttrService as String] as? String, service)
        XCTAssertTrue(service.hasPrefix("dev.euforic.agentdock.claude-login"))
        XCTAssertEqual(items.first?[kSecAttrAccount as String] as? String, "claude-code")

        try store.delete(allowInteraction: false)
        XCTAssertNil(try store.load(allowInteraction: false))
        XCTAssertNoThrow(try store.delete(allowInteraction: false))
    }

    func testUnreadablePayloadIsRejected() throws {
        let keychain = try makeKeychain()
        defer { _ = SecKeychainDelete(keychain) }
        let service = "\(ClaudeLoginKeychainStore.service).test-\(UUID().uuidString)"
        let store = ClaudeLoginKeychainStore(keychain: keychain, service: service)

        try addItem(Data("not json".utf8), service: service, to: keychain)
        XCTAssertThrowsError(try store.load(allowInteraction: false)) { error in
            XCTAssertEqual(error as? ClaudeLoginStoreError, .unreadable)
        }

        try store.delete(allowInteraction: false)
        try addItem(
            Data(repeating: 0x20, count: ClaudeLoginKeychainStore.maximumBytes + 1),
            service: service,
            to: keychain
        )
        XCTAssertThrowsError(try store.load(allowInteraction: false)) { error in
            XCTAssertEqual(error as? ClaudeLoginStoreError, .unreadable)
        }
    }

    func testAccountItemsAreKeyedListedReplacedAndDeletedSeparately() throws {
        let keychain = try makeKeychain()
        defer { _ = SecKeychainDelete(keychain) }
        let service = "\(ClaudeLoginKeychainStore.service).test-\(UUID().uuidString)"
        let accounts = ClaudeLoginKeychainAccounts(keychain: keychain, service: service)
        XCTAssertEqual(try accounts.accountKeys(allowInteraction: false), [])

        let first = Self.tokens(access: "synthetic-access-a", account: 1)
        let second = Self.tokens(access: "synthetic-access-second", account: 3)
        try accounts.tokenStore(forAccountKey: first.accountKey).save(first, allowInteraction: false)
        try accounts.tokenStore(forAccountKey: second.accountKey).save(second, allowInteraction: false)

        XCTAssertEqual(
            try accounts.accountKeys(allowInteraction: false),
            [first.accountKey, second.accountKey].sorted()
        )
        XCTAssertEqual(try accounts.tokenStore(forAccountKey: first.accountKey).load(allowInteraction: false), first)
        XCTAssertEqual(try accounts.tokenStore(forAccountKey: second.accountKey).load(allowInteraction: false), second)

        // Signing in again replaces the account's item instead of adding one.
        var replaced = first
        replaced.accessToken = "synthetic-access-b"
        replaced.customName = "Work"
        try accounts.tokenStore(forAccountKey: first.accountKey).save(replaced, allowInteraction: false)
        XCTAssertEqual(try accounts.tokenStore(forAccountKey: first.accountKey).load(allowInteraction: false), replaced)

        let items = try itemAttributes(in: keychain, service: service)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(
            Set(items.compactMap { $0[kSecAttrAccount as String] as? String }),
            ["claude-code:\(first.accountKey)", "claude-code:\(second.accountKey)"]
        )
        XCTAssertTrue(items.allSatisfy { $0[kSecAttrLabel as String] as? String == "AgentDock Claude Sign-In" })
        // Account names never carry the raw identifiers or the email.
        for item in items {
            let name = try XCTUnwrap(item[kSecAttrAccount as String] as? String)
            XCTAssertFalse(name.contains("00000000-0000-0000-0000"))
            XCTAssertFalse(name.contains("example.invalid"))
        }

        // An account's item refuses another account's sign-in.
        XCTAssertThrowsError(
            try accounts.tokenStore(forAccountKey: first.accountKey).save(second, allowInteraction: false)
        ) { error in
            XCTAssertEqual(error as? ClaudeLoginStoreError, .unreadable)
        }

        // Signing out deletes only that account's item.
        try accounts.tokenStore(forAccountKey: first.accountKey).delete(allowInteraction: false)
        XCTAssertEqual(try accounts.accountKeys(allowInteraction: false), [second.accountKey])
        XCTAssertNil(try accounts.tokenStore(forAccountKey: first.accountKey).load(allowInteraction: false))
        XCTAssertEqual(try accounts.tokenStore(forAccountKey: second.accountKey).load(allowInteraction: false), second)
    }

    func testListingIgnoresLegacyAndForeignAccountNames() throws {
        let keychain = try makeKeychain()
        defer { _ = SecKeychainDelete(keychain) }
        let service = "\(ClaudeLoginKeychainStore.service).test-\(UUID().uuidString)"
        let accounts = ClaudeLoginKeychainAccounts(keychain: keychain, service: service)
        let tokens = Self.tokens(access: "synthetic-access-a", account: 1)

        try ClaudeLoginKeychainStore(keychain: keychain, service: service).save(tokens, allowInteraction: false)
        try addItem(Data("{}".utf8), service: service, account: "claude-code:not-a-key", to: keychain)
        try addItem(Data("{}".utf8), service: service, account: "other", to: keychain)
        // The same account name under another service is never listed.
        try addItem(
            Data("{}".utf8),
            service: "\(service).other",
            account: "claude-code:\(tokens.accountKey)",
            to: keychain
        )

        XCTAssertEqual(try accounts.accountKeys(allowInteraction: false), [])
        XCTAssertEqual(try accounts.legacyTokenStore.load(allowInteraction: false), tokens)
    }

    func testLegacyItemMigratesInTemporaryKeychain() async throws {
        let keychain = try makeKeychain()
        defer { _ = SecKeychainDelete(keychain) }
        let service = "\(ClaudeLoginKeychainStore.service).test-\(UUID().uuidString)"
        let legacy = Self.tokens(access: "synthetic-access-a", account: 1)
        try ClaudeLoginKeychainStore(keychain: keychain, service: service).save(legacy, allowInteraction: false)
        let store = ClaudeLoginKeychainAccounts(keychain: keychain, service: service)
        let registry = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())

        let listing = await registry.list()

        XCTAssertEqual(listing.accounts.map(\.key), [legacy.accountKey])
        XCTAssertEqual(listing.accounts.first?.status.isSignedIn, true)
        XCTAssertNil(try store.legacyTokenStore.load(allowInteraction: false))
        let migrated = try XCTUnwrap(try store.tokenStore(forAccountKey: legacy.accountKey).load(allowInteraction: false))
        XCTAssertEqual(migrated.accessToken, legacy.accessToken)
        XCTAssertEqual(migrated.refreshToken, legacy.refreshToken)
        XCTAssertNotNil(migrated.addedAt)
        let items = try itemAttributes(in: keychain, service: service)
        XCTAssertEqual(items.compactMap { $0[kSecAttrAccount as String] as? String }, ["claude-code:\(legacy.accountKey)"])

        // A second launch finds nothing left to migrate.
        let relaunched = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())
        let again = await relaunched.list()
        XCTAssertEqual(again.accounts.map(\.key), [legacy.accountKey])
        XCTAssertEqual(try itemAttributes(in: keychain, service: service).count, 1)
    }

    private static func tokens(access: String, account: Int) -> ClaudeLoginTokens {
        ClaudeLoginTokens(
            accessToken: access,
            refreshToken: "synthetic-refresh-\(account)",
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            scopes: ["user:profile", "user:inference"],
            accountUUID: String(format: "00000000-0000-0000-0000-%012d", account),
            organizationUUID: String(format: "00000000-0000-0000-0000-%012d", account + 1),
            accountLabel: "synthetic-\(account)@example.invalid",
            subscriptionType: "max",
            addedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(account))
        )
    }

    private func itemAttributes(in keychain: SecKeychain, service: String) throws -> [[String: Any]] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchSearchList as String: [keychain],
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        XCTAssertEqual(status, errSecSuccess)
        return try XCTUnwrap(result as? [[String: Any]])
    }

    private func makeKeychain() throws -> SecKeychain {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let password = "agentdock-test-password"
        var created: SecKeychain?
        let status = password.withCString { bytes in
            SecKeychainCreate(
                directory.appendingPathComponent("fixture.keychain").path,
                UInt32(password.utf8.count), bytes, false, nil, &created
            )
        }
        XCTAssertEqual(status, errSecSuccess)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        // Callers delete the keychain with `SecKeychainDelete` before returning.
        return try XCTUnwrap(created)
    }

    private func addItem(
        _ data: Data,
        service: String,
        account: String = ClaudeLoginKeychainStore.account,
        to keychain: SecKeychain
    ) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseKeychain as String: keychain,
            kSecValueData as String: data
        ]
        XCTAssertEqual(SecItemAdd(attributes as CFDictionary, nil), errSecSuccess)
    }
}
