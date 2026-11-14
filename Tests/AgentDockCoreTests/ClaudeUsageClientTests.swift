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
        XCTAssertEqual(ClaudeUsageRefreshPolicy.rateLimitCooldown(retryAfter: 86_400), 21_600)
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

    func testPersistedCooldownIsHonoredByNewClientAndManualRefresh() async throws {
        let suiteName = "AgentDockTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let token = "synthetic-claude-code-token"
        let location = try makeClaudeCodeLocation(credentials: #"""
        {"claudeAiOauth":{"accessToken":"\#(token)","expiresAt":\#(Self.millisecondsFromNow(3_600)),
         "scopes":["user:profile"],"subscriptionType":"max"}}
        """#)

        let now = Date()
        ClaudeUsageCooldownStore(defaults: defaults).record(
            tokenDigest: ClaudeUsageCredential.digest(token),
            until: now.addingTimeInterval(600),
            now: now
        )

        // A new client (as after relaunch) honors the saved cooldown even when forced.
        let client = ClaudeUsageClient(cooldowns: ClaudeUsageCooldownStore(defaults: defaults))
        let limits = await client.fetchClaudeCodeUsage(
            location: location,
            allowKeychainInteraction: false,
            forceRefresh: true
        )

        XCTAssertEqual(limits.errorMessage, "Live usage is rate limited. Try again later.")
        XCTAssertEqual(limits.planType, "max")
        XCTAssertTrue(limits.buckets.isEmpty)
        let stored = String(describing: defaults.dictionaryRepresentation())
        XCTAssertFalse(stored.contains(token))
    }

    func testClaudeCodeExpiredCredentialShowsGuidance() async throws {
        let suiteName = "AgentDockTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let location = try makeClaudeCodeLocation(credentials: #"""
        {"claudeAiOauth":{"accessToken":"synthetic-claude-code-token","expiresAt":\#(Self.millisecondsFromNow(60)),
         "scopes":["user:profile"],"subscriptionType":"pro"}}
        """#)

        let limits = await ClaudeUsageClient(cooldowns: ClaudeUsageCooldownStore(defaults: defaults))
            .fetchClaudeCodeUsage(location: location, allowKeychainInteraction: false, forceRefresh: true)

        XCTAssertEqual(limits.errorMessage, ClaudeCodeUsageMessage.expired)
        XCTAssertEqual(limits.planType, "pro")
        XCTAssertTrue(limits.buckets.isEmpty)
    }

    func testInstalledClaudeCodeUsageWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["AGENTDOCK_LIVE_CLAUDE_CODE_USAGE_TEST"] == "1" else {
            throw XCTSkip("Set AGENTDOCK_LIVE_CLAUDE_CODE_USAGE_TEST=1 to validate the signed-in Claude Code login.")
        }
        let location = ClaudeCodeLocation.resolve(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let limits = await ClaudeUsageClient().fetchClaudeCodeUsage(
            location: location,
            allowKeychainInteraction: false,
            forceRefresh: true
        )

        XCTAssertNil(limits.errorMessage)
        XCTAssertFalse(limits.buckets.isEmpty)
        XCTAssertTrue(Set(limits.buckets.map(\.id)).isSubset(of: ["claude", "model-fable"]))
        XCTAssertNil(limits.credits)
    }

    private func makeClaudeCodeLocation(credentials: String) throws -> ClaudeCodeLocation {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Data(credentials.utf8).write(to: home.appendingPathComponent(".credentials.json"))
        return ClaudeCodeLocation(
            homeURL: home,
            globalConfigURL: directory.appendingPathComponent(".claude.json"),
            keychainService: nil
        )
    }

    private static func millisecondsFromNow(_ seconds: TimeInterval) -> Int {
        Int((Date().timeIntervalSince1970 + seconds) * 1_000)
    }

    private static func date(_ text: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: text))
    }
}
