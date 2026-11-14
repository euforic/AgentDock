import CommonCrypto
import CryptoKit
import Foundation
import Security
import SQLite3
import XCTest
@testable import AgentDockCore

final class ClaudeCredentialReaderTests: XCTestCase {
    func testDesktopKeyIsReusedWhileProfileCredentialsAreReadFresh() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A real, isolated Keychain with synthetic data; never query the login Keychain.
        let password = "agentdock-test-password"
        var created: SecKeychain?
        let status = password.withCString { bytes in
            SecKeychainCreate(
                directory.appendingPathComponent("fixture.keychain").path,
                UInt32(password.utf8.count), bytes, false, nil, &created
            )
        }
        XCTAssertEqual(status, errSecSuccess)
        let keychain = try XCTUnwrap(created)
        defer { _ = SecKeychainDelete(keychain) }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage",
            kSecAttrAccount as String: "Claude Key",
            kSecUseKeychain as String: keychain,
            kSecValueData as String: Data(password.utf8)
        ]
        XCTAssertEqual(SecItemAdd(attributes as CFDictionary, nil), errSecSuccess)

        let official = directory.appendingPathComponent("official", isDirectory: true)
        let managed = directory.appendingPathComponent("managed", isDirectory: true)
        try FileManager.default.createDirectory(at: official, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        // Electron v10 AES-CBC fixtures, PBKDF2-SHA1(password, "saltysalt", 1003), space IV.
        let first = Data(#"{"lastKnownAccountUuid":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","oauth:tokenCacheV2":"djEwE9y4lgzKGR3SkB2bnuiCGyRu9Thl9kfHsh0glwfcgQ7JEx5myhGSAv+phFvoC2MCpK3VgEvAo7iiuBImTOCnJlWWVmFucBH3ZD5Eh54R/FfVs5Q2SWCckEmFJNct5iZHIBFyAscCYa2D1RO4M25aMGiLjpeJiDJbMqCTX5rGF/7DKydfhLrE1L/+mu8ZbSlQ9d0ZUv9lZmmbV3yKSdljpA=="}"#.utf8)
        let second = Data(#"{"lastKnownAccountUuid":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","oauth:tokenCacheV2":"djEwdg7PGZpJc77QOSdvoS8YSvNkgCSUGYt8jtehMMnLLTWBFO/nW0vRiOmRux5zYnPlMxnx/qWboh+lLeCr44jMIUpJ1p+uh9zLU9+AkB85XR2Ob8uWlNCSZoZDAq8LahFF29uz2K1j6Nbpymx+3jymLP1ZLsHLslNsusecFt9wszx6U/5Z/FYa2swcti8N6tUVfJ3edu1rQVr1kS/l9W6kiA=="}"#.utf8)
        try first.write(to: official.appendingPathComponent("config.json"))
        try second.write(to: managed.appendingPathComponent("config.json"))

        var reader = ClaudeCredentialReader(keychain: keychain)
        XCTAssertEqual(reader.readDesktopCredential(
            userDataURL: official, allowKeychainInteraction: false
        )?.accessToken, "synthetic-token-one")

        // Remove only our synthetic item. Subsequent success requires the retained key.
        let deletion: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage",
            kSecAttrAccount as String: "Claude Key",
            kSecMatchSearchList as String: [keychain]
        ]
        XCTAssertEqual(SecItemDelete(deletion as CFDictionary), errSecSuccess)
        let other = try XCTUnwrap(reader.readDesktopCredential(
            userDataURL: managed, allowKeychainInteraction: false
        ))
        XCTAssertEqual(other.accessToken, "synthetic-token-two")
        XCTAssertEqual(other.identity?.accountUUID, "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        XCTAssertEqual(other.identity?.organizationUUID, "22222222-2222-2222-2222-222222222222")

        // A replaced token/account on the same root must not reuse the old credential.
        try second.write(to: official.appendingPathComponent("config.json"))
        XCTAssertEqual(reader.readDesktopCredential(
            userDataURL: official, allowKeychainInteraction: false
        )?.accessToken, "synthetic-token-two")
        try FileManager.default.removeItem(at: official.appendingPathComponent("config.json"))
        XCTAssertNil(reader.readDesktopCredential(
            userDataURL: official, allowKeychainInteraction: false
        ))

        // A new reader has no persisted key and cannot read the now-missing item.
        var freshReader = ClaudeCredentialReader(keychain: keychain)
        XCTAssertNil(freshReader.readDesktopCredential(
            userDataURL: managed, allowKeychainInteraction: false
        ))
    }

    func testActiveOrganizationReadsNewestPlainCookie() throws {
        let profile = try makeDirectory()
        try makeCookies(at: profile.appendingPathComponent("Cookies"), rows: [
            ("claude.ai", "lastActiveOrg", "44444444-4444-4444-8444-444444444444", Data(), 1),
            (".claude.ai", "lastActiveOrg", Self.organization.uppercased(), Data(), 2),
            ("claude.ai.example", "lastActiveOrg", "55555555-5555-4555-8555-555555555555", Data(), 3),
            (".claude.ai", "lastActiveProject", "66666666-6666-4666-8666-666666666666", Data(), 4)
        ])

        XCTAssertEqual(
            ClaudeCredentialReader().activeOrganization(userDataURL: profile, key: Self.cookieKey),
            Self.organization
        )
    }

    func testActiveOrganizationDecryptsHostBoundCookie() throws {
        let profile = try makeDirectory()
        let network = profile.appendingPathComponent("Network", isDirectory: true)
        try FileManager.default.createDirectory(at: network, withIntermediateDirectories: true)
        try makeCookies(at: network.appendingPathComponent("Cookies"), rows: [
            (".claude.ai", "lastActiveOrg", "", encryptCookie(Self.organization, host: ".claude.ai"), 1)
        ])
        XCTAssertEqual(
            ClaudeCredentialReader().activeOrganization(userDataURL: profile, key: Self.cookieKey),
            Self.organization
        )

        // A value bound to a different host fails validation.
        let otherProfile = try makeDirectory()
        try makeCookies(at: otherProfile.appendingPathComponent("Cookies"), rows: [
            (".claude.ai", "lastActiveOrg", "", encryptCookie(Self.organization, host: "claude.ai"), 1)
        ])
        XCTAssertNil(ClaudeCredentialReader().activeOrganization(
            userDataURL: otherProfile, key: Self.cookieKey
        ))
    }

    func testActiveOrganizationRejectsCookiesLinkedFromAnotherProfile() throws {
        let profile = try makeDirectory()
        let otherProfile = try makeDirectory()
        try makeCookies(at: otherProfile.appendingPathComponent("Cookies"), rows: [
            (".claude.ai", "lastActiveOrg", Self.organization, Data(), 1)
        ])
        let network = profile.appendingPathComponent("Network", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: network, withDestinationURL: otherProfile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: network.appendingPathComponent("Cookies").path))

        XCTAssertNil(ClaudeCredentialReader().activeOrganization(userDataURL: profile, key: Self.cookieKey))
        XCTAssertEqual(
            ClaudeCredentialReader().activeOrganization(userDataURL: otherProfile, key: Self.cookieKey),
            Self.organization
        )
    }

    func testActiveOrganizationSkipsDatabaseWithoutCookiesTable() throws {
        let profile = try makeDirectory()
        try makeDatabase(at: profile.appendingPathComponent("Cookies"), sql: """
        create table meta (key text, value text);
        insert into meta values ('version', '24');
        """)
        XCTAssertNil(ClaudeCredentialReader().activeOrganization(userDataURL: profile, key: Self.cookieKey))

        // The failure is limited to that database; the next location is still read.
        let network = profile.appendingPathComponent("Network", isDirectory: true)
        try FileManager.default.createDirectory(at: network, withIntermediateDirectories: true)
        try makeCookies(at: network.appendingPathComponent("Cookies"), rows: [
            (".claude.ai", "lastActiveOrg", Self.organization, Data(), 1)
        ])
        XCTAssertEqual(
            ClaudeCredentialReader().activeOrganization(userDataURL: profile, key: Self.cookieKey),
            Self.organization
        )
    }

    private static let organization = "33333333-3333-4333-8333-333333333333"
    // A synthetic AES-128 key passed directly; Keychain derivation is covered above.
    private static let cookieKey = Data(repeating: 0x5A, count: kCCKeySizeAES128)

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeCookies(
        at database: URL,
        rows: [(host: String, name: String, value: String, encrypted: Data, updated: Int)]
    ) throws {
        let values = rows.map { row in
            let encrypted = row.encrypted.map { String(format: "%02x", $0) }.joined()
            return "(0, '\(row.host)', '\(row.name)', '\(row.value)', x'\(encrypted)', \(row.updated))"
        }
        try makeDatabase(at: database, sql: """
        create table cookies (
          creation_utc integer not null, host_key text not null, name text not null,
          value text not null, encrypted_value blob not null, last_update_utc integer not null
        );
        insert into cookies values \(values.joined(separator: ", "));
        """)
    }

    private func makeDatabase(at database: URL, sql: String) throws {
        var connection: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
            SQLITE_OK
        )
        defer { sqlite3_close_v2(connection) }
        XCTAssertEqual(sqlite3_exec(connection, sql, nil, nil, nil), SQLITE_OK)
    }

    // Electron v10 cookie value: AES-128-CBC, space IV, SHA-256 host-key prefix.
    private func encryptCookie(_ value: String, host: String) -> Data {
        let plaintext = Data(SHA256.hash(data: Data(host.utf8))) + Data(value.utf8)
        let key = Self.cookieKey
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: plaintext.count + kCCBlockSizeAES128)
        var outputLength = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            plaintext.withUnsafeBytes { plaintextBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            plaintextBytes.baseAddress,
                            plaintext.count,
                            outputBytes.baseAddress,
                            capacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        output.count = outputLength
        return Data("v10".utf8) + output
    }
}
