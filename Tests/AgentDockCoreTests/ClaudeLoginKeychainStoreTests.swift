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

    private func addItem(_ data: Data, service: String, to keychain: SecKeychain) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ClaudeLoginKeychainStore.account,
            kSecUseKeychain as String: keychain,
            kSecValueData as String: data
        ]
        XCTAssertEqual(SecItemAdd(attributes as CFDictionary, nil), errSecSuccess)
    }
}
