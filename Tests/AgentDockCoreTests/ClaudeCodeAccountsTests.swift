import Foundation
import XCTest
@testable import AgentDockCore

/// One Claude Code sign-in per AgentDock profile, over the in-memory store and
/// the scripted transport; sign-ins run the real PKCE flow with a pasted
/// code, so nothing leaves the process and no Keychain is touched.
final class ClaudeCodeAccountsTests: XCTestCase {
    private typealias Fixture = ClaudeLoginFixture
    private let tokenPath = ScriptedClaudeTransport.tokenPath
    private let profilePath = ScriptedClaudeTransport.profilePath

    // MARK: - One sign-in per profile

    func testSigningInTwoProfilesStoresSeparateItemsAndListsEachOnItsOwnProfile() async throws {
        let store = InMemoryClaudeLoginAccounts()
        let transport = ScriptedClaudeTransport()
        let accounts = ClaudeCodeAccounts(store: store, transport: transport)

        let first = try await signIn(accounts, transport, profile: .official, access: "synthetic-access-a")
        let second = try await signIn(
            accounts,
            transport,
            profile: Fixture.work,
            access: "synthetic-access-second",
            account: Fixture.secondAccount,
            organization: Fixture.secondOrganization,
            email: Fixture.secondEmail
        )

        XCTAssertEqual(first.profile, .official)
        XCTAssertEqual(second.profile, Fixture.work)
        XCTAssertEqual(first.accountKey, Fixture.accountKey)
        XCTAssertEqual(second.accountKey, Fixture.secondAccountKey)
        XCTAssertNotEqual(first.accountKey, second.accountKey)
        let firstKey = try XCTUnwrap(first.accountKey)
        XCTAssertTrue(ClaudeLoginAccountKey.isValid(firstKey))
        XCTAssertFalse(firstKey.contains(Fixture.account))
        XCTAssertFalse(Fixture.work.storageKey.contains(Fixture.account), "item names carry no account identifiers")
        XCTAssertEqual(first.status, .signedIn(try XCTUnwrap(first.account)))
        XCTAssertEqual(first.account?.label, Fixture.email)
        XCTAssertEqual(first.account?.subscriptionType, "max")
        XCTAssertNotNil(first.account?.addedAt)

        XCTAssertEqual(Set(store.storedProfileIDs), [.official, Fixture.work])
        XCTAssertEqual(store.tokens(.profile(.official))?.accessToken, "synthetic-access-a")
        XCTAssertEqual(store.tokens(.profile(Fixture.work))?.accessToken, "synthetic-access-second")
        XCTAssertTrue(store.storedAccountKeys.isEmpty, "sign-ins are stored per profile only")
        XCTAssertNil(store.tokens(.legacy))

        let listing = await accounts.list(profiles: [.official, Fixture.work, Fixture.personal])
        XCTAssertFalse(listing.keychainAccessRequired)
        XCTAssertEqual(listing.accounts.map(\.profile), [.official, Fixture.work, Fixture.personal])
        XCTAssertEqual(listing.accounts.map(\.title), [Fixture.email, Fixture.secondEmail, "Claude account"])
        XCTAssertEqual(listing.accounts.map(\.accountKey), [Fixture.accountKey, Fixture.secondAccountKey, nil])
        XCTAssertEqual(listing.accounts.map(\.status.isSignedIn), [true, true, false])
        XCTAssertEqual(listing.accounts[2].status, .signedOut(expired: false))
        XCTAssertEqual(listing.accounts[2].phase(), .signedOut)
        XCTAssertTrue(listing.accounts.allSatisfy { $0.limits == nil })
    }

    func testSigningInAgainReplacesOnlyThatProfilesItemAndKeepsTheSameAccountsName() async throws {
        let other = Fixture.secondTokens()
        let store = InMemoryClaudeLoginAccounts(profiles: [Fixture.work: other])
        let transport = ScriptedClaudeTransport()
        let accounts = ClaudeCodeAccounts(store: store, transport: transport)
        let first = try await signIn(accounts, transport, profile: .official, access: "synthetic-access-a")
        let addedAt = try XCTUnwrap(first.account?.addedAt)
        _ = try await accounts.rename(profile: .official, to: "Work")

        let again = try await signIn(accounts, transport, profile: .official, access: "synthetic-access-b")

        XCTAssertEqual(again.profile, .official)
        XCTAssertEqual(again.accountKey, first.accountKey)
        XCTAssertEqual(again.account?.customName, "Work")
        XCTAssertEqual(again.account?.addedAt, addedAt)
        XCTAssertEqual(again.title, "Work")
        XCTAssertEqual(Set(store.storedProfileIDs), [.official, Fixture.work], "no duplicate item")
        let stored = try XCTUnwrap(store.tokens(.profile(.official)))
        XCTAssertEqual(stored.accessToken, "synthetic-access-b")
        XCTAssertEqual(stored.customName, "Work")
        XCTAssertEqual(store.tokens(.profile(Fixture.work)), other, "another profile's sign-in is untouched")
        XCTAssertEqual(store.saveCount(.profile(Fixture.work)), 0)

        let listing = await accounts.list(profiles: [.official])
        XCTAssertEqual(listing.accounts.map(\.profile), [.official])
        XCTAssertEqual(listing.accounts.first?.title, "Work")
    }

    func testSigningInWithAnotherAccountReplacesTheProfilesAccountAndDropsItsName() async throws {
        let store = InMemoryClaudeLoginAccounts()
        let transport = ScriptedClaudeTransport()
        let accounts = ClaudeCodeAccounts(store: store, transport: transport)
        _ = try await signIn(accounts, transport, profile: Fixture.work, access: "synthetic-access-a")
        _ = try await accounts.rename(profile: Fixture.work, to: "Old name")

        let switched = try await signIn(
            accounts,
            transport,
            profile: Fixture.work,
            access: "synthetic-access-second",
            account: Fixture.secondAccount,
            organization: Fixture.secondOrganization,
            email: Fixture.secondEmail
        )

        XCTAssertEqual(switched.accountKey, Fixture.secondAccountKey)
        XCTAssertNil(switched.account?.customName, "another account's name does not carry over")
        XCTAssertEqual(switched.title, Fixture.secondEmail)
        XCTAssertEqual(store.storedProfileIDs, [Fixture.work], "exactly one sign-in for the profile")
        XCTAssertEqual(store.tokens(.profile(Fixture.work))?.accountUUID, Fixture.secondAccount)
        XCTAssertNil(store.tokens(.profile(Fixture.work))?.customName)
    }

    func testRenameChangesOnlyThatProfileAndEmptyNameRestoresEmail() async throws {
        let first = Fixture.tokens()
        let second = Fixture.secondTokens()
        let store = InMemoryClaudeLoginAccounts(profiles: [.official: first, Fixture.work: second])
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())
        _ = await accounts.list(profiles: [.official, Fixture.work])

        let renamed = try await accounts.rename(profile: .official, to: "  Personal  ")
        XCTAssertEqual(renamed.customName, "Personal")
        XCTAssertEqual(renamed.displayName, "Personal")
        XCTAssertEqual(renamed.label, Fixture.email)
        XCTAssertEqual(store.tokens(.profile(.official))?.customName, "Personal")
        XCTAssertEqual(store.tokens(.profile(.official))?.accessToken, first.accessToken)
        XCTAssertEqual(store.tokens(.profile(Fixture.work)), second)
        XCTAssertEqual(store.saveCount(.profile(Fixture.work)), 0)

        let long = String(repeating: "n", count: 200)
        let clipped = try await accounts.rename(profile: .official, to: long)
        XCTAssertEqual(clipped.customName?.count, ClaudeLoginTokens.maximumCustomNameLength)

        let cleared = try await accounts.rename(profile: .official, to: "   ")
        XCTAssertNil(cleared.customName)
        XCTAssertEqual(cleared.displayName, Fixture.email)
        XCTAssertNil(store.tokens(.profile(.official))?.customName)

        do {
            _ = try await accounts.rename(profile: Fixture.personal, to: "Missing")
            XCTFail("Renaming a profile without a sign-in should fail")
        } catch {
            XCTAssertEqual(error as Any as? ClaudeSignInError, .accountNotFound)
        }
    }

    func testSignOutDeletesOnlyThatProfilesItem() async throws {
        let first = Fixture.tokens()
        let second = Fixture.secondTokens()
        let store = InMemoryClaudeLoginAccounts(profiles: [.official: first, Fixture.work: second])
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())
        _ = await accounts.list(profiles: [.official, Fixture.work])

        try await accounts.signOut(profile: .official)

        XCTAssertNil(store.tokens(.profile(.official)))
        XCTAssertEqual(store.tokens(.profile(Fixture.work)), second)
        XCTAssertEqual(store.deleteCount(.profile(.official)), 1)
        XCTAssertEqual(store.deleteCount(.profile(Fixture.work)), 0)
        let listing = await accounts.list(profiles: [.official, Fixture.work])
        XCTAssertEqual(listing.accounts.map(\.profile), [.official, Fixture.work])
        XCTAssertEqual(listing.accounts[0].status, .signedOut(expired: false))
        XCTAssertNil(listing.accounts[0].account, "a signed-out profile remembers no account")
        XCTAssertEqual(listing.accounts[1].status.isSignedIn, true)
    }

    func testTwoProfilesOnTheSameAccountAreIndependent() async throws {
        let onOfficial = Fixture.tokens(access: "synthetic-access-official")
        let onWork = Fixture.tokens(access: "synthetic-access-work")
        let store = InMemoryClaudeLoginAccounts(profiles: [.official: onOfficial, Fixture.work: onWork])
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())

        try await accounts.signOut(profile: .official)

        XCTAssertNil(store.tokens(.profile(.official)))
        XCTAssertEqual(store.tokens(.profile(Fixture.work)), onWork)
        let listing = await accounts.list(profiles: [.official, Fixture.work])
        XCTAssertEqual(listing.accounts.map(\.status.isSignedIn), [false, true])
        XCTAssertEqual(listing.accounts[1].accountKey, Fixture.accountKey)
    }

    func testRefusedRenewalKeepsAnExpiredCardForOnlyThatProfile() async throws {
        let now = Date()
        let first = Fixture.tokens(expiresAt: now.addingTimeInterval(10))
        let second = Fixture.secondTokens()
        let store = InMemoryClaudeLoginAccounts(profiles: [.official: first, Fixture.work: second])
        let transport = ScriptedClaudeTransport()
        await transport.enqueue(tokenPath, Fixture.errorReply(400, "invalid_grant"))
        let accounts = ClaudeCodeAccounts(store: store, transport: transport)
        let entries = await accounts.entries(for: [.official, Fixture.work])
        let login = try XCTUnwrap(entries.first { $0.profile == .official }?.login)

        let outcome = await login.usableTokens(allowKeychainInteraction: false, now: now)
        XCTAssertEqual(outcome, .signedOut(expired: true))

        XCTAssertNil(store.tokens(.profile(.official)))
        XCTAssertEqual(store.tokens(.profile(Fixture.work)), second)
        let listing = await accounts.list(profiles: [.official, Fixture.work])
        let expired = listing.accounts[0]
        XCTAssertEqual(expired.status, .signedOut(expired: true))
        XCTAssertEqual(expired.title, Fixture.email, "the card keeps its label to ask for a new sign-in")
        XCTAssertEqual(expired.phase(), .reauthenticationRequired(ClaudeCodeUsageMessage.signInExpired))
        XCTAssertEqual(listing.accounts[1].status.isSignedIn, true)

        // Signing out of the expired card succeeds even though its item is already gone.
        try await accounts.signOut(profile: .official)
        let afterSignOut = await accounts.list(profiles: [.official, Fixture.work])
        XCTAssertEqual(afterSignOut.accounts[0].phase(), .signedOut)
        XCTAssertEqual(afterSignOut.accounts[1].status.isSignedIn, true)
    }

    func testOneUnreadableProfileDoesNotHideOthers() async throws {
        let second = Fixture.secondTokens()
        let store = InMemoryClaudeLoginAccounts(profiles: [.official: Fixture.thirdTokens(), Fixture.work: second])
        store.failNextLoad(.profile(.official), with: .unreadable)
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())

        let listing = await accounts.list(profiles: [.official, Fixture.work])

        let unreadable = listing.accounts[0]
        XCTAssertEqual(unreadable.status, .signedOut(expired: false))
        XCTAssertTrue(unreadable.signInUnreadable)
        XCTAssertNil(unreadable.account)
        XCTAssertEqual(unreadable.phase(), .reauthenticationRequired(ClaudeCodeUsageMessage.unreadableSignIn))
        XCTAssertEqual(listing.accounts[1].status.isSignedIn, true)
        XCTAssertFalse(listing.accounts[1].signInUnreadable)
    }

    func testListingNeedsKeychainAccessForOneProfileKeepsOthers() async throws {
        let store = InMemoryClaudeLoginAccounts(
            profiles: [.official: Fixture.tokens(), Fixture.work: Fixture.secondTokens()]
        )
        store.failNextLoad(.profile(.official), with: .interactionRequired)
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())

        let blocked = await accounts.list(profiles: [.official, Fixture.work])

        XCTAssertTrue(blocked.keychainAccessRequired)
        XCTAssertEqual(blocked.accounts[0].status, .keychainAccessRequired)
        XCTAssertEqual(blocked.accounts[0].phase(), .keychainAccessRequired)
        XCTAssertEqual(blocked.accounts[1].status.isSignedIn, true)

        let allowed = await accounts.list(profiles: [.official, Fixture.work], allowKeychainInteraction: true)
        XCTAssertFalse(allowed.keychainAccessRequired)
        XCTAssertEqual(allowed.accounts.map(\.status.isSignedIn), [true, true])
    }

    func testRenewalWritesBackOnlyToItsOwnProfile() async throws {
        let now = Date()
        let first = Fixture.tokens(expiresAt: now.addingTimeInterval(10))
        let second = Fixture.secondTokens()
        let store = InMemoryClaudeLoginAccounts(profiles: [.official: first, Fixture.work: second])
        let transport = ScriptedClaudeTransport()
        await transport.enqueue(tokenPath, Fixture.tokenReply(access: "synthetic-access-renewed"))
        let accounts = ClaudeCodeAccounts(store: store, transport: transport)
        let entries = await accounts.entries(for: [.official, Fixture.work])
        let login = try XCTUnwrap(entries.first { $0.profile == .official }?.login)

        let outcome = await login.usableTokens(allowKeychainInteraction: false, now: now)

        guard case let .tokens(renewed) = outcome else { return XCTFail("Expected tokens, got \(outcome)") }
        XCTAssertEqual(renewed.accessToken, "synthetic-access-renewed")
        XCTAssertEqual(store.tokens(.profile(.official))?.accessToken, "synthetic-access-renewed")
        XCTAssertEqual(store.tokens(.profile(Fixture.work)), second)
        XCTAssertEqual(store.saveCount(.profile(Fixture.work)), 0)
        XCTAssertEqual(store.saveCount(.legacy), 0)
        XCTAssertTrue(store.storedAccountKeys.isEmpty)
    }

    func testRemovingSignInsOfMissingProfilesKeepsEveryOtherProfile() async throws {
        let onWork = Fixture.secondTokens()
        let store = InMemoryClaudeLoginAccounts(profiles: [
            .official: Fixture.tokens(),
            Fixture.work: onWork,
            Fixture.personal: Fixture.thirdTokens()
        ])
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())

        let removed = await accounts.removeSignIns(keeping: [.official, Fixture.work])

        XCTAssertTrue(removed)
        XCTAssertEqual(store.storedProfileIDs, [.official, Fixture.work].sorted { $0.storageKey < $1.storageKey })
        XCTAssertEqual(store.tokens(.profile(Fixture.work)), onWork)

        // Official Claude is never treated as a missing profile.
        await accounts.removeSignIns(keeping: [])
        XCTAssertEqual(store.storedProfileIDs, [.official])
    }

    func testProfileStorageKeysRoundTripAndRejectOtherForms() {
        XCTAssertEqual(ClaudeCodeProfileID.official.storageKey, "official")
        XCTAssertEqual(Fixture.work.storageKey, "10000000-0000-0000-0000-000000000001")
        XCTAssertEqual(ClaudeCodeProfileID(storageKey: "official"), .official)
        XCTAssertEqual(ClaudeCodeProfileID(storageKey: Fixture.work.storageKey), Fixture.work)
        XCTAssertNil(ClaudeCodeProfileID(storageKey: "OFFICIAL"))
        XCTAssertNil(ClaudeCodeProfileID(storageKey: Fixture.workProfileID.uuidString.uppercased() + "X"))
        XCTAssertNil(ClaudeCodeProfileID(storageKey: "10000000-0000-0000-0000-00000000000A"))
        XCTAssertNil(ClaudeCodeProfileID(storageKey: Fixture.accountKey))
    }

    // MARK: - Card states

    func testPhaseCoversEveryCardState() {
        let now = Date()
        let account = ClaudeLoginAccount(label: Fixture.email, subscriptionType: "max")
        let windows = [RateLimitBucket(
            id: "claude",
            name: "Claude",
            primary: RateLimitWindowUsage(usedPercent: 10, windowDurationMins: 300, resetsAt: nil),
            secondary: nil
        )]
        func signedIn(
            _ limits: ProfileRateLimits?,
            until: Date? = nil
        ) -> ClaudeCodeAccountUsage {
            ClaudeCodeAccountUsage(
                profile: Fixture.work,
                accountKey: Fixture.accountKey,
                account: account,
                status: .signedIn(account),
                limits: limits,
                rateLimitedUntil: until
            )
        }
        let later = now.addingTimeInterval(600)

        XCTAssertEqual(ClaudeCodeAccountUsage.checking(.official).phase(now: now), .checking)
        XCTAssertEqual(
            ClaudeCodeAccountUsage(profile: .official, account: nil, status: .keychainAccessRequired).phase(now: now),
            .keychainAccessRequired
        )
        XCTAssertEqual(
            ClaudeCodeAccountUsage(profile: .official, account: nil, status: .signedOut(expired: false)).phase(now: now),
            .signedOut
        )
        XCTAssertEqual(
            ClaudeCodeAccountUsage(profile: .official, account: account, status: .signedOut(expired: true)).phase(now: now),
            .reauthenticationRequired(ClaudeCodeUsageMessage.signInExpired)
        )
        XCTAssertEqual(
            ClaudeCodeAccountUsage(
                profile: .official,
                account: nil,
                status: .signedOut(expired: false),
                signInUnreadable: true
            ).phase(now: now),
            .reauthenticationRequired(ClaudeCodeUsageMessage.unreadableSignIn)
        )
        XCTAssertEqual(signedIn(nil).phase(now: now), .loading)
        XCTAssertEqual(signedIn(ProfileRateLimits(planType: "max", buckets: windows)).phase(now: now), .ok)
        XCTAssertEqual(
            signedIn(ProfileRateLimits(errorMessage: ClaudeCodeUsageMessage.identityMismatch)).phase(now: now),
            .reauthenticationRequired(ClaudeCodeUsageMessage.identityMismatch)
        )
        XCTAssertEqual(
            signedIn(ProfileRateLimits(errorMessage: ClaudeCodeUsageMessage.keychainAccessRequired)).phase(now: now),
            .keychainAccessRequired
        )
        XCTAssertEqual(
            signedIn(ProfileRateLimits(errorMessage: "Live usage is rate limited. Try again later."), until: later)
                .phase(now: now),
            .rateLimited(until: later)
        )
        XCTAssertEqual(
            signedIn(ProfileRateLimits(errorMessage: ClaudeUsageClient.budgetError), until: later).phase(now: now),
            .budgetExhausted(until: later)
        )
        XCTAssertEqual(
            signedIn(
                ProfileRateLimits(buckets: windows, warningMessage: ClaudeUsageClient.budgetWarning),
                until: later
            ).phase(now: now),
            .budgetExhausted(until: later)
        )
        XCTAssertEqual(
            signedIn(ProfileRateLimits(errorMessage: "Live usage request failed (HTTP 500).")).phase(now: now),
            .error("Live usage request failed (HTTP 500).")
        )
        XCTAssertEqual(
            signedIn(ProfileRateLimits(buckets: windows), until: now.addingTimeInterval(-1)).phase(now: now),
            .ok,
            "an ended cooldown is not shown"
        )
    }

    // MARK: - Migrating earlier sign-ins onto profiles

    func testMigratesLegacyItemToTheDefaultProfileWithoutSigningIn() async throws {
        let legacy = Fixture.tokens()
        let store = InMemoryClaudeLoginAccounts(legacy: legacy)
        let transport = ScriptedClaudeTransport()
        let accounts = ClaudeCodeAccounts(store: store, transport: transport)

        let result = await accounts.migrateEarlierSignIns(to: targets())

        XCTAssertEqual(result, ClaudeCodeMigrationResult(outcome: .complete, placed: [.official: legacy.accountKey]))
        XCTAssertNil(store.tokens(.legacy))
        let migrated = try XCTUnwrap(store.tokens(.profile(.official)))
        XCTAssertEqual(migrated.accessToken, legacy.accessToken)
        XCTAssertEqual(migrated.refreshToken, legacy.refreshToken)
        XCTAssertEqual(migrated.accountUUID, legacy.accountUUID)
        XCTAssertEqual(migrated.organizationUUID, legacy.organizationUUID)
        XCTAssertNotNil(migrated.addedAt)
        XCTAssertTrue(store.storedAccountKeys.isEmpty)
        let listing = await accounts.list(profiles: [.official, Fixture.work])
        XCTAssertEqual(listing.accounts[0].status.isSignedIn, true)
        XCTAssertEqual(listing.accounts[0].title, Fixture.email)
        XCTAssertEqual(listing.accounts[1].status, .signedOut(expired: false))
        let requests = await transport.requests.count
        XCTAssertEqual(requests, 0, "migration needs no network request")
    }

    func testKeyedSignInsMoveToTheProfileTheyMatchByNameOrEmail() async throws {
        var named = Fixture.tokens()
        named.customName = " work "
        let byEmail = Fixture.secondTokens()
        let store = InMemoryClaudeLoginAccounts(accounts: [named, byEmail])
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())

        let result = await accounts.migrateEarlierSignIns(
            to: targets(work: "Work", personal: "SECOND@example.invalid")
        )

        XCTAssertEqual(result.outcome, .complete)
        XCTAssertEqual(result.placed, [Fixture.work: named.accountKey, Fixture.personal: byEmail.accountKey])
        XCTAssertTrue(result.unplacedAccountKeys.isEmpty)
        XCTAssertEqual(store.tokens(.profile(Fixture.work))?.accessToken, named.accessToken)
        XCTAssertEqual(store.tokens(.profile(Fixture.work))?.customName, " work ")
        XCTAssertEqual(store.tokens(.profile(Fixture.personal))?.accessToken, byEmail.accessToken)
        XCTAssertNil(store.tokens(.profile(.official)), "a matched sign-in never lands on the default profile")
        XCTAssertTrue(store.storedAccountKeys.isEmpty)
    }

    func testUnmatchedSignInFallsBackToTheDefaultProfile() async throws {
        let unmatched = Fixture.thirdTokens()
        let store = InMemoryClaudeLoginAccounts(accounts: [unmatched])
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())

        let result = await accounts.migrateEarlierSignIns(to: targets())

        XCTAssertEqual(result, ClaudeCodeMigrationResult(outcome: .complete, placed: [.official: unmatched.accountKey]))
        XCTAssertEqual(store.tokens(.profile(.official))?.accessToken, unmatched.accessToken)
        XCTAssertNil(store.tokens(.profile(Fixture.work)))
        XCTAssertNil(store.tokens(.account(unmatched.accountKey)))
    }

    func testMatchingUsesOnlyAgentDockNamesAndEmailsInProfileOrder() {
        var tokens = Fixture.tokens()
        let ordered = [
            ClaudeCodeMigrationTarget(profile: .official, name: Fixture.email),
            ClaudeCodeMigrationTarget(profile: Fixture.work, name: Fixture.email.uppercased()),
            ClaudeCodeMigrationTarget(profile: Fixture.personal, name: Fixture.email)
        ]
        // Official Claude is never matched by name; the first managed match wins.
        XCTAssertEqual(ClaudeCodeAccounts.matchingProfile(for: tokens, in: ordered), Fixture.work)

        // The AgentDock name wins over the email.
        tokens.customName = "Personal"
        let named = [
            ClaudeCodeMigrationTarget(profile: Fixture.work, name: Fixture.email),
            ClaudeCodeMigrationTarget(profile: Fixture.personal, name: "personal")
        ]
        XCTAssertEqual(ClaudeCodeAccounts.matchingProfile(for: tokens, in: named), Fixture.personal)

        // Nothing similar enough matches; empty names never match.
        tokens.customName = "   "
        let unrelated = [
            ClaudeCodeMigrationTarget(profile: Fixture.work, name: "synthetic"),
            ClaudeCodeMigrationTarget(profile: Fixture.personal, name: "")
        ]
        XCTAssertNil(ClaudeCodeAccounts.matchingProfile(for: tokens, in: unrelated))
    }

    func testTwoSignInsForOneProfileKeepTheEarliestAndLeaveTheOtherInPlace() async throws {
        // Neither matches a managed profile, so both would land on Official Claude.
        let earlier = Fixture.secondTokens()
        let later = Fixture.thirdTokens()
        let store = InMemoryClaudeLoginAccounts(accounts: [later, earlier])
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())

        let result = await accounts.migrateEarlierSignIns(to: targets())

        XCTAssertEqual(result.outcome, .complete)
        XCTAssertEqual(result.placed, [.official: earlier.accountKey])
        XCTAssertEqual(result.unplacedAccountKeys, [later.accountKey])
        XCTAssertEqual(store.tokens(.profile(.official))?.accessToken, earlier.accessToken)
        XCTAssertNil(store.tokens(.account(earlier.accountKey)))
        XCTAssertEqual(store.tokens(.account(later.accountKey)), later, "the other sign-in is kept, not deleted")
        XCTAssertEqual(store.deleteCount(.account(later.accountKey)), 0)

        // Running it again changes nothing.
        let before = store.snapshot
        let again = await accounts.migrateEarlierSignIns(to: targets())
        XCTAssertEqual(again, ClaudeCodeMigrationResult(outcome: .complete, unplacedAccountKeys: [later.accountKey]))
        XCTAssertEqual(store.snapshot, before)

        // A profile named after the kept sign-in takes it on a later launch.
        let relaunched = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())
        let placedLater = await relaunched.migrateEarlierSignIns(to: targets(personal: Fixture.thirdEmail))
        XCTAssertEqual(placedLater, ClaudeCodeMigrationResult(
            outcome: .complete,
            placed: [Fixture.personal: later.accountKey]
        ))
        XCTAssertEqual(store.tokens(.profile(Fixture.personal))?.accessToken, later.accessToken)
        XCTAssertEqual(store.tokens(.profile(.official))?.accessToken, earlier.accessToken)
        XCTAssertTrue(store.storedAccountKeys.isEmpty)
    }

    func testCollisionWithoutDatesKeepsTheLowerAccountKey() async throws {
        let first = Fixture.tokens(account: Fixture.account, organization: Fixture.organization)
        let second = Fixture.tokens(
            access: "synthetic-access-second",
            account: Fixture.secondAccount,
            organization: Fixture.secondOrganization,
            email: Fixture.secondEmail
        )
        let dated = Fixture.thirdTokens()
        XCTAssertNil(first.addedAt)
        XCTAssertNil(second.addedAt)
        let store = InMemoryClaudeLoginAccounts(accounts: [dated, second, first])
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())

        let result = await accounts.migrateEarlierSignIns(to: targets())

        // A missing date counts as earliest; between two of them the lower key wins.
        let winner = min(first.accountKey, second.accountKey)
        XCTAssertEqual(result.placed, [.official: winner])
        XCTAssertEqual(
            result.unplacedAccountKeys,
            [first.accountKey, second.accountKey, dated.accountKey].filter { $0 != winner }.sorted()
        )
        XCTAssertEqual(store.tokens(.profile(.official))?.accountKey, winner)
    }

    func testAProfileThatAlreadyHasASignInKeepsIt() async throws {
        let existing = Fixture.secondTokens()
        let earlier = Fixture.tokens()
        let store = InMemoryClaudeLoginAccounts(accounts: [earlier], profiles: [.official: existing])
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())

        let result = await accounts.migrateEarlierSignIns(to: targets())

        XCTAssertEqual(result, ClaudeCodeMigrationResult(outcome: .complete, unplacedAccountKeys: [earlier.accountKey]))
        XCTAssertEqual(store.tokens(.profile(.official)), existing)
        XCTAssertEqual(store.saveCount(.profile(.official)), 0)
        XCTAssertEqual(store.tokens(.account(earlier.accountKey)), earlier)
    }

    func testEarlierItemOfAnAccountAlreadyOnAProfileIsRemoved() async throws {
        let current = Fixture.tokens(access: "synthetic-access-current")
        let earlier = Fixture.tokens(access: "synthetic-access-earlier")
        let store = InMemoryClaudeLoginAccounts(accounts: [earlier], profiles: [Fixture.work: current])
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())

        let result = await accounts.migrateEarlierSignIns(to: targets())

        XCTAssertEqual(result, ClaudeCodeMigrationResult(outcome: .complete))
        XCTAssertNil(store.tokens(.account(earlier.accountKey)))
        XCTAssertEqual(store.tokens(.profile(Fixture.work)), current)
        XCTAssertNil(store.tokens(.profile(.official)), "the account is not placed twice")
    }

    func testLegacyAndKeyedItemsOfTheSameAccountMigrateOnceKeepingTheKeyedOne() async throws {
        let legacy = Fixture.tokens()
        let renewed = Fixture.tokens(
            access: "synthetic-access-renewed",
            addedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let store = InMemoryClaudeLoginAccounts(legacy: legacy, accounts: [renewed])
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())

        let result = await accounts.migrateEarlierSignIns(to: targets())

        XCTAssertEqual(result, ClaudeCodeMigrationResult(outcome: .complete, placed: [.official: legacy.accountKey]))
        XCTAssertEqual(store.tokens(.profile(.official))?.accessToken, "synthetic-access-renewed")
        XCTAssertNil(store.tokens(.legacy))
        XCTAssertTrue(store.storedAccountKeys.isEmpty)
        XCTAssertEqual(store.saveCount(.profile(.official)), 1)
    }

    func testMigrationIsIdempotent() async throws {
        let legacy = Fixture.tokens()
        let store = InMemoryClaudeLoginAccounts(legacy: legacy)
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())

        let firstRun = await accounts.migrateEarlierSignIns(to: targets())
        let afterFirst = store.snapshot
        let secondRun = await accounts.migrateEarlierSignIns(to: targets())
        let relaunched = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())
        let thirdRun = await relaunched.migrateEarlierSignIns(to: targets())

        XCTAssertEqual(firstRun.placed, [.official: legacy.accountKey])
        XCTAssertEqual(secondRun, ClaudeCodeMigrationResult(outcome: .complete))
        XCTAssertEqual(thirdRun, ClaudeCodeMigrationResult(outcome: .complete))
        XCTAssertEqual(store.snapshot, afterFirst)
        XCTAssertEqual(store.saveCount(.profile(.official)), 1)
        XCTAssertEqual(store.deleteCount(.legacy), 1)
        XCTAssertEqual(store.storedProfileIDs, [.official])
    }

    func testFailedWriteKeepsLegacyItemAndRetries() async throws {
        let legacy = Fixture.tokens()
        let store = InMemoryClaudeLoginAccounts(legacy: legacy)
        store.failNextSave(.profile(.official))
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())

        let failed = await accounts.migrateEarlierSignIns(to: targets())

        XCTAssertEqual(failed.outcome, .failed)
        XCTAssertTrue(failed.placed.isEmpty)
        XCTAssertEqual(store.tokens(.legacy), legacy, "the credential is not lost")
        XCTAssertEqual(store.deleteCount(.legacy), 0)
        XCTAssertNil(store.tokens(.profile(.official)))

        let retried = await accounts.migrateEarlierSignIns(to: targets())
        XCTAssertEqual(retried, ClaudeCodeMigrationResult(outcome: .complete, placed: [.official: legacy.accountKey]))
        XCTAssertNil(store.tokens(.legacy))
        XCTAssertEqual(store.tokens(.profile(.official))?.accessToken, legacy.accessToken)
    }

    func testUnverifiedWriteKeepsLegacyItem() async throws {
        let legacy = Fixture.tokens()
        let store = InMemoryClaudeLoginAccounts(legacy: legacy)
        // The write reports success but nothing can be read back.
        store.dropNextSave(.profile(.official))
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())

        let unverified = await accounts.migrateEarlierSignIns(to: targets())
        XCTAssertEqual(unverified.outcome, .failed)
        XCTAssertEqual(store.tokens(.legacy), legacy)
        XCTAssertEqual(store.deleteCount(.legacy), 0)
        XCTAssertNil(store.tokens(.profile(.official)))

        let retried = await accounts.migrateEarlierSignIns(to: targets())
        XCTAssertEqual(retried.outcome, .complete)
        XCTAssertNil(store.tokens(.legacy))
        XCTAssertEqual(store.tokens(.profile(.official))?.accessToken, legacy.accessToken)
    }

    func testFailedEarlierDeleteIsRetriedWithoutPlacingTwice() async throws {
        let legacy = Fixture.tokens()
        let store = InMemoryClaudeLoginAccounts(legacy: legacy)
        store.failNextDelete(.legacy)
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())

        let first = await accounts.migrateEarlierSignIns(to: targets())

        XCTAssertEqual(first.placed, [.official: legacy.accountKey])
        XCTAssertNotNil(store.tokens(.legacy))
        let listing = await accounts.list(profiles: [.official])
        XCTAssertEqual(listing.accounts.first?.status.isSignedIn, true)

        let second = await accounts.migrateEarlierSignIns(to: targets())
        XCTAssertEqual(second, ClaudeCodeMigrationResult(outcome: .complete))
        XCTAssertNil(store.tokens(.legacy))
        XCTAssertEqual(store.saveCount(.profile(.official)), 1)
    }

    func testSignOutAfterAFailedEarlierDeleteDoesNotBringTheSignInBack() async throws {
        let legacy = Fixture.tokens()
        let store = InMemoryClaudeLoginAccounts(legacy: legacy)
        store.failNextDelete(.legacy)
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())
        _ = await accounts.migrateEarlierSignIns(to: targets())
        _ = await accounts.list(profiles: [.official])
        XCTAssertNotNil(store.tokens(.legacy))

        try await accounts.signOut(profile: .official)

        XCTAssertNil(store.tokens(.legacy))
        let again = await accounts.migrateEarlierSignIns(to: targets())
        XCTAssertEqual(again, ClaudeCodeMigrationResult(outcome: .complete))
        XCTAssertNil(store.tokens(.profile(.official)))
    }

    func testMigrationWaitsForKeychainAccessWithoutLosingTheItem() async throws {
        let legacy = Fixture.tokens()
        let store = InMemoryClaudeLoginAccounts(legacy: legacy)
        store.failNextLoad(.legacy, with: .interactionRequired)
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())

        let blocked = await accounts.migrateEarlierSignIns(to: targets())

        XCTAssertEqual(blocked, ClaudeCodeMigrationResult(outcome: .keychainAccessRequired))
        XCTAssertEqual(store.tokens(.legacy), legacy)
        XCTAssertTrue(store.storedProfileIDs.isEmpty)

        let allowed = await accounts.migrateEarlierSignIns(to: targets(), allowKeychainInteraction: true)
        XCTAssertEqual(allowed, ClaudeCodeMigrationResult(outcome: .complete, placed: [.official: legacy.accountKey]))
        XCTAssertNil(store.tokens(.legacy))
    }

    func testListingFailureChangesNothing() async throws {
        let earlier = Fixture.tokens()
        let store = InMemoryClaudeLoginAccounts(accounts: [earlier])
        store.failNextList(with: .interactionRequired)
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())
        let before = store.snapshot

        let result = await accounts.migrateEarlierSignIns(to: targets())

        XCTAssertEqual(result, ClaudeCodeMigrationResult(outcome: .keychainAccessRequired))
        XCTAssertEqual(store.snapshot, before)
    }

    func testUnreadableLegacyItemIsLeftUntouched() async throws {
        let store = InMemoryClaudeLoginAccounts(legacy: Fixture.tokens())
        store.failNextLoad(.legacy, with: .unreadable)
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())

        let result = await accounts.migrateEarlierSignIns(to: targets())
        XCTAssertEqual(result, ClaudeCodeMigrationResult(outcome: .complete))
        XCTAssertEqual(store.deleteCount(.legacy), 0)
        XCTAssertTrue(store.storedAccountKeys.isEmpty)
        XCTAssertTrue(store.storedProfileIDs.isEmpty)
    }

    func testDiscardingUnplacedSignInsDeletesOnlyThoseItems() async throws {
        let onProfile = Fixture.secondTokens()
        let keyed = Fixture.thirdTokens()
        let legacy = Fixture.tokens()
        let store = InMemoryClaudeLoginAccounts(
            legacy: legacy,
            accounts: [keyed],
            profiles: [.official: onProfile]
        )
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())
        let result = await accounts.migrateEarlierSignIns(to: targets())
        XCTAssertEqual(result.unplacedAccountKeys, [keyed.accountKey, legacy.accountKey].sorted())

        try await accounts.discardUnplacedSignIns(accountKeys: result.unplacedAccountKeys)

        XCTAssertNil(store.tokens(.legacy))
        XCTAssertTrue(store.storedAccountKeys.isEmpty)
        XCTAssertEqual(store.tokens(.profile(.official)), onProfile)
        let again = await accounts.migrateEarlierSignIns(to: targets())
        XCTAssertEqual(again, ClaudeCodeMigrationResult(outcome: .complete))
    }

    // MARK: - Helpers

    private func targets(
        work: String = "Work",
        personal: String = "Personal"
    ) -> [ClaudeCodeMigrationTarget] {
        [
            ClaudeCodeMigrationTarget(profile: .official, name: "Official Claude"),
            ClaudeCodeMigrationTarget(profile: Fixture.work, name: work),
            ClaudeCodeMigrationTarget(profile: Fixture.personal, name: personal)
        ]
    }

    /// Runs the real sign-in flow for one profile, answering with the
    /// synthetic account and pasting `code#state` once the authorize URL is known.
    private func signIn(
        _ accounts: ClaudeCodeAccounts,
        _ transport: ScriptedClaudeTransport,
        profile: ClaudeCodeProfileID,
        access: String,
        account: String = ClaudeLoginFixture.account,
        organization: String = ClaudeLoginFixture.organization,
        email: String = ClaudeLoginFixture.email
    ) async throws -> ClaudeCodeAccountUsage {
        await transport.enqueue(tokenPath, Fixture.tokenReply(access: access, refresh: "synthetic-refresh-\(access)"))
        await transport.enqueue(
            profilePath,
            token: access,
            Fixture.profileReply(account: account, organization: organization, email: email)
        )
        let (codes, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { continuation.finish() }
        return try await accounts.signIn(
            profile: profile,
            progress: { progress in
                guard case let .waitingForBrowser(url) = progress,
                      let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                          .queryItems?
                          .first(where: { $0.name == "state" })?
                          .value
                else { return }
                continuation.yield("synthetic-code#\(state)")
            },
            pastedCodes: codes
        )
    }
}
