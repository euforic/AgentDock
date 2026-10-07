import XCTest
@testable import CodexerCore

final class CodexAccountDisplayParserTests: XCTestCase {
    func testInstalledCodexAccountDisplayRoundTrip() throws {
        guard ProcessInfo.processInfo.environment["AGENTDOCK_LIVE_RESET_ACCOUNT_DISPLAY"] == "1" else {
            throw XCTSkip("Signed-in installed Codex account check is opt in.")
        }
        let result = AppServerRateLimitClient().fetchRateLimits(
            codexHomeURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
            codexAppURL: URL(fileURLWithPath: "/Applications/Codex.app"), includeAccountDetails: true)
        XCTAssertNil(result.errorMessage)
        XCTAssertNotNil(result.accountEmail, "Signed-in ChatGPT display metadata should arrive with the limits response.")
    }

    func testReadsDisplayEmailOnlyFromChatGPTAccountResponse() {
        let data = Data(#"{"id":3,"result":{"account":{"type":"chatgpt","email":"synthetic@example.com","planType":"pro"}}}"#.utf8)
        XCTAssertEqual(CodexAccountDisplayParser.email(from: data), "synthetic@example.com")
    }

    func testMissingUnsupportedAndFailedAccountsHaveNoDisplayEmail() {
        for json in [#"{"id":3,"result":{"account":null}}"#,
                     #"{"id":3,"result":{"account":{"type":"apiKey","email":"synthetic@example.com"}}}"#,
                     #"{"id":3,"error":{"message":"unavailable"}}"#,
                     #"{"id":3,"result":{"account":{"type":"chatgpt","email":"bad\nlabel"}}}"#] {
            XCTAssertNil(CodexAccountDisplayParser.email(from: Data(json.utf8)))
        }
    }

    func testOldCachedAccountStillDecodesWithoutDisplayMetadata() throws {
        let json = Data(#"{"id":"hash","sourceIDs":["personal"],"identityVerified":true,"detailsAreStale":false,"names":["Personal"],"summary":{"availableCount":0},"checkedAt":100}"#.utf8)
        let account = try JSONDecoder().decode(ResetAccount.self, from: json)
        XCTAssertNil(account.accountEmail)
        XCTAssertNil(account.sourceNames)
        XCTAssertEqual(account.displayName, "Personal")
    }

    func testConsolidatedAliasesRetainNamesAndNeverAddQuota() {
        let credit = ResetCredit(id: "synthetic", grantedAt: Date(), expiresAt: nil)
        var personal = ResetAccount(id: "same-account", sourceIDs: ["personal"], names: ["Personal"],
            summary: .init(availableCount: 1, credits: [credit]), checkedAt: Date(), identityVerified: true)
        personal.accountEmail = "synthetic@example.com"; personal.sourceNames = ["personal": "Personal"]
        var research = personal; research.sourceIDs = ["research"]; research.names = ["Research"]
        research.sourceNames = ["research": "Research"]
        let result = ResetAccount.consolidated([personal, research])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].summary.availableCount, 1)
        XCTAssertEqual(result[0].sourceNames, ["personal": "Personal", "research": "Research"])
        XCTAssertEqual(result[0].accountEmail, "synthetic@example.com")
    }
}
