import CryptoKit
import Foundation
import Security

/// Codex keys its login and encrypted-secret Keychain entries by canonical
/// CODEX_HOME. Copy only these exact entries, preserving access controls and the
/// originals. Never export credentials into the migration journal or logs.
/// Upstream contracts: codex-rs/login/src/auth/storage.rs and
/// codex-rs/secrets/src/lib.rs in https://github.com/openai/codex.
enum ProfileCredentialMigration {
    struct Account: Equatable {
        let service: String
        let name: String
        let encryptedFiles: [String]
    }

    static func accounts(home: URL) -> [Account] {
        let path = home.standardizedFileURL.resolvingSymlinksInPath().path
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        return [
            Account(service: "Codex Auth", name: "cli|\(hash)", encryptedFiles: []),
            Account(service: "codex", name: "secrets|\(hash)", encryptedFiles: ["local.age", "codex_auth.age", "mcp_oauth.age"]),
            Account(service: "codex", name: "secrets|\(hash)|gateway-oauth", encryptedFiles: ["gateway_oauth.age"])
        ]
    }

    static func migrate(oldHome: URL, newHome: URL, existingHome: URL, keychain: SecKeychain? = nil) throws {
        for (old, new) in zip(accounts(home: oldHome), accounts(home: newHome)) {
            guard old.name != new.name else { continue }
            guard let source = try read(old, keychain: keychain) else {
                let hasEncryptedData = old.encryptedFiles.contains {
                    LegacyBrand.exists(existingHome.appendingPathComponent("secrets").appendingPathComponent($0))
                }
                guard !hasEncryptedData else { throw CredentialError.missingEncryptionKey }
                continue
            }
            if let destination = try read(new, keychain: keychain) {
                guard destination.data == source.data else { throw CredentialError.conflict }
                continue
            }
            var access: SecAccess?
            var sourceKeychain: SecKeychain?
            try check(SecKeychainItemCopyAccess(source.item, &access))
            try check(SecKeychainItemCopyKeychain(source.item, &sourceKeychain))
            guard let access, let sourceKeychain else { throw CredentialError.invalidItem }
            let attributes: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: new.service,
                kSecAttrAccount as String: new.name,
                kSecValueData as String: source.data,
                kSecAttrAccess as String: access,
                kSecUseKeychain as String: sourceKeychain
            ]
            let status = SecItemAdd(attributes as CFDictionary, nil)
            if status == errSecDuplicateItem {
                guard try read(new, keychain: keychain)?.data == source.data else { throw CredentialError.conflict }
            } else {
                try check(status)
            }
        }
    }

    private struct Item {
        let item: SecKeychainItem
        let data: Data
    }

    private static func read(_ account: Account, keychain: SecKeychain?) throws -> Item? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: account.service,
            kSecAttrAccount as String: account.name,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnRef as String: true,
            kSecReturnData as String: true
        ]
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let dictionary = result as? [String: Any],
              let data = dictionary[kSecValueData as String] as? Data,
              data.count <= LocalControlFileLimit.providerCredentialState,
              let reference = dictionary[kSecValueRef as String],
              CFGetTypeID(reference as CFTypeRef) == SecKeychainItemGetTypeID()
        else { throw CredentialError.invalidItem }
        return Item(item: reference as! SecKeychainItem, data: data)
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
    }

    enum CredentialError: Error, LocalizedError {
        case keychain(OSStatus), conflict, missingEncryptionKey, invalidItem
        var errorDescription: String? {
            switch self {
            case let .keychain(status):
                "AgentDock could not preserve the profile's Keychain entries (status \(status)). Unlock the login Keychain and allow access, then relaunch. Profile files have been preserved."
            case .conflict:
                "The destination profile has a different Keychain entry. Migration stopped without replacing either credential."
            case .missingEncryptionKey:
                "An encrypted profile file has no matching Keychain key. Restore that key before migrating; the encrypted file has been preserved."
            case .invalidItem:
                "The profile's Keychain entry could not be safely migrated. Profile files have been preserved."
            }
        }
    }
}
