import SwiftUI
import XCTest
@testable import AgentDock
@testable import AgentDockCore

@MainActor
final class AgentDockModelTests: XCTestCase {
    func testWorkspaceNotificationsOnlyRefreshForSupportedProviders() {
        XCTAssertTrue(AgentDockModel.isRelevantWorkspaceBundleIdentifier("com.openai.codex"))
        XCTAssertTrue(AgentDockModel.isRelevantWorkspaceBundleIdentifier("com.anthropic.claudefordesktop"))
        XCTAssertFalse(AgentDockModel.isRelevantWorkspaceBundleIdentifier("com.apple.TextEdit"))
        XCTAssertFalse(AgentDockModel.isRelevantWorkspaceBundleIdentifier(nil))
    }

    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentDockModelTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
        .resolvingSymlinksInPath()

    nonisolated override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testSuccessfulLaunchClearsBusyStateAndPersistsLaunchDate() async throws {
        let store = try makeStore()
        let profile = try store.createProfile(name: "Launch")
        let manager = RecordingInstanceManager()
        let model = makeModel(store: store, manager: manager)

        model.launch(profile)
        await waitUntil { !model.isBusy(profile) && store.profiles.first?.lastLaunchedAt != nil }

        XCTAssertNil(model.errorMessage)
        let openedProfileIDs = await manager.openedProfileIDs()
        XCTAssertEqual(openedProfileIDs, [profile.id])
        XCTAssertNotNil(store.profiles.first?.lastLaunchedAt)
    }

    func testLaunchFailureClearsBusyStateWithoutMarkingProfile() async throws {
        let store = try makeStore()
        let profile = try store.createProfile(name: "Rejected")
        let manager = RecordingInstanceManager(openShouldFail: true)
        let model = makeModel(store: store, manager: manager)

        model.launch(profile)
        await waitUntil { !model.isBusy(profile) && model.errorMessage != nil }

        XCTAssertNil(store.profiles.first?.lastLaunchedAt)
        XCTAssertEqual(model.errorMessage, "rejected")
    }

    func testDeleteFailureRestoresIdleStateAndKeepsProfile() async throws {
        let store = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: root.appendingPathComponent("Shortcuts"),
            usageChecker: AlwaysInUseModelChecker()
        )
        let profile = try store.createProfile(name: "Busy")
        let model = makeModel(store: store)

        model.deleteProfileData(profile)
        await waitUntil { !model.storeMutationInProgress && !model.isBusy(profile) }

        XCTAssertEqual(store.profiles.map(\.id), [profile.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.profileDirectory.path))
        XCTAssertNotNil(model.errorMessage)
    }

    func testNewRefreshCannotBeOverwrittenByCancelledGeneration() async throws {
        let store = try makeStore()
        let profile = try store.createProfile(name: "Refresh")
        let scanner = SequencedStatsScanner()
        let model = makeModel(store: store, scanner: scanner)

        await waitUntil { scanner.invocationCount >= 1 }
        model.refreshStats()
        await waitUntil { model.stats(for: profile).totalSessions == 2 }
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(model.stats(for: profile).totalSessions, 2)
    }

    func testPartialRefreshDoesNotCancelRunningFullRefresh() async throws {
        let store = try makeStore()
        let first = try store.createProfile(product: .claude, name: "First")
        let second = try store.createProfile(product: .claude, name: "Second")
        let model = AgentDockModel(
            store: store,
            officialDataRootURL: root.appendingPathComponent("Official"),
            codexAppURL: URL(fileURLWithPath: "/Applications/Codex.app"),
            statsScanner: ProfileStatsScanner(),
            rateLimitClient: AppServerRateLimitClient(
                codexExecutable: URL(fileURLWithPath: "/usr/bin/false"),
                timeoutSeconds: 0.1
            ),
            claudeCodeAccounts: ClaudeCodeAccounts(store: InMemoryClaudeLoginAccounts()),
            startMonitoring: false
        )

        model.refreshStats()
        XCTAssertEqual(model.statsLoadingProfileIDs, [first.id, second.id])
        XCTAssertTrue(model.officialStatsLoading)

        // Launching a profile requests a partial refresh. It must not discard the
        // official and sibling results of the full refresh already in flight.
        model.refreshStats(for: first)

        XCTAssertEqual(model.statsLoadingProfileIDs, [first.id, second.id])
        XCTAssertTrue(model.officialStatsLoading)
        await waitUntil { model.statsLoadingProfileIDs.isEmpty && !model.officialStatsLoading }
        XCTAssertNotNil(model.lastStatsRefreshAt)
    }

    func testPartialRefreshesCoalesceWithoutDroppingEarlierProfiles() async throws {
        let store = try makeStore()
        let first = try store.createProfile(name: "First")
        let second = try store.createProfile(name: "Second")
        let model = makeModel(store: store)
        await waitUntil { model.statsLoadingProfileIDs.isEmpty && !model.officialStatsLoading }

        model.refreshStats(for: first)
        model.refreshStats(for: second)

        XCTAssertEqual(model.statsLoadingProfileIDs, [first.id, second.id])
        await waitUntil { model.statsLoadingProfileIDs.isEmpty }
    }

    func testActivityRefreshScopeSeparatesFreshStatsFromStaleQuota() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            AgentDockModel.activityRefreshScope(
                now: now,
                statsRefreshedAt: now.addingTimeInterval(-60),
                quotaRefreshedAt: nil,
                quotaAttemptedAt: now.addingTimeInterval(-61),
                refreshInterval: 5 * 60
            ),
            .quota
        )
        XCTAssertEqual(
            AgentDockModel.activityRefreshScope(
                now: now,
                statsRefreshedAt: nil,
                quotaRefreshedAt: now.addingTimeInterval(-60),
                quotaAttemptedAt: now.addingTimeInterval(-60),
                refreshInterval: 5 * 60
            ),
            .stats
        )
        XCTAssertEqual(
            AgentDockModel.activityRefreshScope(
                now: now,
                statsRefreshedAt: nil,
                quotaRefreshedAt: nil,
                quotaAttemptedAt: now.addingTimeInterval(-59),
                refreshInterval: 5 * 60
            ),
            .stats
        )
        XCTAssertEqual(
            AgentDockModel.activityRefreshScope(
                now: now,
                statsRefreshedAt: now.addingTimeInterval(-60),
                quotaRefreshedAt: nil,
                quotaAttemptedAt: now.addingTimeInterval(-59),
                refreshInterval: 5 * 60
            ),
            .none
        )
    }

    func testStoreMutationIsRejectedWhileLaunchIsInFlight() async throws {
        let store = try makeStore()
        let profile = try store.createProfile(name: "Existing")
        let manager = RecordingInstanceManager(openDelay: .milliseconds(200))
        let model = makeModel(store: store, manager: manager)

        model.launch(profile)
        let created = await model.addProfile(name: "Conflicting", color: .blue)

        XCTAssertFalse(created)
        XCTAssertEqual(store.profiles.map(\.id), [profile.id])
        XCTAssertEqual(model.errorMessage, "Another profile change is still in progress.")
        await waitUntil { !model.isBusy(profile) }
    }

    func testProfileReorderUpdatesImmediatelyAndPersists() async throws {
        let store = try makeStore()
        let first = try store.createProfile(name: "First")
        let second = try store.createProfile(name: "Second")
        let third = try store.createProfile(name: "Third")
        let model = makeModel(store: store)

        XCTAssertTrue(model.reorderProfile(
            third.id,
            relativeTo: first.id,
            placeAfter: false
        ))
        XCTAssertEqual(model.profiles.map(\.id), [third.id, first.id, second.id])

        await waitUntil { !model.storeMutationInProgress }
        XCTAssertEqual(store.profiles.map(\.id), [third.id, first.id, second.id])

        let reloaded = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: root.appendingPathComponent("Shortcuts"),
            usageChecker: NeverInUseModelChecker()
        )
        XCTAssertEqual(reloaded.profiles.map(\.id), [third.id, first.id, second.id])
    }

    func testSidebarListMovesUseInsertionIndexSemantics() async throws {
        let store = try makeStore()
        let first = try store.createProfile(name: "First")
        let second = try store.createProfile(name: "Second")
        let third = try store.createProfile(name: "Third")
        let claude = try store.createProfile(product: .claude, name: "Claude")
        let model = makeModel(store: store)

        // Dropping below the last row appends.
        model.moveProfiles(of: .codex, from: [0], to: 3)
        XCTAssertEqual(model.profiles.filter { $0.product == .codex }.map(\.id), [second.id, third.id, first.id])
        await waitUntil { !model.storeMutationInProgress }

        // The destination is the row the item is inserted before.
        model.moveProfiles(of: .codex, from: [2], to: 1)
        XCTAssertEqual(model.profiles.filter { $0.product == .codex }.map(\.id), [second.id, first.id, third.id])
        await waitUntil { !model.storeMutationInProgress }

        // Dropping an item onto its own position changes nothing.
        model.moveProfiles(of: .codex, from: [1], to: 2)
        model.moveProfiles(of: .codex, from: [1], to: 1)
        XCTAssertEqual(store.profiles.filter { $0.product == .codex }.map(\.id), [second.id, first.id, third.id])
        XCTAssertEqual(store.profiles.filter { $0.product == .claude }.map(\.id), [claude.id])
        XCTAssertNil(model.errorMessage)
    }

    func testAddProfileCompletesAndSelectsBothProducts() async throws {
        let store = try makeStore()
        let model = makeRealModel(store: store)

        let claudeCreated = await model.addProfile(
            product: .claude,
            name: "Claude Account",
            color: .purple
        )
        XCTAssertTrue(claudeCreated)
        XCTAssertEqual(model.selectedProfile?.product, .claude)
        XCTAssertEqual(model.selectedProfile?.name, "Claude Account")

        let codexCreated = await model.addProfile(
            product: .codex,
            name: "Codex Account",
            color: .blue
        )
        XCTAssertTrue(codexCreated)
        XCTAssertEqual(model.selectedProfile?.product, .codex)
        XCTAssertEqual(model.selectedProfile?.name, "Codex Account")
        XCTAssertEqual(Set(store.profiles.map(\.product)), Set(DesktopProduct.allCases))
        XCTAssertFalse(model.storeMutationInProgress)
    }

    func testRapidSecondCreateIsRejectedWhileFirstWaitsWithoutBlockingMainActor() async throws {
        let store = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: root.appendingPathComponent("Shortcuts"),
            usageChecker: NeverInUseModelChecker(),
            operationLockTimeout: .seconds(2)
        )
        let model = makeRealModel(store: store)
        var heldLock: AdvisoryFileLock? = try AdvisoryFileLock.acquireSynchronously(
            at: root.appendingPathComponent(".profiles.lock")
        )

        let firstCreate = Task { @MainActor in
            await model.addProfile(
                product: .claude,
                name: "First",
                color: .purple
            )
        }
        await waitUntil { model.storeMutationInProgress }

        var mainActorAdvanced = false
        Task { @MainActor in
            mainActorAdvanced = true
        }
        await waitUntil { mainActorAdvanced }

        let secondCreated = await model.addProfile(
            product: .claude,
            name: "Second",
            color: .orange
        )
        XCTAssertFalse(secondCreated)
        XCTAssertEqual(model.errorMessage, "Another profile change is still in progress.")

        heldLock = nil
        let firstCreated = await firstCreate.value
        XCTAssertTrue(firstCreated)
        XCTAssertEqual(store.profiles.map(\.name), ["First"])
        XCTAssertFalse(model.storeMutationInProgress)
        withExtendedLifetime(heldLock) {}
    }

    func testStoppedCodexProfileCanSelectNamedProfileUseDefaultAndReturnToBuiltIn() async throws {
        let store = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: root.appendingPathComponent("Shortcuts"),
            usageChecker: NeverInUseModelChecker()
        )
        let profile = try store.createProfile(name: "Local")
        try Data("model_provider = \"ollama\"\n".utf8).write(
            to: profile.codexHomePath.appendingPathComponent("ollama.config.toml")
        )
        let model = makeRealModel(store: store)
        let ollama = try CodexConfigProfile(validating: "ollama")

        model.setCodexLaunchProfileSelection(.named(ollama), for: profile)
        await waitUntil { !model.storeMutationInProgress }
        XCTAssertEqual(store.profiles.first?.codexLaunchProfileSelection, .named(ollama))

        model.setDefaultCodexConfigProfile(ollama, for: try XCTUnwrap(store.profiles.first))
        await waitUntil { !model.storeMutationInProgress }
        XCTAssertEqual(store.profiles.first?.codexDefaultConfigProfile, ollama)
        let selected = try XCTUnwrap(store.profiles.first)
        model.setCodexLaunchProfileSelection(.useDefault, for: selected)
        await waitUntil { !model.storeMutationInProgress }
        XCTAssertEqual(store.profiles.first?.codexLaunchProfileSelection, .useDefault)
        XCTAssertEqual(model.effectiveCodexConfigProfile(for: try XCTUnwrap(store.profiles.first)), ollama)

        let inherited = try XCTUnwrap(store.profiles.first)
        model.setCodexLaunchProfileSelection(.builtIn, for: inherited)
        await waitUntil { !model.storeMutationInProgress }
        XCTAssertEqual(store.profiles.first?.codexLaunchProfileSelection, .builtIn)
        XCTAssertNil(model.effectiveCodexConfigProfile(for: try XCTUnwrap(store.profiles.first)))
    }

    func testCancellingCreateWaitingForStoreLockLeavesNoProfileState() async throws {
        let store = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: root.appendingPathComponent("Shortcuts"),
            usageChecker: NeverInUseModelChecker(),
            operationLockTimeout: .seconds(2)
        )
        let model = makeRealModel(store: store)
        let heldLock = try AdvisoryFileLock.acquireSynchronously(
            at: root.appendingPathComponent(".profiles.lock")
        )

        let create = Task { @MainActor in
            await model.addProfile(
                product: .claude,
                name: "Cancelled",
                color: .red
            )
        }
        await waitUntil { model.storeMutationInProgress }
        create.cancel()

        let created = await create.value
        XCTAssertFalse(created)
        XCTAssertFalse(model.storeMutationInProgress)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: store.profilesRootDirectory(for: .claude),
                includingPropertiesForKeys: nil
            ).filter { !$0.lastPathComponent.hasPrefix(".") },
            []
        )
        withExtendedLifetime(heldLock) {}
    }

    func testCreateCompletesWhileRealStatsRefreshIsRunning() async throws {
        let store = try makeStore()
        let existing = try store.createProfile(product: .claude, name: "Existing")
        try Data(repeating: 0x41, count: 2 * 1_024 * 1_024).write(
            to: existing.claudeUserDataPath.appendingPathComponent("activity.bin")
        )
        let model = makeRealModel(store: store)

        model.refreshStats()
        let created = await model.addProfile(
            product: .claude,
            name: "During Refresh",
            color: .green
        )

        XCTAssertTrue(created)
        XCTAssertEqual(model.selectedProfile?.name, "During Refresh")
        XCTAssertEqual(Set(store.profiles.map(\.name)), Set(["Existing", "During Refresh"]))
        XCTAssertFalse(model.storeMutationInProgress)
    }

    func testClaudeCodeSignedOutWithoutStoredLogin() async throws {
        let store = try makeStore()
        let model = makeModel(store: store)

        await waitUntil { model.claudeCodeAccountsState == .ready }
        XCTAssertEqual(model.claudeCodeProfileIDs, [.official])
        XCTAssertEqual(model.claudeCodeUsage(for: .official).status, .signedOut(expired: false))
        XCTAssertEqual(model.claudeCodeUsage(for: .official).phase(), .signedOut)
        XCTAssertFalse(model.isClaudeSignInSheetPresented)
        XCTAssertFalse(model.isClaudeSignInSheetPresented(for: .official))
    }

    func testClaudeCodeSignOutClearsLimitsAndStoredLogin() async throws {
        let store = try makeStore()
        let tokens = ClaudeLoginTokens(
            accessToken: "synthetic-access-a",
            refreshToken: "synthetic-refresh-a",
            expiresAt: Date().addingTimeInterval(3_600),
            scopes: ["user:profile", "user:inference"],
            accountUUID: "00000000-0000-0000-0000-000000000001",
            organizationUUID: "00000000-0000-0000-0000-000000000002",
            accountLabel: "synthetic@example.invalid",
            subscriptionType: "max"
        )
        let loginStore = InMemoryClaudeLoginAccounts([tokens])
        let transport = AppScriptedClaudeTransport()
        await transport.enqueue("/api/oauth/profile", status: 200, body: #"""
        {"account":{"uuid":"00000000-0000-0000-0000-000000000001"},
         "organization":{"uuid":"00000000-0000-0000-0000-000000000002"}}
        """#)
        await transport.enqueue("/api/oauth/usage", status: 200, body: #"""
        {"five_hour":{"utilization":12.5,"resets_at":"2099-01-01T05:00:00.000Z"},
         "seven_day":{"utilization":41,"resets_at":"2099-01-07T00:00:00Z"}}
        """#)
        let suiteName = "AgentDockModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let accounts = ClaudeCodeAccounts(store: loginStore, transport: transport)
        let model = AgentDockModel(
            store: store,
            officialDataRootURL: root.appendingPathComponent("Official"),
            codexAppURL: URL(fileURLWithPath: "/Applications/Codex.app"),
            instanceController: RecordingInstanceManager(),
            shortcutInstaller: NoopShortcutManager(),
            statsScanner: FixedStatsScanner(),
            rateLimitClient: FixedRateLimitClient(),
            claudeUsageClient: ClaudeUsageClient(
                cooldowns: ClaudeUsageCooldownStore(defaults: defaults),
                transport: transport,
                claudeCodeAccounts: accounts,
                claudeCodeRequestSpacing: .zero
            ),
            claudeCodeAccounts: accounts
        )

        // The earlier account-keyed sign-in is migrated to Official Claude, the default profile.
        await waitUntil {
            let official = model.claudeCodeUsage(for: .official)
            return official.title == "synthetic@example.invalid"
                && official.status.isSignedIn
                && official.limits?.buckets.isEmpty == false
        }
        XCTAssertEqual(model.claudeCodeUsage(for: .official).phase(), .ok)

        model.signOutOfClaude(profile: .official)
        await waitUntil { model.claudeCodeUsage(for: .official).status == .signedOut(expired: false) }
        XCTAssertNil(model.claudeCodeUsage(for: .official).limits)
        XCTAssertNil(loginStore.tokens(forProfile: .official))
        XCTAssertNil(loginStore.tokens(forAccountKey: tokens.accountKey))
        XCTAssertEqual(model.claudeCodeAccountsState, .ready)
    }

    func testClaudeCodeShowsEachProfilesOwnCardAndSignOutKeepsTheOther() async throws {
        let store = try makeStore()
        let work = try store.createProfile(product: .claude, name: "Work")
        let first = ClaudeLoginTokens(
            accessToken: "synthetic-access-a",
            refreshToken: "synthetic-refresh-a",
            expiresAt: Date().addingTimeInterval(3_600),
            scopes: ["user:profile", "user:inference"],
            accountUUID: "00000000-0000-0000-0000-000000000001",
            organizationUUID: "00000000-0000-0000-0000-000000000002",
            accountLabel: "synthetic@example.invalid",
            subscriptionType: "max",
            addedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let second = ClaudeLoginTokens(
            accessToken: "synthetic-access-second",
            refreshToken: "synthetic-refresh-second",
            expiresAt: Date().addingTimeInterval(3_600),
            scopes: ["user:profile", "user:inference"],
            accountUUID: "00000000-0000-0000-0000-000000000003",
            organizationUUID: "00000000-0000-0000-0000-000000000004",
            accountLabel: "second@example.invalid",
            subscriptionType: "pro",
            customName: "Work",
            addedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let loginStore = InMemoryClaudeLoginAccounts([first, second])
        let transport = AppScriptedClaudeTransport()
        let accounts = ClaudeCodeAccounts(store: loginStore, transport: transport)
        let model = makeModel(
            store: store,
            claudeCodeAccounts: accounts,
            claudeUsageClient: try scriptedClaudeUsageClient(accounts: accounts, transport: transport)
        )

        // The sign-in named "Work" moves to the Work profile; the other one,
        // matching no profile, to Official Claude.
        let workID = ClaudeCodeProfileID.managed(work.id)
        await waitUntil {
            model.claudeCodeUsage(for: .official).status.isSignedIn
                && model.claudeCodeUsage(for: workID).status.isSignedIn
        }
        XCTAssertEqual(model.claudeCodeProfileIDs, [.official, workID])
        XCTAssertEqual(model.claudeCodeUsage(for: .official).accountKey, first.accountKey)
        XCTAssertEqual(model.claudeCodeUsage(for: workID).accountKey, second.accountKey)
        XCTAssertEqual(model.claudeCodeUsage(for: .official).title, "synthetic@example.invalid")
        XCTAssertEqual(model.claudeCodeUsage(for: workID).title, "Work")

        model.signOutOfClaude(profile: .official)
        await waitUntil { model.claudeCodeUsage(for: .official).status == .signedOut(expired: false) }
        XCTAssertEqual(model.claudeCodeUsage(for: workID).accountKey, second.accountKey)
        XCTAssertNil(loginStore.tokens(forProfile: .official))
        XCTAssertEqual(loginStore.tokens(forProfile: workID), second)

        model.renameClaudeAccount(profile: workID, to: "Personal")
        await waitUntil { model.claudeCodeUsage(for: workID).title == "Personal" }
        XCTAssertEqual(loginStore.tokens(forProfile: workID)?.customName, "Personal")
    }

    func testClaudeCodeLegacySignInAppearsWithoutSigningInAgain() async throws {
        let store = try makeStore()
        let legacy = ClaudeLoginTokens(
            accessToken: "synthetic-access-a",
            refreshToken: "synthetic-refresh-a",
            expiresAt: Date().addingTimeInterval(3_600),
            scopes: ["user:profile", "user:inference"],
            accountUUID: "00000000-0000-0000-0000-000000000001",
            organizationUUID: "00000000-0000-0000-0000-000000000002",
            accountLabel: "synthetic@example.invalid",
            subscriptionType: "max"
        )
        let loginStore = InMemoryClaudeLoginAccounts(legacy: legacy)
        let transport = AppScriptedClaudeTransport()
        let accounts = ClaudeCodeAccounts(store: loginStore, transport: transport)
        let model = makeModel(
            store: store,
            claudeCodeAccounts: accounts,
            claudeUsageClient: try scriptedClaudeUsageClient(accounts: accounts, transport: transport)
        )

        await waitUntil { model.claudeCodeUsage(for: .official).status.isSignedIn }
        XCTAssertEqual(model.claudeCodeUsage(for: .official).accountKey, legacy.accountKey)
        XCTAssertEqual(model.claudeCodeUsage(for: .official).status.isSignedIn, true)
        XCTAssertNil(loginStore.legacyTokens)
        XCTAssertEqual(loginStore.tokens(forProfile: .official)?.accessToken, legacy.accessToken)
        XCTAssertNil(loginStore.tokens(forAccountKey: legacy.accountKey))
        XCTAssertTrue(model.unplacedClaudeSignIns.isEmpty)
    }

    func testEachClaudeProfilePageExposesOnlyItsOwnSignIn() async throws {
        let store = try makeStore()
        let work = try store.createProfile(product: .claude, name: "Work")
        let personal = try store.createProfile(product: .claude, name: "Personal")
        _ = try store.createProfile(product: .codex, name: "Codex Only")
        let workID = ClaudeCodeProfileID.managed(work.id)
        let personalID = ClaudeCodeProfileID.managed(personal.id)
        let officialTokens = Self.claudeTokens(access: "synthetic-access-a", account: 1, email: "synthetic@example.invalid")
        let workTokens = Self.claudeTokens(access: "synthetic-access-work", account: 3, email: "work@example.invalid")
        let loginStore = InMemoryClaudeLoginAccounts(profiles: [.official: officialTokens, workID: workTokens])
        let transport = AppScriptedClaudeTransport()
        let accounts = ClaudeCodeAccounts(store: loginStore, transport: transport)
        let model = makeModel(
            store: store,
            claudeCodeAccounts: accounts,
            claudeUsageClient: try scriptedClaudeUsageClient(accounts: accounts, transport: transport)
        )

        await waitUntil {
            model.claudeCodeAccountsState == .ready
                && model.claudeCodeUsage(for: .official).limits != nil
                && model.claudeCodeUsage(for: workID).limits != nil
        }

        // Only Claude profiles have a page with a sign-in; Official Claude first.
        XCTAssertEqual(model.claudeCodeProfileIDs, [.official, workID, personalID])
        XCTAssertEqual(Set(model.claudeCodeUsageByProfile.keys), [.official, workID, personalID])
        // Each page shows its own sign-in and nothing from another profile.
        XCTAssertEqual(model.claudeCodeUsage(for: .official).profile, .official)
        XCTAssertEqual(model.claudeCodeUsage(for: .official).accountKey, officialTokens.accountKey)
        XCTAssertEqual(model.claudeCodeUsage(for: .official).title, "synthetic@example.invalid")
        XCTAssertEqual(model.claudeCodeUsage(for: workID).profile, workID)
        XCTAssertEqual(model.claudeCodeUsage(for: workID).accountKey, workTokens.accountKey)
        XCTAssertEqual(model.claudeCodeUsage(for: workID).title, "work@example.invalid")
        XCTAssertEqual(model.claudeCodeUsage(for: personalID).phase(), .signedOut)
        XCTAssertNil(model.claudeCodeUsage(for: personalID).account)
        // No usage requests were answered, so signed-in pages show their own error.
        if case .error = model.claudeCodeUsage(for: workID).phase() {} else {
            XCTFail("Expected the Work page to show its own fetch error")
        }
        XCTAssertEqual(model.claudeCodeProfileName(.official), "Official Claude")
        XCTAssertEqual(model.claudeCodeProfileName(workID), "Work")
        XCTAssertTrue(model.unplacedClaudeSignIns.isEmpty)
        for profile in model.claudeCodeProfileIDs {
            XCTAssertFalse(model.isClaudeSignInSheetPresented(for: profile))
        }

        // Selecting a Claude Code profile opens that profile's page.
        model.selectClaudeCodeProfile(workID)
        XCTAssertEqual(model.selectedProfileID, work.id)
        model.selectClaudeCodeProfile(.official)
        XCTAssertEqual(model.selectedOfficialProduct, .claude)
    }

    func testUnplacedEarlierSignInsAreKeptAndCanBeDiscarded() async throws {
        let store = try makeStore()
        let earlier = Self.claudeTokens(
            access: "synthetic-access-a",
            account: 1,
            email: "synthetic@example.invalid",
            addedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let later = Self.claudeTokens(
            access: "synthetic-access-later",
            account: 3,
            email: "later@example.invalid",
            addedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let loginStore = InMemoryClaudeLoginAccounts([earlier, later])
        let transport = AppScriptedClaudeTransport()
        let accounts = ClaudeCodeAccounts(store: loginStore, transport: transport)
        let model = makeModel(
            store: store,
            claudeCodeAccounts: accounts,
            claudeUsageClient: try scriptedClaudeUsageClient(accounts: accounts, transport: transport)
        )

        // Both would land on Official Claude; the earlier-added one wins.
        await waitUntil { model.claudeCodeUsage(for: .official).status.isSignedIn }
        XCTAssertEqual(model.claudeCodeUsage(for: .official).accountKey, earlier.accountKey)
        XCTAssertEqual(model.unplacedClaudeSignIns, [later.accountKey])
        XCTAssertEqual(loginStore.tokens(forAccountKey: later.accountKey), later)

        model.discardUnplacedClaudeSignIns()
        await waitUntil { model.unplacedClaudeSignIns.isEmpty }
        XCTAssertNil(loginStore.tokens(forAccountKey: later.accountKey))
        XCTAssertEqual(loginStore.tokens(forProfile: .official)?.accountUUID, earlier.accountUUID)
    }

    func testDeletingOrRemovingAProfileRemovesOnlyItsSignIn() async throws {
        let store = try makeStore()
        let work = try store.createProfile(product: .claude, name: "Work")
        let personal = try store.createProfile(product: .claude, name: "Personal")
        let workID = ClaudeCodeProfileID.managed(work.id)
        let personalID = ClaudeCodeProfileID.managed(personal.id)
        let officialTokens = Self.claudeTokens(access: "synthetic-access-a", account: 1, email: "a@example.invalid")
        let workTokens = Self.claudeTokens(access: "synthetic-access-work", account: 3, email: "work@example.invalid")
        let personalTokens = Self.claudeTokens(access: "synthetic-access-personal", account: 5, email: "p@example.invalid")
        let loginStore = InMemoryClaudeLoginAccounts(profiles: [
            .official: officialTokens,
            workID: workTokens,
            personalID: personalTokens
        ])
        let transport = AppScriptedClaudeTransport()
        let accounts = ClaudeCodeAccounts(store: loginStore, transport: transport)
        let model = makeModel(
            store: store,
            claudeCodeAccounts: accounts,
            claudeUsageClient: try scriptedClaudeUsageClient(accounts: accounts, transport: transport)
        )
        await waitUntil { model.claudeCodeUsage(for: workID).status.isSignedIn }

        model.deleteProfileData(work)
        await waitUntil {
            !model.storeMutationInProgress
                && loginStore.tokens(forProfile: workID) == nil
                && !model.claudeCodeProfileIDs.contains(workID)
        }
        XCTAssertNil(model.claudeCodeUsageByProfile[workID])
        XCTAssertEqual(loginStore.tokens(forProfile: .official), officialTokens)
        XCTAssertEqual(loginStore.tokens(forProfile: personalID), personalTokens)
        XCTAssertEqual(model.claudeCodeUsage(for: personalID).accountKey, personalTokens.accountKey)

        model.removeProfileFromList(personal)
        await waitUntil {
            !model.storeMutationInProgress
                && loginStore.tokens(forProfile: personalID) == nil
                && !model.claudeCodeProfileIDs.contains(personalID)
        }
        XCTAssertNil(model.claudeCodeUsageByProfile[personalID])
        XCTAssertEqual(loginStore.tokens(forProfile: .official), officialTokens)
        XCTAssertEqual(model.claudeCodeProfileIDs, [.official])
    }

    func testStartupRemovesTheSignInOfAProfileThatNoLongerExists() async throws {
        let store = try makeStore()
        let work = try store.createProfile(product: .claude, name: "Work")
        let missing = ClaudeCodeProfileID.managed(UUID(uuidString: "20000000-0000-0000-0000-000000000009")!)
        let workTokens = Self.claudeTokens(access: "synthetic-access-work", account: 3, email: "work@example.invalid")
        let missingTokens = Self.claudeTokens(access: "synthetic-access-gone", account: 5, email: "gone@example.invalid")
        let loginStore = InMemoryClaudeLoginAccounts(profiles: [.managed(work.id): workTokens, missing: missingTokens])
        let transport = AppScriptedClaudeTransport()
        let accounts = ClaudeCodeAccounts(store: loginStore, transport: transport)
        let model = makeModel(
            store: store,
            claudeCodeAccounts: accounts,
            claudeUsageClient: try scriptedClaudeUsageClient(accounts: accounts, transport: transport)
        )

        await waitUntil { model.claudeCodeAccountsState == .ready && loginStore.tokens(forProfile: missing) == nil }
        XCTAssertEqual(loginStore.tokens(forProfile: .managed(work.id)), workTokens)
        XCTAssertFalse(model.claudeCodeProfileIDs.contains(missing))
    }

    func testHomeShowsOneReadOnlyClaudeCodeRowPerSignedInProfile() async throws {
        let store = try makeStore()
        let work = try store.createProfile(product: .claude, name: "Work")
        let workID = ClaudeCodeProfileID.managed(work.id)
        let workTokens = Self.claudeTokens(access: "synthetic-access-work", account: 3, email: "work@example.invalid")
        let loginStore = InMemoryClaudeLoginAccounts(profiles: [workID: workTokens])
        let transport = AppScriptedClaudeTransport()
        await transport.enqueue("/api/oauth/profile", status: 200, body: #"""
        {"account":{"uuid":"00000000-0000-0000-0000-000000000003"},
         "organization":{"uuid":"00000000-0000-0000-0000-000000000004"}}
        """#)
        await transport.enqueue("/api/oauth/usage", status: 200, body: #"""
        {"five_hour":{"utilization":12.5,"resets_at":"2099-01-01T05:00:00.000Z"},
         "seven_day":{"utilization":41,"resets_at":"2099-01-07T00:00:00Z"}}
        """#)
        let accounts = ClaudeCodeAccounts(store: loginStore, transport: transport)
        let model = makeModel(
            store: store,
            claudeCodeAccounts: accounts,
            claudeUsageClient: try scriptedClaudeUsageClient(accounts: accounts, transport: transport)
        )
        await waitUntil { model.claudeCodeUsage(for: workID).limits?.buckets.isEmpty == false }

        let rows = DashboardSource.all(in: model, resets: model.resetReminders, now: Date())
            .filter { $0.kind == .claudeCode }

        // Official Claude is signed out, so only Work has a row.
        XCTAssertEqual(rows.map(\.id), ["claude-code.\(workID.storageKey)"])
        XCTAssertEqual(rows.map(\.name), ["Claude Code · Work"])
        XCTAssertEqual(rows.first?.claudeCodeProfile, workID)
        XCTAssertEqual(rows.first?.sessionWindow?.usage.usedPercent, 12.5)
        XCTAssertFalse(rows.contains { $0.countsAsAccount })

        // The row is read-only and opens the profile's page.
        let row = try XCTUnwrap(rows.first)
        DashboardSource.select(row, in: model)
        XCTAssertEqual(model.selectedProfileID, work.id)
    }

    func testSignedInProfileOffersNoSignInAndTheModelWillNotStartOne() async throws {
        let store = try makeStore()
        let work = try store.createProfile(product: .claude, name: "Work")
        let workID = ClaudeCodeProfileID.managed(work.id)
        let officialTokens = Self.claudeTokens(access: "synthetic-access-a", account: 1, email: "synthetic@example.invalid")
        let loginStore = InMemoryClaudeLoginAccounts(profiles: [.official: officialTokens])
        let transport = AppScriptedClaudeTransport()
        await transport.enqueue("/api/oauth/profile", status: 200, body: #"""
        {"account":{"uuid":"00000000-0000-0000-0000-000000000001"},
         "organization":{"uuid":"00000000-0000-0000-0000-000000000002"}}
        """#)
        await transport.enqueue("/api/oauth/usage", status: 200, body: #"""
        {"five_hour":{"utilization":12.5,"resets_at":"2099-01-01T05:00:00.000Z"},
         "seven_day":{"utilization":41,"resets_at":"2099-01-07T00:00:00Z"}}
        """#)
        let accounts = ClaudeCodeAccounts(store: loginStore, transport: transport)
        let model = makeModel(
            store: store,
            claudeCodeAccounts: accounts,
            claudeUsageClient: try scriptedClaudeUsageClient(accounts: accounts, transport: transport)
        )

        // Before sign-ins are read, no card offers controls and nothing starts.
        if model.claudeCodeAccountsState != .ready {
            for profile in model.claudeCodeProfileIDs {
                XCTAssertEqual(model.claudeCodeAccountControls(for: profile), .empty)
            }
            model.signInToClaude(profile: workID)
            let earlyState = model.claudeSignInState
            model.cancelClaudeCodeSignIn()
            XCTAssertEqual(earlyState, .idle)
        }

        await waitUntil {
            model.claudeCodeAccountsState == .ready
                && model.claudeCodeUsage(for: .official).limits?.buckets.isEmpty == false
        }
        XCTAssertEqual(model.claudeCodeCardPhase(for: .official), .ok)
        XCTAssertEqual(
            model.claudeCodeAccountControls(for: .official),
            ClaudeCodeAccountControls(rename: true, signOut: true)
        )
        XCTAssertNil(model.claudeCodeAccountControls(for: .official).signIn, "a signed-in profile has no Sign In")
        XCTAssertEqual(model.claudeCodeCardPhase(for: workID), .signedOut)
        XCTAssertEqual(model.claudeCodeAccountControls(for: workID), ClaudeCodeAccountControls(signIn: .anyAccount))

        model.signInToClaude(profile: .official)
        let state = model.claudeSignInState
        let sheetProfile = model.claudeSignInProfile
        let sheetPresented = model.isClaudeSignInSheetPresented
        // Defensive: if a sign-in had started, stop it before it opens a browser.
        model.cancelClaudeCodeSignIn()
        XCTAssertEqual(state, .idle)
        XCTAssertNil(sheetProfile)
        XCTAssertFalse(sheetPresented)

        try await Task.sleep(for: .milliseconds(50))
        let sent = await transport.requests
        XCTAssertEqual(sent.filter { $0.url?.path == "/v1/oauth/token" }.count, 0, "no sign-in was started")
        XCTAssertEqual(loginStore.tokens(forProfile: .official), officialTokens)
        XCTAssertEqual(model.claudeCodeUsage(for: .official).accountKey, officialTokens.accountKey)
    }

    func testExpiredSignInOffersSignInForTheSameAccountOnly() async throws {
        let store = try makeStore()
        let expiring = ClaudeLoginTokens(
            accessToken: "synthetic-access-a",
            refreshToken: "synthetic-refresh-a",
            expiresAt: Date().addingTimeInterval(10),
            scopes: ["user:profile", "user:inference"],
            accountUUID: "00000000-0000-0000-0000-000000000001",
            organizationUUID: "00000000-0000-0000-0000-000000000002",
            accountLabel: "synthetic@example.invalid",
            subscriptionType: "max"
        )
        let loginStore = InMemoryClaudeLoginAccounts(profiles: [.official: expiring])
        let transport = AppScriptedClaudeTransport()
        // Claude refuses the renewal, so the sign-in expires.
        await transport.enqueue("/v1/oauth/token", status: 400, body: #"{"error":"invalid_grant"}"#)
        let accounts = ClaudeCodeAccounts(store: loginStore, transport: transport)
        let model = makeModel(
            store: store,
            claudeCodeAccounts: accounts,
            claudeUsageClient: try scriptedClaudeUsageClient(accounts: accounts, transport: transport)
        )

        await waitUntil {
            model.claudeCodeCardPhase(for: .official)
                == .reauthenticationRequired(ClaudeCodeUsageMessage.signInExpired)
        }
        XCTAssertEqual(
            model.claudeCodeAccountControls(for: .official),
            ClaudeCodeAccountControls(signIn: .sameAccount, signOut: true)
        )
        XCTAssertEqual(model.claudeCodeUsage(for: .official).account?.label, "synthetic@example.invalid")
        XCTAssertNil(loginStore.tokens(forProfile: .official))
    }

    func testClaudeRowsShowUsageOnlyThroughClaudeCode() async throws {
        let store = try makeStore()
        let claudeProfile = try store.createProfile(product: .claude, name: "Claude Work")
        let codexProfile = try store.createProfile(product: .codex, name: "Codex Work")
        let model = makeModel(store: store)

        model.refreshRateLimits()
        await waitUntil {
            model.rateLimits(for: codexProfile) != nil && model.officialCodexRateLimits != nil
        }
        XCTAssertNil(model.rateLimits(for: claudeProfile), "Claude app usage is no longer read")

        let rows = DashboardSource.all(in: model, resets: model.resetReminders, now: Date())
        // Profile rows carry the model's copy of the profile, which need not
        // equal the value createProfile returned, so they are matched by ID.
        func profileRow(_ id: CodexProfile.ID) -> DashboardSource? {
            rows.first { row in
                guard case let .profile(profile) = row.kind else { return false }
                return profile.id == id
            }
        }
        let officialClaude = try XCTUnwrap(rows.first { $0.kind == .official && $0.product == .claude })
        let managedClaude = try XCTUnwrap(profileRow(claudeProfile.id))
        let officialCodex = try XCTUnwrap(rows.first { $0.kind == .official && $0.product == .codex })
        let managedCodex = try XCTUnwrap(profileRow(codexProfile.id))
        XCTAssertEqual(managedClaude.product, .claude)
        XCTAssertEqual(managedCodex.product, .codex)

        for row in [officialClaude, managedClaude] {
            XCTAssertNil(row.limits, row.name)
            XCTAssertFalse(row.readsAppUsage, row.name)
            XCTAssertTrue(row.windows.isEmpty, row.name)
        }
        for row in [officialCodex, managedCodex] {
            XCTAssertNotNil(row.limits, row.name)
            XCTAssertTrue(row.readsAppUsage, row.name)
        }
    }

    private static func claudeTokens(
        access: String,
        account: Int,
        email: String,
        addedAt: Date? = nil
    ) -> ClaudeLoginTokens {
        ClaudeLoginTokens(
            accessToken: access,
            refreshToken: "synthetic-refresh-\(account)",
            expiresAt: Date().addingTimeInterval(3_600),
            scopes: ["user:profile", "user:inference"],
            accountUUID: String(format: "00000000-0000-0000-0000-%012d", account),
            organizationUUID: String(format: "00000000-0000-0000-0000-%012d", account + 1),
            accountLabel: email,
            subscriptionType: "max",
            addedAt: addedAt
        )
    }

    func testOfficialCodexActionUsesStockInstancePath() async throws {
        let store = try makeStore()
        let manager = RecordingInstanceManager()
        let model = makeModel(store: store, manager: manager)

        model.openStockCodex()
        await waitUntil { !model.stockOperationInProgress }

        XCTAssertNil(model.errorMessage)
        let stockOpenCount = await manager.stockOpenCount()
        XCTAssertEqual(stockOpenCount, 1)
    }

    func testOfficialCodexUsesNativeProfileAndKeepsManagedDefaultsIsolated() async throws {
        let store = try makeStore()
        let managed = try store.createProfile(name: "Managed")
        let officialDataRoot = root.appendingPathComponent("Official", isDirectory: true)
        let officialHome = officialDataRoot.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: officialHome, withIntermediateDirectories: true)
        try Data(#"""
        [model_providers.ollama]
        name = "Ollama"
        base_url = "http://127.0.0.1:11434/v1"

        """#.utf8).write(to: officialHome.appendingPathComponent("config.toml"))
        try Data(#"""
        model_provider = "ollama"
        model = "local-model"
        """#.utf8).write(to: officialHome.appendingPathComponent("ollama.config.toml"))
        let suiteName = "OfficialCodexProfileSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferencesStore = AgentDockPreferencesStore(defaults: defaults)
        let manager = RecordingInstanceManager(stockRunning: true)
        let model = AgentDockModel(
            store: store,
            officialDataRootURL: officialDataRoot,
            codexAppURL: URL(fileURLWithPath: "/Applications/Codex.app"),
            instanceController: manager,
            shortcutInstaller: NoopShortcutManager(),
            statsScanner: FixedStatsScanner(),
            rateLimitClient: FixedRateLimitClient(),
            claudeCodeAccounts: ClaudeCodeAccounts(store: InMemoryClaudeLoginAccounts()),
            preferencesStore: preferencesStore
        )
        await waitUntil { !model.officialCodexConfigProfiles.isEmpty }
        let ollama = try XCTUnwrap(model.officialCodexConfigProfiles.first)

        model.openStockCodex()
        await waitUntil { !model.busyStockProducts.contains(.codex) }
        model.setOfficialCodexDefaultConfigProfile(ollama)
        await waitUntil { !model.busyStockProducts.contains(.codex) }

        XCTAssertEqual(model.effectiveOfficialCodexConfigProfile, ollama)
        XCTAssertEqual(
            preferencesStore.loadOfficialCodexProfileSettings().defaultConfigProfile,
            ollama
        )
        XCTAssertNil(store.profiles.first(where: { $0.id == managed.id })?.codexDefaultConfigProfile)
        let firstCloseCount = await manager.stockCloseCount()
        let firstOpenedProfiles = await manager.openedStockConfigProfiles()
        XCTAssertEqual(firstCloseCount, 1)
        XCTAssertEqual(firstOpenedProfiles, [nil, ollama])

        model.setOfficialCodexLaunchProfileSelection(.builtIn)
        await waitUntil { !model.busyStockProducts.contains(.codex) }

        XCTAssertNil(model.effectiveOfficialCodexConfigProfile)
        let finalCloseCount = await manager.stockCloseCount()
        let finalOpenedProfiles = await manager.openedStockConfigProfiles()
        XCTAssertEqual(finalCloseCount, 2)
        XCTAssertEqual(finalOpenedProfiles, [nil, ollama, nil])
    }

    func testClaudeSelectionAndAppPathRemainProductScoped() throws {
        let store = try makeStore()
        let profile = try store.createProfile(product: .claude, name: "Personal")
        let claudeAppURL = URL(fileURLWithPath: "/Applications/Claude Preview.app")
        let model = makeModel(store: store, claudeAppURL: claudeAppURL)

        model.selectOfficial(.claude)
        XCTAssertEqual(model.selectedOfficialProduct, .claude)
        XCTAssertNil(model.selectedProfile)
        XCTAssertEqual(model.appURL(for: .claude), claudeAppURL)
        XCTAssertEqual(
            model.appURL(for: .codex),
            URL(fileURLWithPath: "/Applications/Codex.app")
        )

        model.selectProfile(profile.id)
        XCTAssertEqual(model.selectedProfile?.id, profile.id)
        XCTAssertEqual(model.selectedProfile?.product, .claude)
        XCTAssertNil(model.rateLimits(for: profile))
    }

    func testManagedProfileSelectionPreservesAdvancedSection() throws {
        let store = try makeStore()
        let first = try store.createProfile(name: "Personal")
        let second = try store.createProfile(name: "Work")
        let model = makeModel(store: store)

        model.selectProfile(first.id)
        model.detailTab = .advanced
        model.selectProfile(second.id)

        XCTAssertEqual(model.selectedProfile?.id, second.id)
        XCTAssertEqual(model.detailTab, .advanced)
    }

    func testOverviewIsAlwaysAvailableWhileAdvancedIsProfileScoped() {
        XCTAssertEqual(
            AgentDockDetailTab.availableTabs(hasManagedProfile: false),
            [.overview]
        )
        XCTAssertEqual(
            AgentDockDetailTab.availableTabs(hasManagedProfile: true),
            [.overview, .advanced]
        )
    }

    func testOfficialSelectionFallsBackFromAdvancedAndPreservesOverview() throws {
        let store = try makeStore()
        let profile = try store.createProfile(name: "Personal")
        let model = makeModel(store: store)

        model.selectProfile(profile.id)
        model.detailTab = .advanced
        model.selectOfficial(.codex)
        XCTAssertEqual(model.detailTab, .overview)

        model.selectProfile(profile.id)
        model.selectOfficial(.claude)
        XCTAssertEqual(model.detailTab, .overview)
    }

    func testProfileEditRebuildsInstalledShortcutIconAndDisplayName() async throws {
        let store = try makeStore()
        let profile = try store.createProfile(name: "Work", iconColor: "#2563EB")
        let installer = ShortcutInstaller(
            fileManager: .default,
            helperExecutableURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        let appURL = URL(fileURLWithPath: "/Applications/Codex.app")
        try installer.installShortcut(for: profile, codexAppURL: appURL)
        let iconURL = profile.shortcutPath
            .appendingPathComponent("Contents/Resources/ProfileIcon.icns")
        let originalIcon = try Data(contentsOf: iconURL)

        let model = AgentDockModel(
            store: store,
            officialDataRootURL: root.appendingPathComponent("Official"),
            codexAppURL: appURL,
            shortcutInstaller: installer,
            claudeCodeAccounts: ClaudeCodeAccounts(store: InMemoryClaudeLoginAccounts()),
            startMonitoring: false,
            loadActivityOnInit: false
        )
        model.updateProfile(
            profile,
            name: "Day Job",
            color: Color(hex: "#F97316"),
            iconKind: .symbol,
            iconValue: "briefcase",
            customIconData: nil
        )
        await waitUntil {
            !model.storeMutationInProgress && store.profiles.first?.name == "Day Job"
        }

        let updated = try XCTUnwrap(store.profiles.first)
        XCTAssertEqual(updated.iconKind, .symbol)
        XCTAssertEqual(updated.iconValue, "briefcase")
        XCTAssertEqual(updated.iconColor, "#F97316")
        XCTAssertNotEqual(try Data(contentsOf: iconURL), originalIcon)

        let plistData = try Data(contentsOf: updated.shortcutPath.appendingPathComponent("Contents/Info.plist"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "Day Job")
    }

    private func makeStore() throws -> ProfileStore {
        try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: root.appendingPathComponent("Shortcuts"),
            usageChecker: NeverInUseModelChecker()
        )
    }

    private func makeModel(
        store: ProfileStore,
        claudeAppURL: URL = DesktopAppRegistry.claude.defaultAppURL,
        manager: any DesktopInstanceManaging = RecordingInstanceManager(),
        scanner: any ProfileStatsScanning = FixedStatsScanner(),
        claudeCodeAccounts: ClaudeCodeAccounts = ClaudeCodeAccounts(store: InMemoryClaudeLoginAccounts()),
        claudeUsageClient: (any ClaudeUsageFetching)? = nil
    ) -> AgentDockModel {
        AgentDockModel(
            store: store,
            officialDataRootURL: root.appendingPathComponent("Official"),
            codexAppURL: URL(fileURLWithPath: "/Applications/Codex.app"),
            claudeAppURL: claudeAppURL,
            instanceController: manager,
            shortcutInstaller: NoopShortcutManager(),
            statsScanner: scanner,
            rateLimitClient: FixedRateLimitClient(),
            claudeUsageClient: claudeUsageClient,
            claudeCodeAccounts: claudeCodeAccounts
        )
    }

    /// A usage client that sends nothing off the machine and keeps its
    /// cooldowns in a throwaway defaults suite.
    private func scriptedClaudeUsageClient(
        accounts: ClaudeCodeAccounts,
        transport: AppScriptedClaudeTransport
    ) throws -> ClaudeUsageClient {
        let suiteName = "AgentDockModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        return ClaudeUsageClient(
            cooldowns: ClaudeUsageCooldownStore(defaults: defaults),
            transport: transport,
            claudeCodeAccounts: accounts,
            claudeCodeRequestSpacing: .zero
        )
    }

    private func makeRealModel(store: ProfileStore) -> AgentDockModel {
        AgentDockModel(
            store: store,
            officialDataRootURL: root.appendingPathComponent("Official"),
            codexAppURL: URL(fileURLWithPath: "/Applications/Codex.app"),
            claudeAppURL: URL(fileURLWithPath: "/Applications/Claude.app"),
            instanceController: DesktopInstanceController(),
            shortcutInstaller: ShortcutInstaller(),
            statsScanner: ProfileStatsScanner(),
            rateLimitClient: AppServerRateLimitClient(),
            claudeCodeAccounts: ClaudeCodeAccounts(store: InMemoryClaudeLoginAccounts()),
            startMonitoring: false,
            loadActivityOnInit: false
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }
}

private actor RecordingInstanceManager: DesktopInstanceManaging {
    private let openShouldFail: Bool
    private let openDelay: Duration?
    private var opened: [CodexProfile.ID] = []
    private var stockOpens = 0
    private var stockCloses = 0
    private var stockConfigProfiles: [CodexConfigProfile?] = []
    private let stockRunning: Bool

    init(
        openShouldFail: Bool = false,
        openDelay: Duration? = nil,
        stockRunning: Bool = false
    ) {
        self.openShouldFail = openShouldFail
        self.openDelay = openDelay
        self.stockRunning = stockRunning
    }

    func statuses(
        for profiles: [CodexProfile],
        appURLs _: [DesktopProduct: URL]
    ) async throws -> [CodexProfile.ID: CodexInstanceStatus] {
        Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, CodexInstanceStatus()) })
    }

    func open(profile: CodexProfile, appURL _: URL) async throws -> CodexOpenOutcome {
        opened.append(profile.id)
        if let openDelay {
            try await Task.sleep(for: openDelay)
        }
        if openShouldFail {
            throw TestFailure.rejected
        }
        return .launched(processID: 123)
    }

    func close(profile _: CodexProfile, appURL _: URL) async throws -> CodexCloseOutcome {
        .alreadyStopped
    }

    func stockStatus(
        product _: DesktopProduct,
        appURL _: URL
    ) async throws -> CodexInstanceStatus {
        CodexInstanceStatus(processIDs: stockRunning ? [456] : [])
    }

    func openStock(
        product _: DesktopProduct,
        appURL _: URL,
        codexHomeURL _: URL?,
        codexConfigProfile: CodexConfigProfile?
    ) async throws -> CodexOpenOutcome {
        stockOpens += 1
        stockConfigProfiles.append(codexConfigProfile)
        return .launched(processID: 456)
    }

    func closeOfficialCodex(appURL _: URL) async throws -> CodexCloseOutcome {
        stockCloses += 1
        return .closed(processIDs: [456])
    }

    func validateApp(product _: DesktopProduct, at _: URL) async throws {}

    func openedProfileIDs() -> [CodexProfile.ID] {
        opened
    }

    func stockOpenCount() -> Int {
        stockOpens
    }

    func stockCloseCount() -> Int {
        stockCloses
    }

    func openedStockConfigProfiles() -> [CodexConfigProfile?] {
        stockConfigProfiles
    }
}

private final class SequencedStatsScanner: ProfileStatsScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var invocation = 0

    var invocationCount: Int {
        lock.withLock { invocation }
    }

    func stats(for _: CodexProfile, now _: Date) -> ProfileStats {
        let current = lock.withLock {
            invocation += 1
            return invocation
        }
        if current == 1 {
            Thread.sleep(forTimeInterval: 0.15)
        }
        var stats = ProfileStats.empty
        stats.totalSessions = current
        return stats
    }

    func stats(codexHomeURL _: URL, dataRootURL _: URL, now _: Date) -> ProfileStats {
        .empty
    }

    func stats(
        claudeUserDataURL _: URL,
        claudeCodeHomeURL _: URL,
        dataRootURL _: URL,
        now _: Date
    ) -> ProfileStats { .empty }
}

private struct FixedStatsScanner: ProfileStatsScanning {
    func stats(for _: CodexProfile, now _: Date) -> ProfileStats { .empty }
    func stats(codexHomeURL _: URL, dataRootURL _: URL, now _: Date) -> ProfileStats { .empty }
    func stats(
        claudeUserDataURL _: URL,
        claudeCodeHomeURL _: URL,
        dataRootURL _: URL,
        now _: Date
    ) -> ProfileStats { .empty }
}

private struct FixedRateLimitClient: ProfileRateLimitFetching {
    func fetchRateLimits(for _: CodexProfile, codexAppURL _: URL) -> ProfileRateLimits {
        ProfileRateLimits()
    }

    func fetchRateLimits(codexHomeURL _: URL, codexAppURL _: URL) -> ProfileRateLimits {
        ProfileRateLimits()
    }
}

private struct NoopShortcutManager: ShortcutManaging {
    func installShortcut(for _: CodexProfile, codexAppURL _: URL) throws {}
    func removeShortcut(for _: CodexProfile) throws {}
    func shortcutExists(for _: CodexProfile) -> Bool { false }
}

private struct NeverInUseModelChecker: ProfileUsageChecking {
    func isProfileInUse(_: CodexProfile) -> Bool { false }
}

private struct AlwaysInUseModelChecker: ProfileUsageChecking {
    func isProfileInUse(_: CodexProfile) -> Bool { true }
}

private enum TestFailure: LocalizedError {
    case rejected

    var errorDescription: String? { "rejected" }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
