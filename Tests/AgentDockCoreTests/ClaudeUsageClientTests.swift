import Security
import XCTest
@testable import AgentDockCore

final class ClaudeUsageClientTests: XCTestCase {
    func testDesktopCredentialRequiresExplicitAccountAndOrganizationIdentity() {
        let account = "00000000-0000-0000-0000-000000000001"
        let organization = "00000000-0000-0000-0000-000000000002"

        XCTAssertEqual(
            ClaudeAccountIdentity.desktop(accountUUID: account, organizationUUID: organization),
            ClaudeAccountIdentity(accountUUID: account, organizationUUID: organization)
        )
        XCTAssertNil(ClaudeAccountIdentity.desktop(accountUUID: nil, organizationUUID: organization))
        XCTAssertNil(ClaudeAccountIdentity.desktop(accountUUID: "", organizationUUID: organization))
        XCTAssertNil(ClaudeAccountIdentity.desktop(accountUUID: "invalid", organizationUUID: organization))
        XCTAssertNil(ClaudeAccountIdentity.desktop(accountUUID: account, organizationUUID: "invalid"))
    }

    func testCredentialCacheSeparatesAccountAndOrganizationForTheSameToken() {
        let identity = ClaudeAccountIdentity(
            accountUUID: "00000000-0000-0000-0000-000000000001",
            organizationUUID: "00000000-0000-0000-0000-000000000002"
        )
        let original = ClaudeUsageCredential(
            accessToken: "synthetic-token",
            scopes: ["user:profile"],
            identity: identity
        )
        var otherAccount = original
        otherAccount.identity?.accountUUID = "00000000-0000-0000-0000-000000000003"
        var otherOrganization = original
        otherOrganization.identity?.organizationUUID = "00000000-0000-0000-0000-000000000004"

        XCTAssertNotEqual(original.cacheKey, otherAccount.cacheKey)
        XCTAssertNotEqual(original.cacheKey, otherOrganization.cacheKey)
        XCTAssertFalse(original.cacheKey.contains(original.accessToken))
    }

    func testNoninteractiveKeychainReadSuppressesLegacyUIAndRestoresState() throws {
        var original = DarwinBoolean(false)
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&original), errSecSuccess)
        defer { _ = SecKeychainSetUserInteractionAllowed(original.boolValue) }
        XCTAssertEqual(SecKeychainSetUserInteractionAllowed(true), errSecSuccess)

        let result: Bool? = ClaudeKeychainAccess.withInteractionAllowed(false) {
            var allowed = DarwinBoolean(true)
            XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
            return allowed.boolValue
        }
        XCTAssertEqual(result, false)
        var restored = DarwinBoolean(false)
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&restored), errSecSuccess)
        XCTAssertTrue(restored.boolValue)

        let missing: String? = ClaudeKeychainAccess.withInteractionAllowed(false) { nil }
        XCTAssertNil(missing)
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&restored), errSecSuccess)
        XCTAssertTrue(restored.boolValue)
    }

    func testOfficialUsageRequiresDesktopLoginEvenWhenCodeCredentialExists() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codeHome = directory.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: codeHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"claudeAiOauth":{"accessToken":"synthetic-token","scopes":["user:profile"]}}"#.utf8)
            .write(to: codeHome.appendingPathComponent(".credentials.json"))

        let limits = await ClaudeUsageClient().fetchOfficialUsage(
            claudeUserDataURL: directory.appendingPathComponent("desktop"),
            allowKeychainInteraction: false,
            forceRefresh: true
        )
        XCTAssertTrue(limits.buckets.isEmpty)
        XCTAssertTrue(limits.errorMessage?.hasPrefix("Live usage is unavailable.") == true)
    }

    func testInstalledOfficialUsageWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["AGENTDOCK_LIVE_CLAUDE_USAGE_TEST"] == "1" else {
            throw XCTSkip("Set AGENTDOCK_LIVE_CLAUDE_USAGE_TEST=1 to validate the signed-in official account.")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let limits = await ClaudeUsageClient().fetchOfficialUsage(
            claudeUserDataURL: home.appendingPathComponent(
                "Library/Application Support/Claude",
                isDirectory: true
            ),
            allowKeychainInteraction: false,
            forceRefresh: true
        )

        XCTAssertNil(limits.errorMessage)
        XCTAssertFalse(limits.buckets.isEmpty)
    }

    func testMapsLiveWindowsScopedModelsAndExtraUsage() throws {
        let data = Data(#"""
        {
          "five_hour":{"utilization":12.5,"resets_at":"2099-01-01T00:00:00.000Z"},
          "seven_day":{"utilization":41,"resets_at":"2099-01-07T00:00:00Z"},
          "seven_day_sonnet":{"utilization":7,"resets_at":"2099-01-07T00:00:00.000Z"},
          "limits":[
            {"kind":"weekly_scoped","percent":23,"resets_at":"2099-01-07T00:00:00.000Z",
             "scope":{"model":{"display_name":"Fable"}}},
            {"kind":"other","percent":99,"scope":{"model":{"display_name":"Ignored"}}}
          ],
          "extra_usage":{"is_enabled":true,"used_credits":525,"monthly_limit":2000}
        }
        """#.utf8)

        let limits = try ClaudeUsageResponseParser.parse(
            data,
            planType: "max",
            fetchedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(limits.planType, "max")
        XCTAssertEqual(limits.fetchedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(limits.buckets.map(\.id), ["claude", "sonnet", "model-fable"])
        XCTAssertEqual(limits.buckets[0].primary?.usedPercent, 12.5)
        XCTAssertEqual(limits.buckets[0].primary?.windowDurationMins, 300)
        XCTAssertEqual(limits.buckets[0].secondary?.usedPercent, 41)
        XCTAssertEqual(limits.buckets[0].secondary?.windowDurationMins, 10_080)
        XCTAssertEqual(limits.buckets[2].name, "Fable")
        XCTAssertEqual(limits.buckets[2].primary?.usedPercent, 23)
        XCTAssertEqual(limits.credits?.balance, "$5.25 of $20.00 used")
    }

    func testMissingAndNullWindowsRemainHonest() throws {
        let data = Data(#"""
        {
          "five_hour":null,
          "seven_day":{"resets_at":"invalid"},
          "extra_usage":{"is_enabled":false,"used_credits":500}
        }
        """#.utf8)

        let limits = try ClaudeUsageResponseParser.parse(data)

        XCTAssertTrue(limits.buckets.isEmpty)
        XCTAssertNil(limits.credits)
    }

    func testRejectsNonObjectResponse() {
        XCTAssertThrowsError(try ClaudeUsageResponseParser.parse(Data("[]".utf8)))
    }

    func testSuccessfulUsageIsReusableForFiveMinutes() {
        let fetchedAt = Date(timeIntervalSince1970: 1_000)
        let limits = ProfileRateLimits(fetchedAt: fetchedAt)

        XCTAssertTrue(ClaudeUsageRefreshPolicy.canReuse(
            limits,
            now: fetchedAt.addingTimeInterval(299)
        ))
        XCTAssertFalse(ClaudeUsageRefreshPolicy.canReuse(
            limits,
            now: fetchedAt.addingTimeInterval(300)
        ))
        XCTAssertFalse(ClaudeUsageRefreshPolicy.canReuse(ProfileRateLimits(), now: fetchedAt))
    }

    func testRateLimitCooldownUsesProviderDelayWithOneMinuteMinimum() {
        XCTAssertEqual(ClaudeUsageRefreshPolicy.rateLimitCooldown(retryAfter: nil), 300)
        XCTAssertEqual(ClaudeUsageRefreshPolicy.rateLimitCooldown(retryAfter: 15), 60)
        XCTAssertEqual(ClaudeUsageRefreshPolicy.rateLimitCooldown(retryAfter: 600), 600)
    }

    // MARK: - Claude Code projection

    private static let fixtureA = Data(#"""
    {"five_hour":{"utilization":12.5,"resets_at":"2099-01-01T05:00:00.000Z"},
     "seven_day":{"utilization":41,"resets_at":"2099-01-07T00:00:00Z"},
     "seven_day_opus":null,"seven_day_sonnet":null,"seven_day_omelette":null,
     "limits":[
      {"kind":"weekly_all","group":"weekly","percent":41,"resets_at":"2099-01-07T00:00:00Z","scope":null},
      {"kind":"weekly_scoped","group":"weekly","percent":2,"severity":"normal","resets_at":"2099-01-08T00:00:00Z",
       "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false},
      {"kind":"weekly_scoped","group":"weekly","percent":64,"scope":{"model":{"id":"claude-sonnet-5","display_name":"Sonnet"}}},
      {"kind":"weekly_scoped","group":"weekly","percent":80,"scope":{"model":{"id":null,"display_name":"Design"}}}],
     "extra_usage":{"is_enabled":true,"used_credits":525,"monthly_limit":2000}}
    """#.utf8)

    func testClaudeCodeProjectionMapsSessionWeeklyAndFableOnly() throws {
        let limits = try ClaudeUsageResponseParser.parseClaudeCode(
            Self.fixtureA,
            planType: "max",
            fetchedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(limits.planType, "max")
        XCTAssertEqual(limits.fetchedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(limits.buckets.map(\.id), ["claude", "model-fable"])
        XCTAssertEqual(limits.buckets[0].primary?.usedPercent, 12.5)
        XCTAssertEqual(limits.buckets[0].primary?.windowDurationMins, 300)
        XCTAssertEqual(limits.buckets[0].secondary?.usedPercent, 41)
        XCTAssertEqual(limits.buckets[0].secondary?.windowDurationMins, 10_080)
        XCTAssertEqual(limits.buckets[1].name, "Fable")
        XCTAssertEqual(limits.buckets[1].primary?.usedPercent, 2)
        XCTAssertEqual(limits.buckets[1].primary?.windowDurationMins, 10_080)
        XCTAssertEqual(limits.buckets[1].primary?.resetsAt, try Self.date("2099-01-08T00:00:00Z"))
        XCTAssertNil(limits.buckets[1].secondary)
        XCTAssertNil(limits.credits)
    }

    func testDesktopProjectionOfSameResponseIsUnchanged() throws {
        let limits = try ClaudeUsageResponseParser.parse(Self.fixtureA, planType: "max")

        XCTAssertEqual(
            limits.buckets.map(\.id),
            ["claude", "model-fable", "model-sonnet", "model-design"]
        )
        XCTAssertEqual(limits.credits?.balance, "$5.25 of $20.00 used")
    }

    func testClaudeCodeFableFallsBackToLegacySevenDayFable() throws {
        let limits = try ClaudeUsageResponseParser.parseClaudeCode(Data(#"""
        {"five_hour":null,
         "seven_day":{"utilization":30,"resets_at":"2099-01-07T00:00:00Z"},
         "seven_day_fable":{"utilization":17,"resets_at":"2099-01-06T00:00:00Z"}}
        """#.utf8))

        XCTAssertEqual(limits.buckets.map(\.id), ["claude", "model-fable"])
        XCTAssertNil(limits.buckets[0].primary)
        XCTAssertEqual(limits.buckets[0].secondary?.usedPercent, 30)
        XCTAssertEqual(limits.buckets[1].primary?.usedPercent, 17)
        XCTAssertEqual(limits.buckets[1].primary?.resetsAt, try Self.date("2099-01-06T00:00:00Z"))
    }

    func testClaudeCodeFableLimitsOverrideLegacyKey() throws {
        let limits = try ClaudeUsageResponseParser.parseClaudeCode(Data(#"""
        {"five_hour":null,
         "seven_day":{"utilization":30,"resets_at":"2099-01-07T00:00:00Z"},
         "seven_day_fable":{"utilization":17,"resets_at":"2099-01-06T00:00:00Z"},
         "limits":[{"kind":"weekly_scoped","group":"weekly","percent":9,"resets_at":"2099-01-05T00:00:00Z",
                    "scope":{"model":{"display_name":"Fable"}}}]}
        """#.utf8))

        let fable = try XCTUnwrap(limits.buckets.first { $0.id == "model-fable" })
        XCTAssertEqual(fable.primary?.usedPercent, 9)
        XCTAssertEqual(fable.primary?.resetsAt, try Self.date("2099-01-05T00:00:00Z"))
    }

    func testClaudeCodeOmitsFableWhenAbsent() throws {
        let limits = try ClaudeUsageResponseParser.parseClaudeCode(Data(#"""
        {"five_hour":{"utilization":5},"seven_day":{"utilization":6},
         "limits":[{"kind":"weekly_all","group":"weekly","percent":6,"scope":null}]}
        """#.utf8))

        XCTAssertEqual(limits.buckets.map(\.id), ["claude"])
        XCTAssertEqual(limits.buckets[0].primary?.usedPercent, 5)
        XCTAssertEqual(limits.buckets[0].secondary?.usedPercent, 6)
    }

    func testClaudeCodeFableMatchesVersionedNameAndModelIDTakingHighest() throws {
        let limits = try ClaudeUsageResponseParser.parseClaudeCode(Data(#"""
        {"seven_day":{"utilization":1},
         "limits":[
          {"kind":"weekly_scoped","group":"weekly","percent":11,"scope":{"model":{"display_name":"Fable 5.2"}}},
          {"kind":"weekly_scoped","group":"weekly","percent":23,"scope":{"model":{"id":"claude-fable-5-1","display_name":"Preview"}}},
          {"kind":"weekly_scoped","group":"weekly","percent":99,"scope":{"model":{"display_name":"Fableish"}}},
          {"kind":"weekly_scoped","group":"weekly","percent":50,"scope":{"model":{"id":"claude-opus-5","display_name":"Opus"}}}]}
        """#.utf8))

        XCTAssertEqual(limits.buckets.map(\.id), ["claude", "model-fable"])
        XCTAssertEqual(limits.buckets[1].primary?.usedPercent, 23)
        XCTAssertTrue(ClaudeUsageResponseParser.isFableModel(["display_name": " Fable "]))
        XCTAssertFalse(ClaudeUsageResponseParser.isFableModel(["display_name": "Fableish"]))
        XCTAssertFalse(ClaudeUsageResponseParser.isFableModel(["id": NSNull(), "display_name": "Opus"]))
    }

    func testClaudeCodeFableIgnoresBoolStringWrongKindAndGroup() throws {
        let rejected = #"""
          {"kind":"weekly_scoped","group":"weekly","percent":true,"scope":{"model":{"display_name":"Fable"}}},
          {"kind":"weekly_scoped","group":"weekly","percent":"50","scope":{"model":{"display_name":"Fable"}}},
          {"kind":"weekly_all","group":"weekly","percent":40,"scope":{"model":{"display_name":"Fable"}}},
          {"kind":"weekly_scoped","group":"daily","percent":45,"scope":{"model":{"display_name":"Fable"}}},
          {"kind":"weekly_scoped","group":"weekly","scope":{"model":{"display_name":"Fable"}}}
        """#
        let withoutValid = try ClaudeUsageResponseParser.parseClaudeCode(Data(#"""
        {"seven_day":{"utilization":1},"limits":[\#(rejected)]}
        """#.utf8))
        XCTAssertEqual(withoutValid.buckets.map(\.id), ["claude"])

        let withValid = try ClaudeUsageResponseParser.parseClaudeCode(Data(#"""
        {"seven_day":{"utilization":1},"limits":[\#(rejected),
          {"kind":"weekly_scoped","percent":7,"scope":{"model":{"display_name":"Fable"}}}]}
        """#.utf8))
        XCTAssertEqual(withValid.buckets.map(\.id), ["claude", "model-fable"])
        XCTAssertEqual(withValid.buckets[1].primary?.usedPercent, 7)
    }

    func testClaudeCodeRejectsNonObjectResponse() {
        XCTAssertThrowsError(try ClaudeUsageResponseParser.parseClaudeCode(Data("[]".utf8)))
    }

    // MARK: - Refresh policy

    func testRetryAfterParsesDeltaSecondsAndHTTPDate() throws {
        let target = try XCTUnwrap(ISO8601DateFormatter().date(from: "2099-10-21T07:28:00Z"))

        XCTAssertEqual(ClaudeUsageRefreshPolicy.retryAfter("120", now: target), 120)
        XCTAssertEqual(ClaudeUsageRefreshPolicy.retryAfter(" 120 ", now: target), 120)
        XCTAssertEqual(
            try XCTUnwrap(ClaudeUsageRefreshPolicy.retryAfter(
                "Wed, 21 Oct 2099 07:28:00 GMT",
                now: target.addingTimeInterval(-90)
            )),
            90,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ClaudeUsageRefreshPolicy.retryAfter("Wed, 21 Oct 2015 07:28:00 GMT", now: target),
            0
        )
        XCTAssertNil(ClaudeUsageRefreshPolicy.retryAfter("-5", now: target))
        XCTAssertNil(ClaudeUsageRefreshPolicy.retryAfter("soon", now: target))
        XCTAssertNil(ClaudeUsageRefreshPolicy.retryAfter("", now: target))
        XCTAssertNil(ClaudeUsageRefreshPolicy.retryAfter(nil, now: target))
        XCTAssertEqual(ClaudeUsageRefreshPolicy.rateLimitCooldown(retryAfter: 86_400), 3_600)
    }

    func testManualRefreshBypassesFreshnessButNotRateLimitCooldown() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        func gate(
            lastSuccess: TimeInterval? = nil,
            failureRetry: TimeInterval? = nil,
            rateLimited: TimeInterval? = nil,
            force: Bool
        ) -> ClaudeUsageGate {
            ClaudeUsageRefreshPolicy.gate(
                now: now,
                lastSuccessAt: lastSuccess.map { now.addingTimeInterval(-$0) },
                failureRetryAt: failureRetry.map { now.addingTimeInterval($0) },
                rateLimitedUntil: rateLimited.map { now.addingTimeInterval($0) },
                forceRefresh: force
            )
        }

        XCTAssertEqual(gate(lastSuccess: 100, force: true), .fetch)
        XCTAssertEqual(gate(lastSuccess: 10, force: true), .reuseCached)
        XCTAssertEqual(
            gate(lastSuccess: 100, rateLimited: 200, force: true),
            .rateLimited(until: now.addingTimeInterval(200))
        )
        XCTAssertEqual(gate(failureRetry: 30, force: true), .fetch)
        XCTAssertEqual(gate(lastSuccess: 299, force: false), .reuseCached)
        XCTAssertEqual(gate(lastSuccess: 300, force: false), .fetch)
        XCTAssertEqual(gate(failureRetry: 30, force: false), .backingOff)
        XCTAssertEqual(gate(rateLimited: -1, force: true), .fetch)
    }

    // MARK: - Claude Code client

    private typealias Fixture = ClaudeLoginFixture
    private let tokenPath = ScriptedClaudeTransport.tokenPath
    private let profilePath = ScriptedClaudeTransport.profilePath
    private let usagePath = ScriptedClaudeTransport.usagePath

    func testUnauthorizedUsageRenewsOnceAndRetries() async throws {
        let store = InMemoryClaudeLoginStore(Fixture.tokens())
        let transport = ScriptedClaudeTransport()
        await transport.enqueue(profilePath, Fixture.profileReply, Fixture.profileReply)
        await transport.enqueue(usagePath, .json(401, "{}"), Fixture.usageReply)
        await transport.enqueue(
            tokenPath,
            Fixture.tokenReply(access: "synthetic-access-b", refresh: "synthetic-refresh-b")
        )
        let login = ClaudeCodeLogin(store: store, transport: transport)
        let client = try makeClient(transport: transport)

        let limits = await client.fetchClaudeCodeUsage(login: login, allowKeychainInteraction: false, forceRefresh: true)

        XCTAssertNil(limits.errorMessage)
        XCTAssertEqual(limits.buckets.map(\.id), ["claude"])
        let paths = await transport.paths
        XCTAssertEqual(paths, [profilePath, usagePath, tokenPath, profilePath, usagePath])
        let authorizations = await transport.requests
            .filter { $0.url?.path == usagePath }
            .map { $0.value(forHTTPHeaderField: "Authorization") }
        XCTAssertEqual(authorizations, ["Bearer synthetic-access-a", "Bearer synthetic-access-b"])
        XCTAssertEqual(store.tokens?.accessToken, "synthetic-access-b")
        XCTAssertEqual(store.tokens?.refreshToken, "synthetic-refresh-b")
    }

    func testSecondUnauthorizedSignsOut() async throws {
        let store = InMemoryClaudeLoginStore(Fixture.tokens())
        let transport = ScriptedClaudeTransport()
        await transport.enqueue(profilePath, Fixture.profileReply, Fixture.profileReply)
        await transport.enqueue(usagePath, .json(401, "{}"), .json(401, "{}"))
        await transport.enqueue(tokenPath, Fixture.tokenReply(access: "synthetic-access-b"))
        let login = ClaudeCodeLogin(store: store, transport: transport)
        let client = try makeClient(transport: transport)

        let limits = await client.fetchClaudeCodeUsage(login: login, allowKeychainInteraction: false, forceRefresh: true)

        XCTAssertEqual(limits.errorMessage, ClaudeCodeUsageMessage.signInExpired)
        XCTAssertTrue(limits.buckets.isEmpty)
        let tokenRequests = await transport.count(tokenPath)
        XCTAssertEqual(tokenRequests, 1)
        XCTAssertNil(store.tokens)
        let status = await login.status()
        XCTAssertEqual(status, .signedOut(expired: true))
    }

    func testRefusedRenewalAfterUnauthorizedSignsOut() async throws {
        let store = InMemoryClaudeLoginStore(Fixture.tokens())
        let transport = ScriptedClaudeTransport()
        await transport.enqueue(profilePath, Fixture.profileReply)
        await transport.enqueue(usagePath, .json(401, "{}"))
        await transport.enqueue(tokenPath, Fixture.errorReply(400, "invalid_grant"))
        let login = ClaudeCodeLogin(store: store, transport: transport)
        let client = try makeClient(transport: transport)

        let limits = await client.fetchClaudeCodeUsage(login: login, allowKeychainInteraction: false, forceRefresh: true)

        XCTAssertEqual(limits.errorMessage, ClaudeCodeUsageMessage.signInExpired)
        XCTAssertNil(store.tokens)
        let status = await login.status()
        XCTAssertEqual(status, .signedOut(expired: true))

        // Signed out: the next pass sends nothing.
        let next = await client.fetchClaudeCodeUsage(login: login, allowKeychainInteraction: false, forceRefresh: true)
        XCTAssertEqual(next.errorMessage, ClaudeCodeUsageMessage.signInExpired)
        let requests = await transport.requests.count
        XCTAssertEqual(requests, 3)
    }

    func testTokenEndpointOutageAfterUnauthorizedKeepsLogin() async throws {
        let original = Fixture.tokens()
        let store = InMemoryClaudeLoginStore(original)
        let transport = ScriptedClaudeTransport()
        await transport.enqueue(profilePath, Fixture.profileReply)
        await transport.enqueue(usagePath, .json(401, "{}"))
        await transport.enqueue(tokenPath, .json(503, ""))
        let login = ClaudeCodeLogin(store: store, transport: transport)
        let client = try makeClient(transport: transport)

        let limits = await client.fetchClaudeCodeUsage(login: login, allowKeychainInteraction: false, forceRefresh: true)

        XCTAssertEqual(limits.errorMessage, ClaudeCodeUsageMessage.renewalUnavailable)
        XCTAssertEqual(store.tokens, original)

        // A manual refresh skips the 60-second backoff and renews again.
        await transport.enqueue(profilePath, Fixture.profileReply, Fixture.profileReply)
        await transport.enqueue(usagePath, .json(401, "{}"), Fixture.usageReply)
        await transport.enqueue(tokenPath, Fixture.tokenReply(access: "synthetic-access-b"))
        let retried = await client.fetchClaudeCodeUsage(login: login, allowKeychainInteraction: false, forceRefresh: true)

        XCTAssertNil(retried.errorMessage)
        XCTAssertEqual(retried.buckets.map(\.id), ["claude"])
        let tokenRequests = await transport.count(tokenPath)
        XCTAssertEqual(tokenRequests, 2)
        XCTAssertEqual(store.tokens?.accessToken, "synthetic-access-b")
    }

    func testAccountKeyedCooldownSurvivesTokenChangeAndNewClient() async throws {
        let defaults = try makeDefaults()
        let store = InMemoryClaudeLoginStore(Fixture.tokens(access: "synthetic-access-a"))
        let firstTransport = ScriptedClaudeTransport()
        await firstTransport.enqueue(profilePath, Fixture.profileReply)
        await firstTransport.enqueue(usagePath, .json(429, "{}", headers: ["Retry-After": "600"]))
        let first = ClaudeUsageClient(
            cooldowns: ClaudeUsageCooldownStore(defaults: defaults),
            transport: firstTransport,
            claudeCodeRequestSpacing: .zero
        )
        let limited = await first.fetchClaudeCodeUsage(
            login: ClaudeCodeLogin(store: store, transport: firstTransport),
            allowKeychainInteraction: false,
            forceRefresh: true
        )
        XCTAssertEqual(limited.errorMessage, "Live usage is rate limited. Try again later.")

        // A renewed token for the same account, read by a new client (as after relaunch).
        store.replace(Fixture.tokens(access: "synthetic-access-b", refresh: "synthetic-refresh-b"))
        let secondTransport = ScriptedClaudeTransport()
        let second = ClaudeUsageClient(
            cooldowns: ClaudeUsageCooldownStore(defaults: defaults),
            transport: secondTransport,
            claudeCodeRequestSpacing: .zero
        )
        let limits = await second.fetchClaudeCodeUsage(
            login: ClaudeCodeLogin(store: store, transport: secondTransport),
            allowKeychainInteraction: false,
            forceRefresh: true
        )

        XCTAssertEqual(limits.errorMessage, "Live usage is rate limited. Try again later.")
        XCTAssertEqual(limits.planType, "max")
        XCTAssertTrue(limits.buckets.isEmpty)
        let requests = await secondTransport.requests.count
        XCTAssertEqual(requests, 0)

        let stored = String(describing: defaults.dictionaryRepresentation())
        for secret in ["synthetic-access-a", "synthetic-access-b", Fixture.account, Fixture.organization] {
            XCTAssertFalse(stored.contains(secret))
        }
        let data = try XCTUnwrap(defaults.data(forKey: "AgentDock.claudeUsage.rateLimitCooldowns"))
        let keys = try JSONDecoder().decode([String: Double].self, from: data).keys
        XCTAssertFalse(keys.isEmpty)
        XCTAssertTrue(keys.allSatisfy(ClaudeUsageCooldownStore.isDigest))
    }

    func testNotSignedInSendsNoRequest() async throws {
        let transport = ScriptedClaudeTransport()
        let login = ClaudeCodeLogin(store: InMemoryClaudeLoginStore(), transport: transport)
        let client = try makeClient(transport: transport)

        let limits = await client.fetchClaudeCodeUsage(login: login, allowKeychainInteraction: false, forceRefresh: true)

        XCTAssertEqual(limits.errorMessage, ClaudeCodeUsageMessage.notSignedIn)
        let requests = await transport.requests.count
        XCTAssertEqual(requests, 0)

        // Without any accounts at all, the section lists none and sends nothing.
        let withoutAccounts = ClaudeUsageClient(
            cooldowns: ClaudeUsageCooldownStore(defaults: try makeDefaults()),
            transport: transport
        )
        let none = await withoutAccounts.fetchClaudeCodeUsage(allowKeychainInteraction: false, forceRefresh: true)
        XCTAssertEqual(none, ClaudeCodeUsageReport())
        let emptyRegistry = try makeClient(
            accounts: ClaudeCodeAccounts(store: InMemoryClaudeLoginAccounts(), transport: transport),
            transport: transport
        )
        let empty = await emptyRegistry.fetchClaudeCodeUsage(allowKeychainInteraction: false, forceRefresh: true)
        XCTAssertTrue(empty.accounts.isEmpty)
        XCTAssertFalse(empty.keychainAccessRequired)
        let afterwards = await transport.requests.count
        XCTAssertEqual(afterwards, 0)
    }

    func testForgetClaudeCodeUsageDropsCache() async throws {
        let transport = ScriptedClaudeTransport()
        await transport.enqueue(profilePath, Fixture.profileReply)
        await transport.enqueue(usagePath, Fixture.usageReply, Fixture.usageReply)
        let login = ClaudeCodeLogin(store: InMemoryClaudeLoginStore(Fixture.tokens()), transport: transport)
        let client = try makeClient(transport: transport)

        let first = await client.fetchClaudeCodeUsage(login: login, allowKeychainInteraction: false, forceRefresh: false)
        XCTAssertFalse(first.buckets.isEmpty)
        _ = await client.fetchClaudeCodeUsage(login: login, allowKeychainInteraction: false, forceRefresh: false)
        let cachedCount = await transport.count(usagePath)
        XCTAssertEqual(cachedCount, 1)

        await client.forgetClaudeCodeUsage()
        let refetched = await client.fetchClaudeCodeUsage(login: login, allowKeychainInteraction: false, forceRefresh: false)
        XCTAssertFalse(refetched.buckets.isEmpty)
        let usageCount = await transport.count(usagePath)
        XCTAssertEqual(usageCount, 2)
    }

    // MARK: - Multiple Claude Code accounts

    func testEachAccountGetsItsOwnCardAndOneFailureHidesNoOther() async throws {
        let transport = ScriptedClaudeTransport()
        let first = Fixture.tokens(addedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let second = Fixture.secondTokens()
        let third = Fixture.thirdTokens()
        await enqueueProfile(transport, first)
        await enqueueProfile(transport, second)
        await enqueueProfile(transport, third)
        await transport.enqueue(usagePath, token: first.accessToken, Fixture.usageReply)
        await transport.enqueue(usagePath, token: second.accessToken, .json(500, "{}"))
        await transport.enqueue(usagePath, token: third.accessToken, .json(429, "{}", headers: ["Retry-After": "600"]))
        let store = InMemoryClaudeLoginAccounts(accounts: [third, first, second])
        let client = try makeClient(accounts: ClaudeCodeAccounts(store: store, transport: transport), transport: transport)

        let report = await client.fetchClaudeCodeUsage(allowKeychainInteraction: false, forceRefresh: false)

        XCTAssertFalse(report.keychainAccessRequired)
        // Ordered by when each account was added.
        XCTAssertEqual(report.accounts.map(\.key), [first.accountKey, second.accountKey, third.accountKey])
        XCTAssertEqual(report.accounts.map(\.title), [Fixture.email, Fixture.secondEmail, Fixture.thirdEmail])
        XCTAssertTrue(report.accounts.allSatisfy { $0.status.isSignedIn })

        let ok = report.accounts[0]
        XCTAssertNil(ok.limits?.errorMessage)
        XCTAssertEqual(ok.limits?.buckets.map(\.id), ["claude"])
        XCTAssertNil(ok.rateLimitedUntil)

        let failed = report.accounts[1]
        XCTAssertEqual(failed.limits?.errorMessage, "Live usage request failed (HTTP 500).")
        XCTAssertNil(failed.rateLimitedUntil)

        let limited = report.accounts[2]
        XCTAssertEqual(limited.limits?.errorMessage, "Live usage is rate limited. Try again later.")
        let until = try XCTUnwrap(limited.rateLimitedUntil)
        XCTAssertEqual(until.timeIntervalSinceNow, 600, accuracy: 5)

        // Each account used only its own token.
        for tokens in [first, second, third] {
            let usage = await transport.count(usagePath, token: tokens.accessToken)
            XCTAssertEqual(usage, 1)
        }
    }

    func testOneAccountsRateLimitDoesNotBlockAnother() async throws {
        let transport = ScriptedClaudeTransport()
        let first = Fixture.tokens()
        let second = Fixture.secondTokens()
        await enqueueProfile(transport, first)
        await enqueueProfile(transport, second)
        await transport.enqueue(usagePath, token: first.accessToken, .json(429, "{}", headers: ["Retry-After": "900"]))
        await transport.enqueue(usagePath, token: second.accessToken, Fixture.usageReply, Fixture.usageReply)
        let store = InMemoryClaudeLoginAccounts(accounts: [first, second])
        let defaults = try makeDefaults()
        let client = ClaudeUsageClient(
            cooldowns: ClaudeUsageCooldownStore(defaults: defaults),
            transport: transport,
            claudeCodeAccounts: ClaudeCodeAccounts(store: store, transport: transport),
            claudeCodeRequestSpacing: .zero
        )

        _ = await client.fetchClaudeCodeUsage(allowKeychainInteraction: false, forceRefresh: true)
        let firstKey = first.accountKey
        let secondKey = second.accountKey
        let limitedAgain = await client.fetchClaudeCodeUsage(
            accountKey: firstKey,
            allowKeychainInteraction: false,
            forceRefresh: true
        )
        XCTAssertEqual(limitedAgain?.limits?.errorMessage, "Live usage is rate limited. Try again later.")
        XCTAssertNotNil(limitedAgain?.rateLimitedUntil)
        let firstUsage = await transport.count(usagePath, token: first.accessToken)
        XCTAssertEqual(firstUsage, 1, "the cooldown blocks the limited account's manual refresh")

        await client.forgetClaudeCodeUsage(accountKey: secondKey)
        let other = await client.fetchClaudeCodeUsage(
            accountKey: secondKey,
            allowKeychainInteraction: false,
            forceRefresh: true
        )
        XCTAssertNil(other?.limits?.errorMessage)
        XCTAssertNil(other?.rateLimitedUntil)
        let secondUsage = await transport.count(usagePath, token: second.accessToken)
        XCTAssertEqual(secondUsage, 2, "the other account still fetches")

        // Cooldowns are persisted per account identity digest.
        let cooldowns = ClaudeUsageCooldownStore(defaults: defaults)
        let firstDigest = ClaudeUsageCredential.cooldownKey(identity: first.identity, projection: .claudeCode)
        let secondDigest = ClaudeUsageCredential.cooldownKey(identity: second.identity, projection: .claudeCode)
        XCTAssertNotNil(cooldowns.blockedUntil(key: firstDigest, now: Date()))
        XCTAssertNil(cooldowns.blockedUntil(key: secondDigest, now: Date()))
    }

    func testHourlyBudgetIsPerAccount() async throws {
        let transport = ScriptedClaudeTransport()
        let first = Fixture.tokens()
        let second = Fixture.secondTokens()
        await enqueueProfile(transport, first)
        await enqueueProfile(transport, second)
        for _ in 0..<ClaudeUsageRequestBudget.limit {
            // Server errors skip the manual floor, so each refresh fetches again.
            await transport.enqueue(usagePath, token: first.accessToken, .json(500, "{}"))
        }
        await transport.enqueue(usagePath, token: second.accessToken, Fixture.usageReply)
        let store = InMemoryClaudeLoginAccounts(accounts: [first, second])
        let registry = ClaudeCodeAccounts(store: store, transport: transport)
        let client = try makeClient(accounts: registry, transport: transport)
        let firstKey = first.accountKey
        // Single-account fetches resolve only accounts the registry has listed,
        // as the app does at launch. Listing sends no requests.
        let listing = await registry.list()
        XCTAssertEqual(listing.accounts.map(\.key), [firstKey, second.accountKey])
        let listingRequests = await transport.requests.count
        XCTAssertEqual(listingRequests, 0)

        for _ in 0..<ClaudeUsageRequestBudget.limit {
            let result = await client.fetchClaudeCodeUsage(
                accountKey: firstKey,
                allowKeychainInteraction: false,
                forceRefresh: true
            )
            let failed = try XCTUnwrap(result, "a listed account must resolve")
            XCTAssertEqual(failed.limits?.errorMessage, "Live usage request failed (HTTP 500).")
        }
        let spent = await client.fetchClaudeCodeUsage(
            accountKey: firstKey,
            allowKeychainInteraction: false,
            forceRefresh: true
        )
        XCTAssertEqual(spent?.limits?.errorMessage, ClaudeUsageClient.budgetError)
        let retry = try XCTUnwrap(spent?.rateLimitedUntil)
        XCTAssertEqual(retry.timeIntervalSinceNow, ClaudeUsageRequestBudget.window, accuracy: 30)
        let firstUsage = await transport.count(usagePath, token: first.accessToken)
        XCTAssertEqual(firstUsage, ClaudeUsageRequestBudget.limit)

        let other = await client.fetchClaudeCodeUsage(
            accountKey: second.accountKey,
            allowKeychainInteraction: false,
            forceRefresh: true
        )
        XCTAssertNotNil(other, "the second account must resolve")
        XCTAssertNil(other?.limits?.errorMessage)
        XCTAssertEqual(other?.limits?.buckets.map(\.id), ["claude"])
        XCTAssertNil(other?.rateLimitedUntil, "the first account's spent budget does not block the second")
        let secondUsage = await transport.count(usagePath, token: second.accessToken)
        XCTAssertEqual(secondUsage, 1)
    }

    func testFetchingAllAccountsStaggersStartsAndRunsAtMostTwo() async throws {
        let transport = ScriptedClaudeTransport()
        let accounts = [Fixture.tokens(), Fixture.secondTokens(), Fixture.thirdTokens()]
        for tokens in accounts {
            await enqueueProfile(transport, tokens)
            await transport.enqueue(usagePath, token: tokens.accessToken, Fixture.usageReply)
        }
        await transport.hold(usagePath)
        let store = InMemoryClaudeLoginAccounts(accounts: accounts)
        let spacing = Duration.milliseconds(150)
        let client = ClaudeUsageClient(
            cooldowns: ClaudeUsageCooldownStore(defaults: try makeDefaults()),
            transport: transport,
            claudeCodeAccounts: ClaudeCodeAccounts(store: store, transport: transport),
            claudeCodeRequestSpacing: spacing
        )

        let pass = Task { await client.fetchClaudeCodeUsage(allowKeychainInteraction: false, forceRefresh: false) }
        let twoHeld = await eventually { await transport.heldCount == 2 }
        XCTAssertTrue(twoHeld)
        // The third account waits for a slot while two requests are in flight.
        try await Task.sleep(for: .milliseconds(400))
        let stillTwo = await transport.heldCount
        XCTAssertEqual(stillTwo, 2)
        let profilesSoFar = await transport.count(profilePath)
        XCTAssertEqual(profilesSoFar, 2)
        await transport.release()

        let report = await pass.value
        XCTAssertEqual(report.accounts.count, 3)
        XCTAssertTrue(report.accounts.allSatisfy { $0.limits?.errorMessage == nil })
        let maximum = await transport.maximumInFlight
        XCTAssertLessThanOrEqual(maximum, 2)
        let perAccount = await transport.maximumInFlightPerAuthorization
        XCTAssertEqual(perAccount, 1)

        // Each account's first request starts at least one spacing after the previous one.
        let recorded = await transport.starts
        let profile = profilePath
        let starts = recorded.filter { $0.path == profile }.map(\.at)
        XCTAssertEqual(starts.count, 3)
        for (earlier, later) in zip(starts, starts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later - earlier, spacing - .milliseconds(20))
        }
    }

    func testOneAccountNeverHasTwoRequestsInFlight() async throws {
        let transport = ScriptedClaudeTransport()
        let tokens = Fixture.tokens()
        await enqueueProfile(transport, tokens)
        await transport.enqueue(usagePath, token: tokens.accessToken, Fixture.usageReply, Fixture.usageReply)
        await transport.hold(usagePath)
        let login = ClaudeCodeLogin(store: InMemoryClaudeLoginStore(tokens), transport: transport)
        let client = try makeClient(transport: transport)

        async let first = client.fetchClaudeCodeUsage(login: login, allowKeychainInteraction: false, forceRefresh: true)
        async let second = client.fetchClaudeCodeUsage(login: login, allowKeychainInteraction: false, forceRefresh: true)
        let held = await eventually { await transport.heldCount == 1 }
        XCTAssertTrue(held)
        try await Task.sleep(for: .milliseconds(100))
        let stillOne = await transport.heldCount
        XCTAssertEqual(stillOne, 1)
        await transport.release()

        let (a, b) = await (first, second)
        XCTAssertEqual(a.buckets.map(\.id), ["claude"])
        // The waiting refresh runs afterwards and reuses the fresh result.
        XCTAssertEqual(b, a)
        let usage = await transport.count(usagePath)
        XCTAssertEqual(usage, 1)
        let perAccount = await transport.maximumInFlightPerAuthorization
        XCTAssertEqual(perAccount, 1)
    }

    func testLegacyCooldownStillAppliesAfterMigration() async throws {
        let defaults = try makeDefaults()
        let legacy = Fixture.tokens()
        // A cooldown recorded before multiple accounts were supported.
        ClaudeUsageCooldownStore(defaults: defaults).record(
            key: legacy.usageCredential.cooldownKey(for: .claudeCode),
            until: Date().addingTimeInterval(900),
            now: Date()
        )
        let transport = ScriptedClaudeTransport()
        let store = InMemoryClaudeLoginAccounts(legacy: legacy)
        let client = ClaudeUsageClient(
            cooldowns: ClaudeUsageCooldownStore(defaults: defaults),
            transport: transport,
            claudeCodeAccounts: ClaudeCodeAccounts(store: store, transport: transport),
            claudeCodeRequestSpacing: .zero
        )

        let report = await client.fetchClaudeCodeUsage(allowKeychainInteraction: false, forceRefresh: true)

        XCTAssertEqual(report.accounts.map(\.key), [legacy.accountKey])
        XCTAssertEqual(report.accounts.first?.limits?.errorMessage, "Live usage is rate limited. Try again later.")
        XCTAssertNotNil(report.accounts.first?.rateLimitedUntil)
        XCTAssertNil(store.tokens(.legacy))
        let requests = await transport.requests.count
        XCTAssertEqual(requests, 0)
    }

    private func enqueueProfile(_ transport: ScriptedClaudeTransport, _ tokens: ClaudeLoginTokens) async {
        await transport.enqueue(
            profilePath,
            token: tokens.accessToken,
            Fixture.profileReply(
                account: tokens.accountUUID,
                organization: tokens.organizationUUID,
                email: tokens.accountLabel
            )
        )
    }

    private func makeClient(
        accounts: ClaudeCodeAccounts? = nil,
        transport: ScriptedClaudeTransport
    ) throws -> ClaudeUsageClient {
        ClaudeUsageClient(
            cooldowns: ClaudeUsageCooldownStore(defaults: try makeDefaults()),
            transport: transport,
            claudeCodeAccounts: accounts,
            claudeCodeRequestSpacing: .zero
        )
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "AgentDockTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private static func date(_ text: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: text))
    }
}
