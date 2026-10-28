import Darwin
import Security
import XCTest
@testable import AgentDockCore

final class LegacyBrandMigrationTests: XCTestCase {
    private var fixture: URL!
    private var keychain: SecKeychain!
    private var support: URL { fixture.appendingPathComponent("Support") }
    private var applications: URL { fixture.appendingPathComponent("Applications") }
    private var oldRoot: URL { support.appendingPathComponent("Codexer") }
    private var root: URL { support.appendingPathComponent("AgentDock") }
    private var oldShortcuts: URL { applications.appendingPathComponent("Codexer") }
    private var shortcuts: URL { applications.appendingPathComponent("AgentDock") }
    private var journalURL: URL { support.appendingPathComponent(".agentdock-brand-migration-v1.json") }

    override func setUpWithError() throws {
        fixture = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("AgentDockMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let password = "synthetic-migration-password"
        var created: SecKeychain?
        let status = password.withCString {
            SecKeychainCreate(fixture.appendingPathComponent("fixture.keychain").path,
                UInt32(password.utf8.count), $0, false, nil, &created)
        }
        XCTAssertEqual(status, errSecSuccess)
        keychain = try XCTUnwrap(created)
    }

    override func tearDownWithError() throws {
        if let keychain { _ = SecKeychainDelete(keychain) }
        try FileManager.default.removeItem(at: fixture)
    }

    private func legacyProfiles() throws -> [CodexProfile] {
        let store = try ProfileStore(rootDirectory: oldRoot, shortcutDirectory: oldShortcuts)
        let codex = try store.createProfile(name: "Work", iconColor: "#123456")
        let claude = try store.createProfile(product: .claude, name: "Personal")
        for profile in [codex, claude] {
            try FileManager.default.moveItem(
                at: profile.profileDirectory.appendingPathComponent(".agentdock-profile.json"),
                to: profile.profileDirectory.appendingPathComponent(".codexer-profile.json")
            )
        }
        let config = codex.codexHomePath.appendingPathComponent("config.toml")
        let text = try String(contentsOf: config, encoding: .utf8)
            .replacingOccurrences(of: CodexMCPConfiguration.managementMarker, with: LegacyBrand.managementMarker)
        try text.write(to: config, atomically: true, encoding: .utf8)
        try Data("synthetic authentication fixture".utf8).write(to: codex.codexHomePath.appendingPathComponent("auth.json"))
        try Data([0, 1, 2, 3, 255]).write(to: claude.claudeUserDataPath.appendingPathComponent("state.db"))
        return [codex, claude]
    }

    private func migrate() throws {
        try LegacyBrandMigration.migrate(applicationSupport: support, applications: applications, keychain: keychain)
    }

    func testMigratesBothProvidersWithoutLosingIdentityConfigurationOrData() throws {
        let before = try legacyProfiles()
        // Include a removed-from-list profile and arbitrary local state.
        let detached = oldRoot.appendingPathComponent("Profiles/detached")
        try FileManager.default.createDirectory(at: detached, withIntermediateDirectories: true)
        try Data("preserved".utf8).write(to: detached.appendingPathComponent("notes"))
        try migrate()
        let store = try ProfileStore(rootDirectory: root, shortcutDirectory: shortcuts)
        XCTAssertEqual(store.profiles.map(\.id), before.map(\.id))
        XCTAssertEqual(store.profiles.map(\.name), before.map(\.name))
        XCTAssertEqual(store.profiles.map(\.createdAt), before.map(\.createdAt).map { Date(timeIntervalSince1970: floor($0.timeIntervalSince1970)) })
        XCTAssertEqual(store.profiles[0].iconColor, before[0].iconColor)
        XCTAssertEqual(store.profiles[0].mcpOAuthCallbackPort, before[0].mcpOAuthCallbackPort)
        XCTAssertEqual(try Data(contentsOf: store.profiles[0].codexHomePath.appendingPathComponent("auth.json")), Data("synthetic authentication fixture".utf8))
        XCTAssertEqual(try Data(contentsOf: store.profiles[1].claudeUserDataPath.appendingPathComponent("state.db")), Data([0, 1, 2, 3, 255]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Profiles/detached/notes").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldShortcuts.path))
        for profile in store.profiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: profile.profileDirectory.appendingPathComponent(".agentdock-profile.json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: profile.profileDirectory.appendingPathComponent(".codexer-profile.json").path))
        }
        let config = try String(contentsOf: store.profiles[0].codexHomePath.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertTrue(config.contains(CodexMCPConfiguration.managementMarker))
        XCTAssertFalse(config.contains(LegacyBrand.managementMarker))
        let metadata = try Data(contentsOf: root.appendingPathComponent("profiles.json"))
        try migrate()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("profiles.json")), metadata)
    }

    func testResumesAfterEachDirectoryRenameAndMetadataCommit() throws {
        for phase in 0...3 {
            let before = try legacyProfiles()
            let backupID = try MigrationBackup.create(applicationSupport: support, store: oldRoot, shortcuts: oldShortcuts)
            try JSONEncoder().encode(LegacyBrandMigration.Journal(moveRoot: true, moveShortcuts: true, backupID: backupID))
                .write(to: journalURL)
            if phase >= 1 { try FileManager.default.moveItem(at: oldRoot, to: root) }
            if phase >= 2 { try FileManager.default.moveItem(at: oldShortcuts, to: shortcuts) }
            if phase >= 3 {
                let rebased = before.map { original in
                    var profile = original
                    profile.profileDirectory = root.appendingPathComponent(original.product == .codex ? "Profiles" : "Profiles/claude").appendingPathComponent(original.slug)
                    profile.shortcutDirectory = original.product == .codex ? shortcuts : shortcuts.appendingPathComponent("claude")
                    return profile
                }
                try JSONEncoder.agentdock.encode(rebased).write(to: root.appendingPathComponent("profiles.json"))
            }
            try migrate()
            let store = try ProfileStore(rootDirectory: root, shortcutDirectory: shortcuts)
            XCTAssertEqual(store.profiles.map(\.id), before.map(\.id))
            XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
            try MigrationBackup.verify(applicationSupport: support, id: backupID)
            try FileManager.default.removeItem(at: root)
            try FileManager.default.removeItem(at: shortcuts)
        }
    }

    func testConflictingStoreIsNeverOverwritten() throws {
        _ = try legacyProfiles()
        let modern = try ProfileStore(rootDirectory: root, shortcutDirectory: shortcuts)
        _ = try modern.createProfile(product: .claude, name: "Separate")
        let oldData = try Data(contentsOf: oldRoot.appendingPathComponent("profiles.json"))
        let newData = try Data(contentsOf: root.appendingPathComponent("profiles.json"))
        XCTAssertThrowsError(try migrate())
        XCTAssertEqual(try Data(contentsOf: oldRoot.appendingPathComponent("profiles.json")), oldData)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("profiles.json")), newData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testRejectsLinkedRootAndInvalidOwnership() throws {
        let profiles = try legacyProfiles()
        let marker = profiles[0].profileDirectory.appendingPathComponent(".codexer-profile.json")
        try Data("{}".utf8).write(to: marker)
        XCTAssertThrowsError(try migrate())
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRoot.path))
        let elsewhere = fixture.appendingPathComponent("Elsewhere")
        try FileManager.default.moveItem(at: oldRoot, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: oldRoot, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try migrate())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testExternalOpenFileBlocksMigrationUntilClosed() throws {
        let profile = try legacyProfiles()[0]
        let file = profile.codexHomePath.appendingPathComponent("auth.json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // A real child holds the file; no provider applications or test doubles.
        process.arguments = ["-c", "exec 3<\"$1\"; echo ready; exec /bin/sleep 30", "migration-test", file.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        _ = output.fileHandleForReading.availableData
        XCTAssertThrowsError(try migrate())
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRoot.path))
        process.terminate()
        process.waitUntilExit()
        try migrate()
    }

    func testCurrentRootConvertsLegacyMarkersWithoutMovingProfiles() throws {
        _ = try legacyProfiles()
        try migrate()
        let store = try ProfileStore(rootDirectory: root, shortcutDirectory: shortcuts)
        let profile = store.profiles[0]
        try FileManager.default.moveItem(at: profile.profileDirectory.appendingPathComponent(".agentdock-profile.json"), to: profile.profileDirectory.appendingPathComponent(".codexer-profile.json"))
        let reloaded = try ProfileStore(rootDirectory: root, shortcutDirectory: shortcuts)
        XCTAssertEqual(reloaded.profiles[0].id, profile.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.profileDirectory.appendingPathComponent(".agentdock-profile.json").path))
    }

    func testKeychainEntriesAreCopiedAndOriginalsRemainAvailable() throws {
        let profile = try legacyProfiles()[0]
        let newHome = root.appendingPathComponent("Profiles/\(profile.slug)/CODEX_HOME")
        let accounts = ProfileCredentialMigration.accounts(home: profile.codexHomePath)
        for account in accounts { try addCredential(account, value: "synthetic-secret") }
        let secrets = profile.codexHomePath.appendingPathComponent("secrets")
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)
        let encrypted = Data("synthetic ciphertext".utf8)
        try encrypted.write(to: secrets.appendingPathComponent("mcp_oauth.age"))
        try migrate()
        for account in accounts + ProfileCredentialMigration.accounts(home: newHome) {
            XCTAssertEqual(try readCredential(account), Data("synthetic-secret".utf8))
        }
        XCTAssertEqual(try Data(contentsOf: newHome.appendingPathComponent("secrets/mcp_oauth.age")), encrypted)
        // Repeating the credential phase is safe after a crash before the folder rename.
        try ProfileCredentialMigration.migrate(oldHome: profile.codexHomePath, newHome: newHome, existingHome: newHome, keychain: keychain)
    }

    func testMissingEncryptionKeyAndConflictingCredentialsLeaveFoldersInPlace() throws {
        let profile = try legacyProfiles()[0]
        let secrets = profile.codexHomePath.appendingPathComponent("secrets")
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)
        let encrypted = secrets.appendingPathComponent("mcp_oauth.age")
        try Data("synthetic ciphertext".utf8).write(to: encrypted)
        XCTAssertThrowsError(try migrate())
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.profileDirectory.appendingPathComponent(".codexer-profile.json").path))
        XCTAssertTrue(try String(contentsOf: profile.codexHomePath.appendingPathComponent("config.toml"), encoding: .utf8).contains(LegacyBrand.managementMarker))
        try FileManager.default.removeItem(at: encrypted)
        let old = ProfileCredentialMigration.accounts(home: profile.codexHomePath)[0]
        let new = ProfileCredentialMigration.accounts(home: root.appendingPathComponent("Profiles/\(profile.slug)/CODEX_HOME"))[0]
        try addCredential(old, value: "original")
        try addCredential(new, value: "conflicting")
        XCTAssertThrowsError(try migrate())
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRoot.path))
        XCTAssertEqual(try readCredential(old), Data("original".utf8))
        XCTAssertEqual(try readCredential(new), Data("conflicting".utf8))
    }

    private func addCredential(_ account: ProfileCredentialMigration.Account, value: String) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: account.service, kSecAttrAccount as String: account.name,
            kSecUseKeychain as String: keychain!, kSecValueData as String: Data(value.utf8)
        ]
        XCTAssertEqual(SecItemAdd(attributes as CFDictionary, nil), errSecSuccess)
    }

    private func readCredential(_ account: ProfileCredentialMigration.Account) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: account.service, kSecAttrAccount as String: account.name,
            kSecMatchSearchList as String: [keychain!], kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        return try XCTUnwrap(result as? Data)
    }

    func testLegacyDeletionJournalRecoversBeforeMovingTheStore() throws {
        let profiles = try legacyProfiles()
        let profile = profiles[0]
        let quarantine = profile.profileDirectory.deletingLastPathComponent()
            .appendingPathComponent(".codexer-deleting-test-\(profile.slug)")
        try FileManager.default.moveItem(at: profile.profileDirectory, to: quarantine)
        let journal: [String: Any] = [
            "profileID": profile.id.uuidString,
            "moves": [["original": profile.profileDirectory.absoluteString, "quarantine": quarantine.absoluteString]]
        ]
        try JSONSerialization.data(withJSONObject: journal).write(to: oldRoot.appendingPathComponent(".delete-profile-journal.json"))
        try migrate()
        let migrated = try ProfileStore(rootDirectory: root, shortcutDirectory: shortcuts)
        XCTAssertEqual(migrated.profiles.map(\.id), profiles.map(\.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: migrated.profiles[0].codexHomePath.appendingPathComponent("auth.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".delete-profile-journal.json").path))
    }

    func testExistingLegacyOperationLockStillSerializesNewHelpers() throws {
        let profile = try legacyProfiles()[0]
        let legacyLock = profile.profileDirectory.deletingLastPathComponent()
            .appendingPathComponent(".codexer-locks/\(profile.slug).lock")
        do {
            let held = try AdvisoryFileLock.acquireSynchronously(at: legacyLock)
            defer { withExtendedLifetime(held) {} }
            XCTAssertThrowsError(try ProfileOperationLock.acquireSynchronously(for: profile.profileDirectory, timeout: .milliseconds(10)))
        }
        let current = try ProfileOperationLock.acquireSynchronously(for: profile.profileDirectory)
        withExtendedLifetime(current) {}
    }

    func testFreshInstallationDoesNotCreateLegacyFoldersOrMigrationJournal() throws {
        try migrate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldShortcuts.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testOpeningStoreAutomaticallyMigratesAndRetainsVerifiedOriginals() throws {
        let profiles = try legacyProfiles()
        let metadata = try Data(contentsOf: oldRoot.appendingPathComponent("profiles.json"))
        let config = try Data(contentsOf: profiles[0].codexHomePath.appendingPathComponent("config.toml"))
        let shortcutFile = oldShortcuts.appendingPathComponent("retained-shortcut-data")
        try Data("original shortcut".utf8).write(to: shortcutFile)
        let store = try ProfileStore(migratingStorageAt: support, applications: applications, keychain: keychain)
        XCTAssertEqual(store.profiles.map(\.id), profiles.map(\.id))
        let backups = try FileManager.default.contentsOfDirectory(at: support.appendingPathComponent(MigrationBackup.directoryName), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        let backup = try XCTUnwrap(backups.first)
        try MigrationBackup.verify(applicationSupport: support, id: try XCTUnwrap(UUID(uuidString: backup.lastPathComponent)))
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("Store/profiles.json")), metadata)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("Store/Profiles/work/CODEX_HOME/config.toml")), config)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("Store/Profiles/work/.codexer-profile.json").path))
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("Shortcuts/retained-shortcut-data")), Data("original shortcut".utf8))
        _ = try ProfileStore(migratingStorageAt: support, applications: applications, keychain: keychain)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backup.deletingLastPathComponent().path).count, 1)
    }

    func testBackupFailureLeavesOriginalFilesAndNoCompletionMarker() throws {
        let profiles = try legacyProfiles()
        let metadata = try Data(contentsOf: oldRoot.appendingPathComponent("profiles.json"))
        // A real filesystem conflict makes the backup unavailable.
        try Data("existing file".utf8).write(to: support.appendingPathComponent(MigrationBackup.directoryName))
        XCTAssertThrowsError(try ProfileStore(migratingStorageAt: support, applications: applications, keychain: keychain))
        XCTAssertEqual(try Data(contentsOf: oldRoot.appendingPathComponent("profiles.json")), metadata)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profiles[0].profileDirectory.appendingPathComponent(".codexer-profile.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldShortcuts.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".brand-migration-v1-complete").path))
    }

    func testDamagedBackupStopsResumeWithoutMovingOriginals() throws {
        _ = try legacyProfiles()
        let id = try MigrationBackup.create(applicationSupport: support, store: oldRoot, shortcuts: oldShortcuts)
        try JSONEncoder().encode(LegacyBrandMigration.Journal(moveRoot: true, moveShortcuts: true, backupID: id)).write(to: journalURL)
        let backup = support.appendingPathComponent(MigrationBackup.directoryName).appendingPathComponent(id.uuidString)
        try Data("damaged".utf8).write(to: backup.appendingPathComponent("Store/profiles.json"))
        XCTAssertThrowsError(try migrate())
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldShortcuts.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testBackupPreservesLinksWithoutFollowingExternalTargets() throws {
        let profiles = try legacyProfiles()
        let external = fixture.appendingPathComponent("external")
        try Data("external".utf8).write(to: external)
        let link = profiles[0].codexHomePath.appendingPathComponent("linked-resource")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let id = try MigrationBackup.create(applicationSupport: support, store: oldRoot, shortcuts: oldShortcuts)
        let copiedLink = support.appendingPathComponent(MigrationBackup.directoryName)
            .appendingPathComponent(id.uuidString).appendingPathComponent("Store/Profiles/work/CODEX_HOME/linked-resource")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: copiedLink.path), external.path)
        try Data("changed externally".utf8).write(to: external)
        try MigrationBackup.verify(applicationSupport: support, id: id)
    }

    func testExistingAgentDockStoreIsBackedUpBeforeLegacyMarkerConversion() throws {
        let originals = try legacyProfiles()
        try FileManager.default.moveItem(at: oldRoot, to: root)
        try FileManager.default.moveItem(at: oldShortcuts, to: shortcuts)
        let profiles = originals.map { original in
            var profile = original
            profile.profileDirectory = root.appendingPathComponent(original.product == .codex ? "Profiles" : "Profiles/claude").appendingPathComponent(original.slug)
            profile.shortcutDirectory = original.product == .codex ? shortcuts : shortcuts.appendingPathComponent("claude")
            return profile
        }
        try JSONEncoder.agentdock.encode(profiles).write(to: root.appendingPathComponent("profiles.json"))
        let store = try ProfileStore(migratingStorageAt: support, applications: applications, keychain: keychain)
        XCTAssertEqual(store.profiles.map(\.id), profiles.map(\.id))
        let backups = try FileManager.default.contentsOfDirectory(at: support.appendingPathComponent(MigrationBackup.directoryName), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        let backup = try XCTUnwrap(backups.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("Store/Profiles/work/.codexer-profile.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.profiles[0].profileDirectory.appendingPathComponent(".agentdock-profile.json").path))
    }

    func testPreferenceMigrationPreservesCurrentChoicesAndRunsOnce() throws {
        let suite = "AgentDockMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("dark", forKey: "Codexer.appearance")
        defaults.set("overview", forKey: "Codexer.defaultView")
        defaults.set("light", forKey: "AgentDock.appearance")
        defaults.set("/Applications/Example.app", forKey: "Codexer.desktopAppPath.codex")
        let store = AgentDockPreferencesStore(defaults: defaults)
        XCTAssertEqual(store.load().appearance, .light)
        XCTAssertEqual(store.load().defaultView, .overview)
        XCTAssertEqual(defaults.string(forKey: "AgentDock.desktopAppPath.codex"), "/Applications/Example.app")
        defaults.removeObject(forKey: "AgentDock.defaultView")
        LegacyBrand.migratePreferences(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "AgentDock.defaultView"))
    }
}
