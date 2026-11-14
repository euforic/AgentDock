import Foundation
import XCTest
@testable import AgentDockCore

/// Multiple Claude Code accounts over the in-memory store and the scripted
/// transport; sign-ins run the real PKCE flow with a pasted code, so nothing
/// leaves the process and no Keychain is touched.
final class ClaudeCodeAccountsTests: XCTestCase {
    private typealias Fixture = ClaudeLoginFixture
    private let tokenPath = ScriptedClaudeTransport.tokenPath
    private let profilePath = ScriptedClaudeTransport.profilePath

    // MARK: - Adding accounts

    func testAddingTwoAccountsStoresSeparateItemsAndListsBoth() async throws {
        let store = InMemoryClaudeLoginAccounts()
        let transport = ScriptedClaudeTransport()
        let accounts = ClaudeCodeAccounts(store: store, transport: transport)

        let first = try await signIn(
            accounts,
            transport,
            access: "synthetic-access-a",
            account: Fixture.account,
            organization: Fixture.organization,
            email: Fixture.email
        )
        let second = try await signIn(
            accounts,
            transport,
            access: "synthetic-access-second",
            account: Fixture.secondAccount,
            organization: Fixture.secondOrganization,
            email: Fixture.secondEmail
        )

        XCTAssertEqual(first.key, Fixture.accountKey)
        XCTAssertEqual(second.key, Fixture.secondAccountKey)
        XCTAssertNotEqual(first.key, second.key)
        XCTAssertTrue(ClaudeLoginAccountKey.isValid(first.key))
        XCTAssertFalse(first.key.contains(Fixture.account))
        XCTAssertEqual(first.status, .signedIn(try XCTUnwrap(first.account)))
        XCTAssertEqual(first.account?.label, Fixture.email)
        XCTAssertEqual(first.account?.subscriptionType, "max")
        XCTAssertNotNil(first.account?.addedAt)

        XCTAssertEqual(store.storedAccountKeys, [Fixture.accountKey, Fixture.secondAccountKey].sorted())
        XCTAssertEqual(store.tokens(.account(Fixture.accountKey))?.accessToken, "synthetic-access-a")
        XCTAssertEqual(store.tokens(.account(Fixture.secondAccountKey))?.accessToken, "synthetic-access-second")
        XCTAssertNil(store.tokens(.legacy))

        let listing = await accounts.list()
        XCTAssertFalse(listing.keychainAccessRequired)
        XCTAssertEqual(Set(listing.accounts.map(\.key)), [first.key, second.key])
        XCTAssertEqual(Set(listing.accounts.map(\.title)), [Fixture.email, Fixture.secondEmail])
        XCTAssertTrue(listing.accounts.allSatisfy { $0.status.isSignedIn && $0.limits == nil })
    }

    func testSigningInAgainReplacesTheAccountsItemAndKeepsItsName() async throws {
        let store = InMemoryClaudeLoginAccounts()
        let transport = ScriptedClaudeTransport()
        let accounts = ClaudeCodeAccounts(store: store, transport: transport)
        let first = try await signIn(accounts, transport, access: "synthetic-access-a")
        let addedAt = try XCTUnwrap(first.account?.addedAt)
        _ = try await accounts.rename(accountKey: first.key, to: "Work")

        let again = try await signIn(accounts, transport, access: "synthetic-access-b")

        XCTAssertEqual(again.key, first.key)
        XCTAssertEqual(again.account?.customName, "Work")
        XCTAssertEqual(again.account?.addedAt, addedAt)
        XCTAssertEqual(again.title, "Work")
        XCTAssertEqual(store.storedAccountKeys, [first.key], "no duplicate item")
        let stored = try XCTUnwrap(store.tokens(.account(first.key)))
        XCTAssertEqual(stored.accessToken, "synthetic-access-b")
        XCTAssertEqual(stored.customName, "Work")

        let listing = await accounts.list()
        XCTAssertEqual(listing.accounts.map(\.key), [first.key])
        XCTAssertEqual(listing.accounts.first?.title, "Work")
    }

    func testRenameChangesOnlyThatAccountAndEmptyNameRestoresEmail() async throws {
        let first = Fixture.tokens()
        let second = Fixture.secondTokens()
        let store = InMemoryClaudeLoginAccounts(accounts: [first, second])
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())
        _ = await accounts.list()

        let renamed = try await accounts.rename(accountKey: first.accountKey, to: "  Personal  ")
        XCTAssertEqual(renamed.customName, "Personal")
        XCTAssertEqual(renamed.displayName, "Personal")
        XCTAssertEqual(renamed.label, Fixture.email)
        XCTAssertEqual(store.tokens(.account(first.accountKey))?.customName, "Personal")
        XCTAssertEqual(store.tokens(.account(first.accountKey))?.accessToken, first.accessToken)
        XCTAssertEqual(store.tokens(.account(second.accountKey)), second)
        XCTAssertEqual(store.saveCount(.account(second.accountKey)), 0)

        let long = String(repeating: "n", count: 200)
        let clipped = try await accounts.rename(accountKey: first.accountKey, to: long)
        XCTAssertEqual(clipped.customName?.count, ClaudeLoginTokens.maximumCustomNameLength)

        let cleared = try await accounts.rename(accountKey: first.accountKey, to: "   ")
        XCTAssertNil(cleared.customName)
        XCTAssertEqual(cleared.displayName, Fixture.email)
        XCTAssertNil(store.tokens(.account(first.accountKey))?.customName)

        do {
            _ = try await accounts.rename(accountKey: Fixture.thirdAccountKey, to: "Missing")
            XCTFail("Renaming an unknown account should fail")
        } catch {
            XCTAssertEqual(error as Any as? ClaudeSignInError, .accountNotFound)
        }
    }

    func testSignOutDeletesOnlyThatAccountsItem() async throws {
        let first = Fixture.tokens()
        let second = Fixture.secondTokens()
        let store = InMemoryClaudeLoginAccounts(accounts: [first, second])
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())
        _ = await accounts.list()

        try await accounts.signOut(accountKey: first.accountKey)

        XCTAssertNil(store.tokens(.account(first.accountKey)))
        XCTAssertEqual(store.tokens(.account(second.accountKey)), second)
        XCTAssertEqual(store.deleteCount(.account(first.accountKey)), 1)
        XCTAssertEqual(store.deleteCount(.account(second.accountKey)), 0)
        let listing = await accounts.list()
        XCTAssertEqual(listing.accounts.map(\.key), [second.accountKey])
        XCTAssertEqual(listing.accounts.first?.status.isSignedIn, true)
    }

    func testRefusedRenewalKeepsAnExpiredCardForOnlyThatAccount() async throws {
        let now = Date()
        let first = Fixture.tokens(expiresAt: now.addingTimeInterval(10))
        let second = Fixture.secondTokens()
        let store = InMemoryClaudeLoginAccounts(accounts: [first, second])
        let transport = ScriptedClaudeTransport()
        await transport.enqueue(tokenPath, Fixture.errorReply(400, "invalid_grant"))
        let accounts = ClaudeCodeAccounts(store: store, transport: transport)
        let entries = await accounts.entries(allowKeychainInteraction: false).entries
        let login = try XCTUnwrap(entries.first { $0.key == first.accountKey }?.login)

        let outcome = await login.usableTokens(allowKeychainInteraction: false, now: now)
        XCTAssertEqual(outcome, .signedOut(expired: true))

        XCTAssertNil(store.tokens(.account(first.accountKey)))
        XCTAssertEqual(store.tokens(.account(second.accountKey)), second)
        let listing = await accounts.list()
        XCTAssertEqual(Set(listing.accounts.map(\.key)), [first.accountKey, second.accountKey])
        let expired = try XCTUnwrap(listing.accounts.first { $0.key == first.accountKey })
        XCTAssertEqual(expired.status, .signedOut(expired: true))
        XCTAssertEqual(expired.title, Fixture.email, "the card keeps its label to ask for a new sign-in")
        XCTAssertEqual(listing.accounts.first { $0.key == second.accountKey }?.status.isSignedIn, true)

        // Removing the expired card succeeds even though its item is already gone.
        try await accounts.signOut(accountKey: first.accountKey)
        let afterRemoval = await accounts.list()
        XCTAssertEqual(afterRemoval.accounts.map(\.key), [second.accountKey])
    }

    func testOneUnreadableAccountDoesNotHideOthers() async throws {
        let second = Fixture.secondTokens()
        let store = InMemoryClaudeLoginAccounts(accounts: [second])
        // An item named for one account that holds another account's sign-in.
        store.replace(.account(Fixture.accountKey), with: Fixture.thirdTokens())
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())

        let listing = await accounts.list()

        XCTAssertEqual(Set(listing.accounts.map(\.key)), [Fixture.accountKey, second.accountKey])
        let unreadable = try XCTUnwrap(listing.accounts.first { $0.key == Fixture.accountKey })
        XCTAssertEqual(unreadable.status, .signedOut(expired: false))
        XCTAssertNil(unreadable.account)
        XCTAssertEqual(listing.accounts.first { $0.key == second.accountKey }?.status.isSignedIn, true)
    }

    func testListingNeedsKeychainAccessKeepsKnownAccounts() async throws {
        let first = Fixture.tokens()
        let store = InMemoryClaudeLoginAccounts(accounts: [first])
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())
        _ = await accounts.list()

        store.failNextList()
        let listing = await accounts.list()

        XCTAssertTrue(listing.keychainAccessRequired)
        XCTAssertEqual(listing.accounts.map(\.key), [first.accountKey])
    }

    // MARK: - Migrating the single legacy item

    func testMigratesLegacyItemToItsAccountKeyedItemWithoutSigningIn() async throws {
        let legacy = Fixture.tokens()
        let store = InMemoryClaudeLoginAccounts(legacy: legacy)
        let transport = ScriptedClaudeTransport()
        let accounts = ClaudeCodeAccounts(store: store, transport: transport)

        let listing = await accounts.list()

        XCTAssertFalse(listing.keychainAccessRequired)
        XCTAssertEqual(listing.accounts.map(\.key), [legacy.accountKey])
        XCTAssertEqual(listing.accounts.first?.status.isSignedIn, true)
        XCTAssertEqual(listing.accounts.first?.title, Fixture.email)
        XCTAssertNil(store.tokens(.legacy))
        let migrated = try XCTUnwrap(store.tokens(.account(legacy.accountKey)))
        XCTAssertEqual(migrated.accessToken, legacy.accessToken)
        XCTAssertEqual(migrated.refreshToken, legacy.refreshToken)
        XCTAssertEqual(migrated.accountUUID, legacy.accountUUID)
        XCTAssertEqual(migrated.organizationUUID, legacy.organizationUUID)
        XCTAssertNotNil(migrated.addedAt)
        let requests = await transport.requests.count
        XCTAssertEqual(requests, 0, "migration needs no network request")
    }

    func testMigrationIsIdempotent() async throws {
        let legacy = Fixture.tokens()
        let store = InMemoryClaudeLoginAccounts(legacy: legacy)
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())
        let key = legacy.accountKey

        let firstRun = await accounts.migrateLegacyIfNeeded(allowInteraction: false)
        let secondRun = await accounts.migrateLegacyIfNeeded(allowInteraction: false)
        XCTAssertEqual(firstRun, .complete)
        XCTAssertEqual(secondRun, .complete)
        _ = await accounts.list()
        _ = await accounts.list()

        XCTAssertEqual(store.saveCount(.account(key)), 1)
        XCTAssertEqual(store.deleteCount(.legacy), 1)
        XCTAssertEqual(store.storedAccountKeys, [key])

        // A relaunch that still finds the legacy item next to a newer keyed
        // item (for example after a failed delete) keeps the keyed item.
        var renewed = try XCTUnwrap(store.tokens(.account(key)))
        renewed.accessToken = "synthetic-access-renewed"
        store.replace(.account(key), with: renewed)
        store.replace(.legacy, with: legacy)
        let relaunched = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())

        let listing = await relaunched.list()

        XCTAssertEqual(listing.accounts.map(\.key), [key])
        XCTAssertEqual(store.tokens(.account(key))?.accessToken, "synthetic-access-renewed")
        XCTAssertEqual(store.saveCount(.account(key)), 1)
        XCTAssertNil(store.tokens(.legacy))
    }

    func testFailedWriteKeepsLegacyItemAndRetries() async throws {
        let legacy = Fixture.tokens()
        let store = InMemoryClaudeLoginAccounts(legacy: legacy)
        store.failNextSave(.account(legacy.accountKey))
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())

        let failed = await accounts.list()

        XCTAssertTrue(failed.accounts.isEmpty)
        XCTAssertEqual(store.tokens(.legacy), legacy, "the credential is not lost")
        XCTAssertEqual(store.deleteCount(.legacy), 0)

        let retried = await accounts.list()
        XCTAssertEqual(retried.accounts.map(\.key), [legacy.accountKey])
        XCTAssertNil(store.tokens(.legacy))
        XCTAssertEqual(store.tokens(.account(legacy.accountKey))?.accessToken, legacy.accessToken)
    }

    func testUnverifiedWriteKeepsLegacyItem() async throws {
        let legacy = Fixture.tokens()
        let store = InMemoryClaudeLoginAccounts(legacy: legacy)
        // The write reports success but nothing can be read back.
        store.dropNextSave(.account(legacy.accountKey))
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())

        let unverified = await accounts.migrateLegacyIfNeeded(allowInteraction: false)
        XCTAssertEqual(unverified, .failed)
        XCTAssertEqual(store.tokens(.legacy), legacy)
        XCTAssertEqual(store.deleteCount(.legacy), 0)

        let retried = await accounts.migrateLegacyIfNeeded(allowInteraction: false)
        XCTAssertEqual(retried, .complete)
        XCTAssertNil(store.tokens(.legacy))
        XCTAssertEqual(store.tokens(.account(legacy.accountKey))?.accessToken, legacy.accessToken)
    }

    func testFailedLegacyDeleteStillShowsMigratedAccountAndRetriesDelete() async throws {
        let legacy = Fixture.tokens()
        let store = InMemoryClaudeLoginAccounts(legacy: legacy)
        store.failNextDelete(.legacy)
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())

        let first = await accounts.list()

        XCTAssertEqual(first.accounts.map(\.key), [legacy.accountKey])
        XCTAssertNotNil(store.tokens(.legacy))

        _ = await accounts.list()
        XCTAssertNil(store.tokens(.legacy))
        XCTAssertEqual(store.saveCount(.account(legacy.accountKey)), 1)
    }

    func testSignOutDuringPendingMigrationDoesNotResurrectAccount() async throws {
        let legacy = Fixture.tokens()
        let store = InMemoryClaudeLoginAccounts(legacy: legacy)
        store.failNextDelete(.legacy)
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())
        _ = await accounts.list()
        XCTAssertNotNil(store.tokens(.legacy))

        try await accounts.signOut(accountKey: legacy.accountKey)

        XCTAssertNil(store.tokens(.legacy))
        let listing = await accounts.list()
        XCTAssertTrue(listing.accounts.isEmpty)
    }

    func testMigrationWaitsForKeychainAccessWithoutLosingTheItem() async throws {
        let legacy = Fixture.tokens()
        let store = InMemoryClaudeLoginAccounts(legacy: legacy)
        store.failNextLoad(.legacy, with: .interactionRequired)
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())

        let blocked = await accounts.list()

        XCTAssertTrue(blocked.keychainAccessRequired)
        XCTAssertTrue(blocked.accounts.isEmpty)
        XCTAssertEqual(store.tokens(.legacy), legacy)

        let allowed = await accounts.list(allowKeychainInteraction: true)
        XCTAssertFalse(allowed.keychainAccessRequired)
        XCTAssertEqual(allowed.accounts.map(\.key), [legacy.accountKey])
        XCTAssertNil(store.tokens(.legacy))
    }

    func testUnreadableLegacyItemIsLeftUntouched() async throws {
        let store = InMemoryClaudeLoginAccounts(legacy: Fixture.tokens())
        store.failNextLoad(.legacy, with: .unreadable)
        let accounts = ClaudeCodeAccounts(store: store, transport: ScriptedClaudeTransport())

        let result = await accounts.migrateLegacyIfNeeded(allowInteraction: false)
        XCTAssertEqual(result, .complete)
        XCTAssertEqual(store.deleteCount(.legacy), 0)
        XCTAssertTrue(store.storedAccountKeys.isEmpty)
    }

    func testRenewalWritesBackOnlyToItsOwnAccount() async throws {
        let now = Date()
        let first = Fixture.tokens(expiresAt: now.addingTimeInterval(10))
        let second = Fixture.secondTokens()
        let store = InMemoryClaudeLoginAccounts(accounts: [first, second])
        let transport = ScriptedClaudeTransport()
        await transport.enqueue(tokenPath, Fixture.tokenReply(access: "synthetic-access-renewed"))
        let accounts = ClaudeCodeAccounts(store: store, transport: transport)
        let entries = await accounts.entries(allowKeychainInteraction: false).entries
        let login = try XCTUnwrap(entries.first { $0.key == first.accountKey }?.login)

        let outcome = await login.usableTokens(allowKeychainInteraction: false, now: now)

        guard case let .tokens(renewed) = outcome else { return XCTFail("Expected tokens, got \(outcome)") }
        XCTAssertEqual(renewed.accessToken, "synthetic-access-renewed")
        XCTAssertEqual(store.tokens(.account(first.accountKey))?.accessToken, "synthetic-access-renewed")
        XCTAssertEqual(store.tokens(.account(second.accountKey)), second)
        XCTAssertEqual(store.saveCount(.account(second.accountKey)), 0)
        XCTAssertEqual(store.saveCount(.legacy), 0)
    }

    // MARK: - Helpers

    /// Runs the real sign-in flow, answering with the synthetic account and
    /// pasting `code#state` once the authorize URL is known.
    private func signIn(
        _ accounts: ClaudeCodeAccounts,
        _ transport: ScriptedClaudeTransport,
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
        return try await accounts.addAccount(
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
