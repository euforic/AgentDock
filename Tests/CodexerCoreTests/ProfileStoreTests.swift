import XCTest
@testable import CodexerCore

final class ProfileStoreTests: XCTestCase {
    private var root: URL!
    private var shortcutRoot: URL!
    private var store: ProfileStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexerTests-\(UUID().uuidString)", isDirectory: true)
        shortcutRoot = root.appendingPathComponent("Shortcuts", isDirectory: true)
        store = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: shortcutRoot,
            usageChecker: NeverInUseChecker()
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCreateProfileCreatesUniqueSlugAndIsolatedPaths() throws {
        let personal = try store.createProfile(name: "Personal")
        let duplicate = try store.createProfile(name: "Personal")

        XCTAssertEqual(personal.slug, "personal")
        XCTAssertEqual(duplicate.slug, "personal-2")
        XCTAssertEqual(personal.shortcutPath.lastPathComponent, "personal.app")
        XCTAssertEqual(duplicate.shortcutPath.lastPathComponent, "personal-2.app")
        XCTAssertEqual(personal.codexHomePath.lastPathComponent, "CODEX_HOME")
        XCTAssertEqual(personal.electronUserDataPath.lastPathComponent, "ElectronUserData")
        XCTAssertTrue(FileManager.default.fileExists(atPath: personal.codexHomePath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: personal.electronUserDataPath.path))
        XCTAssertTrue(
            CodexMCPConfiguration.managedCallbackPorts.contains(
                personal.mcpOAuthCallbackPort
            )
        )
        XCTAssertTrue(
            CodexMCPConfiguration.managedCallbackPorts.contains(
                duplicate.mcpOAuthCallbackPort
            )
        )
        XCTAssertNotEqual(
            personal.mcpOAuthCallbackPort,
            duplicate.mcpOAuthCallbackPort
        )
        try CodexMCPConfiguration.validate(
            codexHomeURL: personal.codexHomePath,
            expectedCallbackPort: personal.mcpOAuthCallbackPort
        )
        try CodexMCPConfiguration.validate(
            codexHomeURL: duplicate.codexHomePath,
            expectedCallbackPort: duplicate.mcpOAuthCallbackPort
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: personal.profileDirectory.appendingPathComponent(".codexer-profile.json").path
        ))
        XCTAssertEqual(store.profiles.map(\.slug), ["personal", "personal-2"])
        XCTAssertTrue(personal.shortcutPath.path.hasPrefix(shortcutRoot.path))
    }

    func testProfileOrderPersistsWithinEachProvider() throws {
        let first = try store.createProfile(name: "First")
        let claude = try store.createProfile(product: .claude, name: "Claude")
        let second = try store.createProfile(name: "Second")
        let third = try store.createProfile(name: "Third")

        try store.reorderProfiles(
            product: .codex,
            orderedIDs: [third.id, first.id, second.id]
        )

        XCTAssertEqual(
            store.profiles.filter { $0.product == .codex }.map(\.id),
            [third.id, first.id, second.id]
        )
        XCTAssertEqual(
            store.profiles.filter { $0.product == .claude }.map(\.id),
            [claude.id]
        )

        let reloaded = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: shortcutRoot,
            usageChecker: NeverInUseChecker()
        )
        XCTAssertEqual(
            reloaded.profiles.filter { $0.product == .codex }.map(\.id),
            [third.id, first.id, second.id]
        )

        let fourth = try reloaded.createProfile(name: "Fourth")
        XCTAssertEqual(
            reloaded.profiles.filter { $0.product == .codex }.map(\.id),
            [third.id, first.id, second.id, fourth.id]
        )
    }

    func testProfileOrderRejectsMissingOrForeignProfiles() throws {
        let first = try store.createProfile(name: "First")
        let second = try store.createProfile(name: "Second")
        let claude = try store.createProfile(product: .claude, name: "Claude")

        XCTAssertThrowsError(try store.reorderProfiles(
            product: .codex,
            orderedIDs: [first.id]
        )) { error in
            XCTAssertEqual(error as? ProfileStoreError, .invalidProfileOrder)
        }
        XCTAssertThrowsError(try store.reorderProfiles(
            product: .codex,
            orderedIDs: [first.id, claude.id]
        )) { error in
            XCTAssertEqual(error as? ProfileStoreError, .invalidProfileOrder)
        }
        XCTAssertEqual(
            store.profiles.filter { $0.product == .codex }.map(\.id),
            [first.id, second.id]
        )
    }

    func testProfileNameCannotEscapeShortcutDirectory() throws {
        let profile = try store.createProfile(name: "../../Outside")

        XCTAssertEqual(profile.shortcutPath.lastPathComponent, "outside.app")
        XCTAssertEqual(profile.shortcutPath.deletingLastPathComponent().standardizedFileURL, shortcutRoot.standardizedFileURL)
    }

    func testCreateDoesNotReusePreservedOnDiskProfile() throws {
        let original = try store.createProfile(name: "Personal")
        try store.removeProfile(id: original.id, policy: .removeFromList)

        let replacement = try store.createProfile(name: "Personal")

        XCTAssertEqual(replacement.slug, "personal-2")
        XCTAssertNotEqual(replacement.profileDirectory, original.profileDirectory)
        XCTAssertNotEqual(
            replacement.mcpOAuthCallbackPort,
            original.mcpOAuthCallbackPort
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.profileDirectory.path))
    }

    func testRestoreRejectsUnmanagedDirectory() throws {
        let arbitrary = root.appendingPathComponent("Unmanaged", isDirectory: true)
        try FileManager.default.createDirectory(at: arbitrary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: arbitrary.appendingPathComponent("CODEX_HOME"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: arbitrary.appendingPathComponent("ElectronUserData"), withIntermediateDirectories: true)

        XCTAssertThrowsError(try store.restoreProfile(name: "Unsafe", profileDirectory: arbitrary)) { error in
            guard case ProfileStoreError.unmanagedProfileDirectory = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRestoreRejectsDirectoryAlreadyOwnedByAnotherProfile() throws {
        let profile = try store.createProfile(name: "Work")

        XCTAssertThrowsError(try store.restoreProfile(name: "Duplicate", profileDirectory: profile.profileDirectory)) { error in
            guard case ProfileStoreError.overlappingProfileDirectory = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRenameProfileUpdatesNameButKeepsDataAndShortcutPathsStable() throws {
        let profile = try store.createProfile(name: "Work")
        let originalCodexHome = profile.codexHomePath
        let originalShortcut = profile.shortcutPath
        let renamed = try store.renameProfile(id: profile.id, name: "Day Job")

        XCTAssertEqual(renamed.name, "Day Job")
        XCTAssertEqual(renamed.slug, "work")
        XCTAssertEqual(renamed.codexHomePath, originalCodexHome)
        XCTAssertEqual(renamed.shortcutPath, originalShortcut)
        XCTAssertEqual(renamed.mcpOAuthCallbackPort, profile.mcpOAuthCallbackPort)
    }

    func testUpdateProfilePersistsAppearanceAndSafelyManagesImportedImage() throws {
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let profile = try store.createProfile(
            name: "Work",
            iconColor: "#2563EB",
            iconKind: .image,
            customIconData: png
        )
        let originalDirectory = profile.profileDirectory
        let originalShortcut = profile.shortcutPath

        XCTAssertEqual(try Data(contentsOf: profile.customIconPath), png)

        let updated = try store.updateProfile(
            id: profile.id,
            name: "Day Job",
            iconColor: "#F97316",
            iconKind: .symbol,
            iconValue: "briefcase",
            customIconData: nil
        )

        XCTAssertEqual(updated.name, "Day Job")
        XCTAssertEqual(updated.iconColor, "#F97316")
        XCTAssertEqual(updated.iconKind, .symbol)
        XCTAssertEqual(updated.iconValue, "briefcase")
        XCTAssertEqual(updated.profileDirectory, originalDirectory)
        XCTAssertEqual(updated.shortcutPath, originalShortcut)
        XCTAssertFalse(FileManager.default.fileExists(atPath: updated.customIconPath.path))

        let reloaded = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: shortcutRoot,
            usageChecker: NeverInUseChecker()
        )
        XCTAssertEqual(reloaded.profiles.first?.iconKind, .symbol)
        XCTAssertEqual(reloaded.profiles.first?.iconValue, "briefcase")
    }

    func testInvalidCustomImageIsRejectedWithoutCreatingProfile() {
        XCTAssertThrowsError(try store.createProfile(
            name: "Unsafe",
            iconKind: .image,
            customIconData: Data("not an image".utf8)
        )) { error in
            XCTAssertEqual(error as? ProfileStoreError, .invalidCustomIcon)
        }
        XCTAssertTrue(store.profiles.isEmpty)
    }

    func testCodexLaunchProfileSelectionPersistsAndResetsToDefault() throws {
        let profile = try store.createProfile(name: "Local")
        let configProfile = try CodexConfigProfile(validating: "ollama")

        let selected = try store.setCodexLaunchProfileSelection(
            id: profile.id,
            selection: .named(configProfile)
        )
        XCTAssertEqual(selected.codexLaunchProfileSelection, .named(configProfile))

        _ = try store.setCodexLaunchProfileSelection(id: profile.id, selection: .useDefault)
        let reloaded = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: shortcutRoot,
            usageChecker: NeverInUseChecker()
        )
        XCTAssertEqual(reloaded.profiles.first?.codexLaunchProfileSelection, .useDefault)
    }

    func testCodexDefaultConfigProfileIsScopedToOneManagedProfile() throws {
        let first = try store.createProfile(name: "First")
        let second = try store.createProfile(name: "Second")
        let configProfile = try CodexConfigProfile(validating: "ollama")

        let updated = try store.setCodexDefaultConfigProfile(
            id: first.id,
            configProfile: configProfile
        )

        XCTAssertEqual(updated.codexDefaultConfigProfile, configProfile)
        XCTAssertNil(store.profiles.first(where: { $0.id == second.id })?.codexDefaultConfigProfile)

        _ = try store.setCodexDefaultConfigProfile(id: first.id, configProfile: nil)
        XCTAssertNil(store.profiles.first(where: { $0.id == first.id })?.codexDefaultConfigProfile)
    }

    func testLegacyProfilesReceiveStableUniqueMCPCallbackPorts() throws {
        let personal = try store.createProfile(name: "Personal")
        let work = try store.createProfile(name: "Work")
        let profilesURL = root.appendingPathComponent("profiles.json")
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: profilesURL))
                as? [[String: Any]]
        )
        for index in payload.indices {
            payload[index].removeValue(forKey: "mcpOAuthCallbackPort")
        }
        try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: profilesURL, options: .atomic)

        let personalConfig = """
        model = "gpt-test"
        mcp_oauth_callback_port = 49200
        mcp_oauth_credentials_store = "file"

        [mcp_servers.example]
        url = "https://example.test/mcp"
        """
        try Data(personalConfig.utf8).write(
            to: personal.codexHomePath.appendingPathComponent("config.toml"),
            options: .atomic
        )
        try Data("[features]\nplugins = true\n".utf8).write(
            to: work.codexHomePath.appendingPathComponent("config.toml"),
            options: .atomic
        )

        let reopened = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: shortcutRoot,
            usageChecker: NeverInUseChecker()
        )
        let migrated = Dictionary(
            uniqueKeysWithValues: reopened.profiles.map { ($0.slug, $0) }
        )
        let migratedPersonal = try XCTUnwrap(migrated["personal"])
        let migratedWork = try XCTUnwrap(migrated["work"])

        XCTAssertEqual(migratedPersonal.mcpOAuthCallbackPort, 49_200)
        XCTAssertTrue(
            CodexMCPConfiguration.managedCallbackPorts.contains(
                migratedWork.mcpOAuthCallbackPort
            )
        )
        XCTAssertNotEqual(
            migratedPersonal.mcpOAuthCallbackPort,
            migratedWork.mcpOAuthCallbackPort
        )
        try CodexMCPConfiguration.validate(
            codexHomeURL: migratedPersonal.codexHomePath,
            expectedCallbackPort: 49_200
        )
        try CodexMCPConfiguration.validate(
            codexHomeURL: migratedWork.codexHomePath,
            expectedCallbackPort: migratedWork.mcpOAuthCallbackPort
        )
        let migratedContent = try String(
            contentsOf: migratedPersonal.codexHomePath.appendingPathComponent("config.toml"),
            encoding: .utf8
        )
        XCTAssertTrue(migratedContent.contains(#"model = "gpt-test""#))
        XCTAssertTrue(migratedContent.contains("[mcp_servers.example]"))
    }

    func testRestorePreservesAvailableMCPCallbackPort() throws {
        let original = try store.createProfile(name: "Detached")
        try store.removeProfile(id: original.id, policy: .removeFromList)

        let restored = try store.restoreProfile(
            name: "Restored",
            profileDirectory: original.profileDirectory
        )

        XCTAssertEqual(
            restored.mcpOAuthCallbackPort,
            original.mcpOAuthCallbackPort
        )
        XCTAssertEqual(restored.id, original.id)
        try CodexMCPConfiguration.validate(
            codexHomeURL: restored.codexHomePath,
            expectedCallbackPort: original.mcpOAuthCallbackPort
        )
    }

    func testRestoreRejectsMismatchedPreservedOwnershipMarker() throws {
        let original = try store.createProfile(name: "Detached")
        try store.removeProfile(id: original.id, policy: .removeFromList)
        let markerURL = original.profileDirectory.appendingPathComponent(".codexer-profile.json")
        let marker = [
            "profileID": original.id.uuidString,
            "product": DesktopProduct.codex.rawValue,
            "slug": "another-profile"
        ]
        try JSONSerialization.data(withJSONObject: marker).write(to: markerURL)

        XCTAssertThrowsError(
            try store.restoreProfile(
                name: "Restored",
                profileDirectory: original.profileDirectory
            )
        ) { error in
            XCTAssertEqual(
                error as? ProfileStoreError,
                .invalidOwnershipMarker(original.profileDirectory.path)
            )
        }
    }

    func testManagedMCPConfigurationDriftFailsWithoutRewritingConfig() throws {
        let profile = try store.createProfile(name: "Drift")
        let configURL = profile.codexHomePath.appendingPathComponent("config.toml")
        let drifted = try String(contentsOf: configURL, encoding: .utf8)
            .replacingOccurrences(
                of: #"mcp_oauth_credentials_store = "keyring""#,
                with: #"mcp_oauth_credentials_store = "file""#
            )
        try Data(drifted.utf8).write(to: configURL, options: .atomic)
        let before = try Data(contentsOf: configURL)

        XCTAssertThrowsError(try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: shortcutRoot,
            usageChecker: NeverInUseChecker()
        )) { error in
            guard case CodexMCPConfigurationError.invalidCredentialsStore = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: configURL), before)
    }

    func testRemoveProfilePreservesDataByDefault() throws {
        let profile = try store.createProfile(name: "Client")

        try store.removeProfile(id: profile.id, policy: .removeFromList)

        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.profileDirectory.path))
    }

    func testDeleteAllDataRemovesProfileDirectoryAndShortcut() throws {
        let profile = try store.createProfile(name: "Disposable")
        try FileManager.default.createDirectory(at: profile.shortcutPath, withIntermediateDirectories: true)

        try store.removeProfile(id: profile.id, policy: .deleteAllData)

        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.profileDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.shortcutPath.path))
        XCTAssertTrue(store.profiles.isEmpty)
    }

    func testDeleteRefusesProfileWithLiveProcesses() throws {
        let guardedStore = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: shortcutRoot,
            usageChecker: AlwaysInUseChecker()
        )
        let profile = try guardedStore.createProfile(name: "Running")

        XCTAssertThrowsError(try guardedStore.removeProfile(id: profile.id, policy: .deleteAllData)) { error in
            guard case ProfileStoreError.profileInUse = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.profileDirectory.path))
        XCTAssertEqual(guardedStore.profiles.map(\.id), [profile.id])
    }

    func testDeleteRollsBackQuarantineWhenMetadataSaveFails() throws {
        let profile = try store.createProfile(name: "Rollback")
        try FileManager.default.createDirectory(at: profile.shortcutPath, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: root.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.path
            )
        }

        XCTAssertThrowsError(try store.removeProfile(id: profile.id, policy: .deleteAllData))

        XCTAssertEqual(store.profiles.map(\.id), [profile.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.profileDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.shortcutPath.path))
    }

    func testDeleteRejectsTamperedOwnershipMarker() throws {
        let profile = try store.createProfile(name: "Owned")
        let marker = profile.profileDirectory.appendingPathComponent(".codexer-profile.json")
        try Data("{}".utf8).write(to: marker, options: .atomic)

        XCTAssertThrowsError(try store.removeProfile(id: profile.id, policy: .deleteAllData)) { error in
            guard case ProfileStoreError.invalidOwnershipMarker = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(store.profiles.map(\.id), [profile.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.profileDirectory.path))
    }

    func testPersistedPathsAreValidatedBeforeUse() throws {
        let profile = try store.createProfile(name: "Safe")
        var tampered = profile
        tampered.profileDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Outside-\(UUID().uuidString)")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([tampered]).write(to: root.appendingPathComponent("profiles.json"), options: .atomic)

        XCTAssertThrowsError(try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: shortcutRoot,
            usageChecker: NeverInUseChecker()
        )) { error in
            guard case ProfileStoreError.unmanagedProfileDirectory = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testIndependentStoresDoNotLoseConcurrentCreates() throws {
        let firstStore = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: shortcutRoot,
            usageChecker: NeverInUseChecker()
        )
        let secondStore = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: shortcutRoot,
            usageChecker: NeverInUseChecker()
        )

        let first = try firstStore.createProfile(name: "First")
        let second = try secondStore.createProfile(name: "Second")
        try firstStore.reload()

        XCTAssertEqual(Set(firstStore.profiles.map(\.id)), Set([first.id, second.id]))
    }

    func testContendedStoreLockTimesOutWithoutCreatingPartialProfile() throws {
        let shortTimeoutStore = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: shortcutRoot,
            usageChecker: NeverInUseChecker(),
            operationLockTimeout: .milliseconds(100)
        )
        let heldLock = try AdvisoryFileLock.acquireSynchronously(
            at: root.appendingPathComponent(".profiles.lock")
        )

        XCTAssertThrowsError(
            try shortTimeoutStore.createProfile(product: .claude, name: "Blocked")
        ) { error in
            XCTAssertEqual(error as? ProfileOperationLockError, .timedOut)
        }
        XCTAssertTrue(shortTimeoutStore.profiles.isEmpty)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: shortTimeoutStore.profilesRootDirectory(for: .claude),
                includingPropertiesForKeys: nil
            ).filter { !$0.lastPathComponent.hasPrefix(".") },
            []
        )
        withExtendedLifetime(heldLock) {}
    }

    func testCreateRollsBackProvisionedDirectoryWhenMetadataSaveFails() throws {
        let existing = try store.createProfile(product: .claude, name: "Existing")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: root.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.path
            )
        }

        XCTAssertThrowsError(
            try store.createProfile(product: .claude, name: "Rollback")
        )

        XCTAssertEqual(store.profiles.map(\.id), [existing.id])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: store.profilesRootDirectory(for: .claude)
                    .appendingPathComponent("rollback")
                    .path
            )
        )
    }

    func testStaleStoreCannotResurrectDeletedProfile() throws {
        let firstStore = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: shortcutRoot,
            usageChecker: NeverInUseChecker()
        )
        let profile = try firstStore.createProfile(name: "Temporary")
        let staleStore = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: shortcutRoot,
            usageChecker: NeverInUseChecker()
        )

        try firstStore.removeProfile(id: profile.id, policy: .deleteAllData)
        XCTAssertThrowsError(try staleStore.markLaunched(id: profile.id)) { error in
            XCTAssertEqual(error as? ProfileStoreError, .profileNotFound)
        }

        let reopened = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: shortcutRoot,
            usageChecker: NeverInUseChecker()
        )
        XCTAssertTrue(reopened.profiles.isEmpty)
    }

    func testPersistedMarkerSlugMustMatchProfile() throws {
        let profile = try store.createProfile(name: "Owned")
        let markerURL = profile.profileDirectory.appendingPathComponent(".codexer-profile.json")
        let marker = ["profileID": profile.id.uuidString, "slug": "different"]
        try JSONSerialization.data(withJSONObject: marker).write(to: markerURL, options: .atomic)

        XCTAssertThrowsError(try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: shortcutRoot,
            usageChecker: NeverInUseChecker()
        )) { error in
            XCTAssertEqual(
                error as? ProfileStoreError,
                .invalidOwnershipMarker(profile.profileDirectory.path)
            )
        }
    }

    func testInterruptedRestoreRecoversPriorOwnershipMarker() throws {
        let detachedDirectory = store.profilesRootDirectory
            .appendingPathComponent("detached", isDirectory: true)
        try FileManager.default.createDirectory(
            at: detachedDirectory.appendingPathComponent("CODEX_HOME"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: detachedDirectory.appendingPathComponent("ElectronUserData"),
            withIntermediateDirectories: true
        )
        let markerURL = detachedDirectory.appendingPathComponent(".codexer-profile.json")
        let originalMarker = Data(#"{"profileID":"00000000-0000-0000-0000-000000000001","slug":"detached"}"#.utf8)
        try originalMarker.write(to: markerURL)
        let interruptedMarker = Data(#"{"profileID":"00000000-0000-0000-0000-000000000002","slug":"detached"}"#.utf8)
        try interruptedMarker.write(to: markerURL)

        let journal: [String: Any] = [
            "profileID": "00000000-0000-0000-0000-000000000002",
            "profileDirectory": detachedDirectory.absoluteString,
            "priorMarker": originalMarker.base64EncodedString()
        ]
        try JSONSerialization.data(withJSONObject: journal).write(
            to: root.appendingPathComponent(".restore-profile-journal.json"),
            options: .atomic
        )

        _ = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: shortcutRoot,
            usageChecker: NeverInUseChecker()
        )

        XCTAssertEqual(try Data(contentsOf: markerURL), originalMarker)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".restore-profile-journal.json").path
        ))
    }

    func testInterruptedDeleteRollsBackWhenMetadataStillOwnsProfile() throws {
        let profile = try store.createProfile(name: "Recoverable")
        let quarantine = profile.profileDirectory.deletingLastPathComponent()
            .appendingPathComponent(".codexer-deleting-test-\(profile.slug)")
        try FileManager.default.moveItem(at: profile.profileDirectory, to: quarantine)
        try writeDeletionJournal(profileID: profile.id, original: profile.profileDirectory, quarantine: quarantine)

        let reopened = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: shortcutRoot,
            usageChecker: NeverInUseChecker()
        )

        XCTAssertEqual(reopened.profiles.map(\.id), [profile.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.profileDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path))
    }

    func testInterruptedDeleteFinishesCleanupAfterMetadataCommit() throws {
        let profile = try store.createProfile(name: "Committed")
        let quarantine = profile.profileDirectory.deletingLastPathComponent()
            .appendingPathComponent(".codexer-deleting-test-\(profile.slug)")
        try FileManager.default.moveItem(at: profile.profileDirectory, to: quarantine)
        try Data("[]".utf8).write(
            to: root.appendingPathComponent("profiles.json"),
            options: .atomic
        )
        try writeDeletionJournal(profileID: profile.id, original: profile.profileDirectory, quarantine: quarantine)

        let reopened = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: shortcutRoot,
            usageChecker: NeverInUseChecker()
        )

        XCTAssertTrue(reopened.profiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path))
    }

    func testTamperedDeletionJournalCannotDeleteExternalFile() throws {
        let victim = FileManager.default.temporaryDirectory
            .appendingPathComponent("Codexer-victim-\(UUID().uuidString)")
        try Data("keep".utf8).write(to: victim)
        defer { try? FileManager.default.removeItem(at: victim) }
        try writeDeletionJournal(
            profileID: UUID(),
            original: root.appendingPathComponent("Profiles/fake"),
            quarantine: victim
        )

        XCTAssertThrowsError(try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: shortcutRoot,
            usageChecker: NeverInUseChecker()
        )) { error in
            guard case ProfileStoreError.invalidRecoveryJournal = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
    }

    func testRestoreRejectsSymlinkedIsolationDirectory() throws {
        let directory = store.profilesRootDirectory.appendingPathComponent("linked")
        let external = root.appendingPathComponent("External")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("CODEX_HOME"),
            withDestinationURL: external
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("ElectronUserData"),
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(try store.restoreProfile(name: "Linked", profileDirectory: directory)) { error in
            guard case ProfileStoreError.invalidProfileLayout = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func writeDeletionJournal(profileID: UUID, original: URL, quarantine: URL) throws {
        let journal: [String: Any] = [
            "profileID": profileID.uuidString,
            "moves": [[
                "original": original.absoluteString,
                "quarantine": quarantine.absoluteString
            ]]
        ]
        try JSONSerialization.data(withJSONObject: journal).write(
            to: root.appendingPathComponent(".delete-profile-journal.json"),
            options: .atomic
        )
    }
}

private struct NeverInUseChecker: ProfileUsageChecking {
    func isProfileInUse(_: CodexProfile) -> Bool { false }
}

private struct AlwaysInUseChecker: ProfileUsageChecking {
    func isProfileInUse(_: CodexProfile) -> Bool { true }
}
