import Foundation
import XCTest
@testable import AgentDockCore

/// Uses the scripted transport and the in-memory store; no network or Keychain.
final class ClaudeCodeLoginTests: XCTestCase {
    private typealias Fixture = ClaudeLoginFixture
    private let tokenPath = ScriptedClaudeTransport.tokenPath

    func testRenewsFiveMinutesBeforeExpiryAndWritesBack() async throws {
        let now = Date()
        let store = InMemoryClaudeLoginStore(Fixture.tokens(expiresAt: now.addingTimeInterval(299)))
        let transport = ScriptedClaudeTransport()
        await transport.enqueue(
            tokenPath,
            Fixture.tokenReply(access: "synthetic-access-b", refresh: "synthetic-refresh-b", expiresIn: 7_200)
        )
        let login = ClaudeCodeLogin(store: store, transport: transport)

        let outcome = await login.usableTokens(allowKeychainInteraction: false, now: now)
        guard case let .tokens(renewed) = outcome else { return XCTFail("Expected tokens, got \(outcome)") }
        XCTAssertEqual(renewed.accessToken, "synthetic-access-b")
        let tokenRequests = await transport.count(tokenPath)
        XCTAssertEqual(tokenRequests, 1)
        let bodies = await transport.bodies(tokenPath)
        XCTAssertEqual(bodies.first?["grant_type"], "refresh_token")
        XCTAssertEqual(bodies.first?["refresh_token"], "synthetic-refresh-a")
        XCTAssertEqual(store.tokens?.accessToken, "synthetic-access-b")
        XCTAssertEqual(store.tokens?.refreshToken, "synthetic-refresh-b")
        XCTAssertEqual(store.tokens?.expiresAt, now.addingTimeInterval(7_200))

        // Outside the five-minute margin nothing is sent.
        let laterStore = InMemoryClaudeLoginStore(Fixture.tokens(expiresAt: now.addingTimeInterval(301)))
        let idleTransport = ScriptedClaudeTransport()
        let idle = ClaudeCodeLogin(store: laterStore, transport: idleTransport)
        let unchanged = await idle.usableTokens(allowKeychainInteraction: false, now: now)
        XCTAssertEqual(unchanged, .tokens(Fixture.tokens(expiresAt: now.addingTimeInterval(301))))
        let idleRequests = await idleTransport.requests.count
        XCTAssertEqual(idleRequests, 0)
    }

    func testKeepsRefreshTokenWhenRenewalOmitsIt() async throws {
        let now = Date()
        let store = InMemoryClaudeLoginStore(Fixture.tokens(expiresAt: now.addingTimeInterval(10)))
        let transport = ScriptedClaudeTransport()
        await transport.enqueue(tokenPath, Fixture.tokenReply(access: "synthetic-access-b"))
        let login = ClaudeCodeLogin(store: store, transport: transport)

        let outcome = await login.usableTokens(allowKeychainInteraction: false, now: now)
        guard case let .tokens(renewed) = outcome else { return XCTFail("Expected tokens, got \(outcome)") }
        XCTAssertEqual(renewed.accessToken, "synthetic-access-b")
        XCTAssertEqual(renewed.refreshToken, "synthetic-refresh-a")
        XCTAssertEqual(store.tokens?.refreshToken, "synthetic-refresh-a")
    }

    func testConcurrentCallersShareOneRenewal() async throws {
        let now = Date()
        let store = InMemoryClaudeLoginStore(Fixture.tokens(expiresAt: now.addingTimeInterval(10)))
        let transport = ScriptedClaudeTransport()
        await transport.hold(tokenPath)
        await transport.enqueue(tokenPath, Fixture.tokenReply(access: "synthetic-access-b"))
        let login = ClaudeCodeLogin(store: store, transport: transport)

        async let first = login.usableTokens(allowKeychainInteraction: false, now: now)
        async let second = login.usableTokens(allowKeychainInteraction: false, now: now)
        let held = await eventually { await transport.heldCount == 1 }
        XCTAssertTrue(held)
        try await Task.sleep(for: .milliseconds(50))
        await transport.release()

        let (a, b) = await (first, second)
        XCTAssertEqual(a, b)
        guard case let .tokens(renewed) = a else { return XCTFail("Expected tokens, got \(a)") }
        XCTAssertEqual(renewed.accessToken, "synthetic-access-b")
        let tokenRequests = await transport.count(tokenPath)
        XCTAssertEqual(tokenRequests, 1)
    }

    func testRenewalReusesTokenAlreadyRenewedByAnotherPath() async throws {
        let store = InMemoryClaudeLoginStore(Fixture.tokens())
        let transport = ScriptedClaudeTransport()
        await transport.enqueue(tokenPath, Fixture.tokenReply(access: "synthetic-access-b"))
        let login = ClaudeCodeLogin(store: store, transport: transport)
        _ = await login.status()

        let renewed = await login.renewAfterUnauthorized(rejectedAccessToken: "synthetic-access-a")
        guard case let .tokens(tokens) = renewed else { return XCTFail("Expected tokens, got \(renewed)") }
        XCTAssertEqual(tokens.accessToken, "synthetic-access-b")
        let afterFirst = await transport.count(tokenPath)
        XCTAssertEqual(afterFirst, 1)

        // A second 401 for the old token reuses the renewal without a request.
        let reused = await login.renewAfterUnauthorized(rejectedAccessToken: "synthetic-access-a")
        XCTAssertEqual(reused, .tokens(tokens))
        let afterSecond = await transport.count(tokenPath)
        XCTAssertEqual(afterSecond, 1)
    }

    func testInvalidScopeRetriesWithProfileScope() async throws {
        let now = Date()
        let store = InMemoryClaudeLoginStore(Fixture.tokens(expiresAt: now.addingTimeInterval(10)))
        let transport = ScriptedClaudeTransport()
        await transport.enqueue(
            tokenPath,
            Fixture.errorReply(400, "invalid_scope"),
            Fixture.tokenReply(access: "synthetic-access-b", scope: "user:profile")
        )
        let login = ClaudeCodeLogin(store: store, transport: transport)

        let outcome = await login.usableTokens(allowKeychainInteraction: false, now: now)
        guard case let .tokens(renewed) = outcome else { return XCTFail("Expected tokens, got \(outcome)") }
        XCTAssertEqual(renewed.accessToken, "synthetic-access-b")
        XCTAssertEqual(renewed.scopes, ["user:profile"])
        let scopes = await transport.bodies(tokenPath).map { $0["scope"] }
        XCTAssertEqual(scopes, ["user:profile user:inference", "user:profile"])
    }

    func testRefusedRenewalSignsOutAndDeletesStoredLogin() async throws {
        let now = Date()
        let store = InMemoryClaudeLoginStore(Fixture.tokens(expiresAt: now.addingTimeInterval(10)))
        let transport = ScriptedClaudeTransport()
        await transport.enqueue(tokenPath, Fixture.errorReply(400, "invalid_grant"))
        let login = ClaudeCodeLogin(store: store, transport: transport)

        let outcome = await login.usableTokens(allowKeychainInteraction: false, now: now)
        XCTAssertEqual(outcome, .signedOut(expired: true))
        XCTAssertNil(store.tokens)
        let status = await login.status()
        XCTAssertEqual(status, .signedOut(expired: true))

        // Nothing more is sent once signed out.
        let again = await login.usableTokens(allowKeychainInteraction: false, now: now)
        XCTAssertEqual(again, .signedOut(expired: true))
        let tokenRequests = await transport.count(tokenPath)
        XCTAssertEqual(tokenRequests, 1)
    }

    func testOutageKeepsCurrentTokenAndRetriesNextPass() async throws {
        let now = Date()
        let original = Fixture.tokens(expiresAt: now.addingTimeInterval(60))
        let store = InMemoryClaudeLoginStore(original)
        let transport = ScriptedClaudeTransport()
        await transport.enqueue(tokenPath, .json(503, ""), .failure())
        let login = ClaudeCodeLogin(store: store, transport: transport)

        let first = await login.usableTokens(allowKeychainInteraction: false, now: now)
        XCTAssertEqual(first, .tokens(original))
        XCTAssertEqual(store.tokens, original)

        let second = await login.usableTokens(allowKeychainInteraction: false, now: now)
        XCTAssertEqual(second, .tokens(original))
        XCTAssertEqual(store.tokens, original)
        let tokenRequests = await transport.count(tokenPath)
        XCTAssertEqual(tokenRequests, 2)
    }

    func testExpiredTokenWithOutageReportsRenewalUnavailable() async throws {
        let now = Date()
        let original = Fixture.tokens(expiresAt: now.addingTimeInterval(-10))
        let store = InMemoryClaudeLoginStore(original)
        let transport = ScriptedClaudeTransport()
        await transport.enqueue(tokenPath, .json(503, ""))
        let login = ClaudeCodeLogin(store: store, transport: transport)

        let outcome = await login.usableTokens(allowKeychainInteraction: false, now: now)
        XCTAssertEqual(outcome, .renewalUnavailable)
        XCTAssertEqual(store.tokens, original)
        let status = await login.status()
        XCTAssertEqual(status, .signedIn(ClaudeLoginAccount(label: Fixture.email, subscriptionType: "max")))
    }

    func testUnsavedRenewalIsSavedOnNextPassWithoutNewRequest() async throws {
        let now = Date()
        let store = InMemoryClaudeLoginStore(Fixture.tokens(expiresAt: now.addingTimeInterval(10)))
        store.failNextSave()
        let transport = ScriptedClaudeTransport()
        await transport.enqueue(tokenPath, Fixture.tokenReply(access: "synthetic-access-b"))
        let login = ClaudeCodeLogin(store: store, transport: transport)

        let first = await login.usableTokens(allowKeychainInteraction: false, now: now)
        guard case let .tokens(renewed) = first else { return XCTFail("Expected tokens, got \(first)") }
        XCTAssertEqual(renewed.accessToken, "synthetic-access-b")
        XCTAssertEqual(store.tokens?.accessToken, "synthetic-access-a")

        let second = await login.usableTokens(allowKeychainInteraction: false, now: now)
        XCTAssertEqual(second, .tokens(renewed))
        XCTAssertEqual(store.tokens, renewed)
        let tokenRequests = await transport.count(tokenPath)
        XCTAssertEqual(tokenRequests, 1)
    }

    func testSignOutDuringRenewalDoesNotRestoreTokens() async throws {
        let now = Date()
        let store = InMemoryClaudeLoginStore(Fixture.tokens(expiresAt: now.addingTimeInterval(10)))
        let transport = ScriptedClaudeTransport()
        await transport.hold(tokenPath)
        await transport.enqueue(tokenPath, Fixture.tokenReply(access: "synthetic-access-b"))
        let login = ClaudeCodeLogin(store: store, transport: transport)

        let pending = Task { await login.usableTokens(allowKeychainInteraction: false, now: now) }
        let held = await eventually { await transport.heldCount == 1 }
        XCTAssertTrue(held)
        try await login.signOut()
        await transport.release()

        let outcome = await pending.value
        XCTAssertEqual(outcome, .signedOut(expired: false))
        XCTAssertNil(store.tokens)
        let status = await login.status()
        XCTAssertEqual(status, .signedOut(expired: false))
    }

    // MARK: - One account per login

    func testAdoptRefusesAnotherAccountAndReplacesTheSameAccountsTokens() async throws {
        var current = Fixture.tokens(addedAt: Date(timeIntervalSince1970: 1_800_000_000))
        current.customName = "Kept"
        let store = InMemoryClaudeLoginStore(current)
        let login = ClaudeCodeLogin(store: store, transport: ScriptedClaudeTransport())
        let stored = try XCTUnwrap(store.tokens)

        do {
            _ = try await login.adopt(Fixture.secondTokens())
            XCTFail("A login bound to one account must refuse another")
        } catch {
            XCTAssertEqual(error as Any as? ClaudeSignInError, .differentAccount(Fixture.email))
        }
        XCTAssertEqual(store.tokens, stored, "the stored sign-in is untouched")
        XCTAssertEqual(store.saveCount, 0)
        let status = await login.status()
        XCTAssertEqual(status.isSignedIn, true)

        let renewed = Fixture.tokens(
            access: "synthetic-access-b",
            refresh: "synthetic-refresh-b",
            addedAt: Date(timeIntervalSince1970: 1_900_000_000)
        )
        let account = try await login.adopt(renewed)

        XCTAssertEqual(account.label, Fixture.email)
        XCTAssertEqual(account.customName, "Kept")
        XCTAssertEqual(account.addedAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(store.tokens?.accessToken, "synthetic-access-b")
        XCTAssertEqual(store.tokens?.refreshToken, "synthetic-refresh-b")
        XCTAssertEqual(store.tokens?.customName, "Kept")
        XCTAssertEqual(store.tokens?.accountUUID, Fixture.account)
    }

    func testAdoptRefusesEveryAccountForAnUnreadableSignIn() async throws {
        let store = InMemoryClaudeLoginStore(Fixture.tokens())
        store.failNextLoad(with: .unreadable)
        let login = ClaudeCodeLogin(store: store, transport: ScriptedClaudeTransport())
        let stored = try XCTUnwrap(store.tokens)

        for candidate in [Fixture.tokens(access: "synthetic-access-b"), Fixture.secondTokens()] {
            do {
                _ = try await login.adopt(candidate)
                XCTFail("An unreadable sign-in must refuse every account")
            } catch {
                XCTAssertEqual(error as Any as? ClaudeSignInError, .unreadableSignIn)
            }
        }
        do {
            try await login.checkCanSignIn()
            XCTFail("An unreadable sign-in must refuse to start a sign-in")
        } catch {
            XCTAssertEqual(error as Any as? ClaudeSignInError, .unreadableSignIn)
        }
        XCTAssertEqual(store.tokens, stored)
        XCTAssertEqual(store.saveCount, 0)

        // Signing out removes it; then any account may sign in.
        try await login.signOut()
        try await login.checkCanSignIn()
        let account = try await login.adopt(Fixture.secondTokens())
        XCTAssertEqual(account.label, Fixture.secondEmail)
        XCTAssertEqual(store.tokens?.accountUUID, Fixture.secondAccount)
    }
}
