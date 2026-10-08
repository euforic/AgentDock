import XCTest
@testable import CodexerCore

final class RateLimitParserTests: XCTestCase {
    func testParsesCodexRateLimitWindows() throws {
        let json = Data("""
        {
          "id": 2,
          "result": {
            "rateLimits": {
              "limitId": "codex",
              "limitName": null,
              "primary": {"usedPercent": 36, "windowDurationMins": 300, "resetsAt": 1780724838},
              "secondary": {"usedPercent": 43, "windowDurationMins": 10080, "resetsAt": 1781185571},
              "credits": {"hasCredits": false, "unlimited": false, "balance": "0"},
              "individualLimit": null,
              "planType": "pro",
              "rateLimitReachedType": null
            },
            "rateLimitsByLimitId": {
              "codex": {
                "limitId": "codex",
                "limitName": null,
                "primary": {"usedPercent": 36, "windowDurationMins": 300, "resetsAt": 1780724838},
                "secondary": {"usedPercent": 43, "windowDurationMins": 10080, "resetsAt": 1781185571},
                "credits": {"hasCredits": false, "unlimited": false, "balance": "0"},
                "individualLimit": null,
                "planType": "pro",
                "rateLimitReachedType": null
              },
              "codex_bengalfox": {
                "limitId": "codex_bengalfox",
                "limitName": "GPT-5.3-Codex-Spark",
                "primary": {"usedPercent": 0, "windowDurationMins": 300, "resetsAt": 1780734580},
                "secondary": {"usedPercent": 0, "windowDurationMins": 10080, "resetsAt": 1781321380},
                "credits": null,
                "individualLimit": null,
                "planType": "pro",
                "rateLimitReachedType": null
              }
            }
          }
        }
        """.utf8)

        let limits = try RateLimitParser.parseResponse(json, fetchedAt: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(limits.planType, "pro")
        XCTAssertEqual(limits.credits?.balance, "0")
        XCTAssertEqual(limits.buckets.count, 1)
        let codex = try XCTUnwrap(limits.buckets.first { $0.id == "codex" })
        XCTAssertEqual(codex.name, "Codex")
        XCTAssertEqual(codex.primary?.usedPercent, 36)
        XCTAssertEqual(codex.primary?.windowDurationMins, 300)
        XCTAssertEqual(codex.secondary?.usedPercent, 43)
        XCTAssertEqual(codex.secondary?.windowDurationMins, 10080)
        XCTAssertFalse(limits.buckets.contains { $0.id == "codex_bengalfox" })
    }

    func testFallsBackToPrimarySnapshotWhenLimitMapIsAbsent() throws {
        let json = Data("""
        {"id":2,"result":{"rateLimits":{"limitId":"codex","planType":"team","primary":{"usedPercent":12}}}}
        """.utf8)

        let limits = try RateLimitParser.parseResponse(json)

        XCTAssertEqual(limits.planType, "team")
        XCTAssertEqual(limits.buckets.count, 1)
        XCTAssertEqual(limits.buckets.first?.primary?.usedPercent, 12)
    }

    func testAcceptsLimitMapWhenLegacyPrimarySnapshotIsAbsent() throws {
        let json = Data("""
        {
          "id": 2,
          "result": {
            "rateLimitsByLimitId": {
              "codex": {
                "limitId": "codex",
                "planType": "pro",
                "primary": {"usedPercent": 27}
              }
            }
          }
        }
        """.utf8)

        let limits = try RateLimitParser.parseResponse(json)

        XCTAssertEqual(limits.planType, "pro")
        XCTAssertEqual(limits.buckets.map(\.id), ["codex"])
        XCTAssertEqual(limits.buckets.first?.primary?.usedPercent, 27)
    }

    func testBusinessPlanAcceptsNullCreditBalanceAndMissingWindows() throws {
        let json = Data("""
        {
          "id": 2,
          "result": {
            "rateLimits": {
              "limitId": "codex",
              "primary": null,
              "secondary": null,
              "credits": {
                "hasCredits": false,
                "unlimited": false,
                "balance": null
              },
              "planType": "business"
            },
            "rateLimitsByLimitId": {
              "codex": {
                "limitId": "codex",
                "primary": null,
                "secondary": null,
                "credits": null,
                "planType": "business"
              }
            }
          }
        }
        """.utf8)

        let limits = try RateLimitParser.parseResponse(json)

        XCTAssertEqual(limits.planType, "business")
        XCTAssertEqual(limits.credits?.balance, "0")
        XCTAssertEqual(limits.buckets.map(\.id), ["codex"])
        XCTAssertNil(limits.buckets.first?.primary)
        XCTAssertNil(limits.buckets.first?.secondary)
        XCTAssertNil(limits.errorMessage)
    }

    func testMissingResultThrows() {
        let json = Data("{\"id\":2,\"result\":null}".utf8)

        XCTAssertThrowsError(try RateLimitParser.parseResponse(json)) { error in
            XCTAssertEqual(error as? RateLimitParserError, .missingResult)
        }
    }
}
