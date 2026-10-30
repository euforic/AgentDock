import XCTest
@testable import AgentDockCore

final class LocalChatSessionTests: XCTestCase {
    func testInstalledClaudeHistoryCanBeIndexedWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["AGENTDOCK_INSTALLED_CLAUDE_HISTORY_TEST"] == "1" else {
            throw XCTSkip(
                "Set AGENTDOCK_INSTALLED_CLAUDE_HISTORY_TEST=1 to validate local Claude history metadata."
            )
        }
        let fileManager = FileManager.default
        let userData = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Claude", isDirectory: true)
        let claudeCodeHome = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        let scanner = LocalChatScanner(
            maximumSessions: 1_000,
            indexRootURL: fileManager.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )

        let result = scanner.scanOfficialClaudeForStats(
            claudeHomeURL: userData,
            claudeCodeHomeURL: claudeCodeHome
        )

        XCTAssertFalse(result.sessions.isEmpty)
        XCTAssertTrue(result.sessions.allSatisfy { $0.provider == .claude })
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalChatSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testCoworkHistoryUsesMetadataForStatsSession() throws {
        try makeCoworkFixture()
        let scanner = LocalChatScanner(indexRootURL: root.appendingPathComponent("Indexes"))

        let result = scanStats(scanner, root)
        let session = try XCTUnwrap(result.sessions.first)

        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(session.id, "cowork-session")
        XCTAssertEqual(session.provider, .claude)
        XCTAssertEqual(session.profileName, "Official Claude")
        XCTAssertEqual(session.model, "claude-opus-4-1")
        XCTAssertEqual(session.status, "Unknown")
        XCTAssertEqual(session.tokenCount, 0)
    }

    func testClaudeUsageDeduplicatesMessagesAndKeepsLatestLimitSignal() throws {
        let usage: [String: Any] = [
            "input_tokens": 2,
            "cache_read_input_tokens": 1_000,
            "cache_creation_input_tokens": 66_818,
            "output_tokens": 286
        ]
        let assistant: [String: Any] = [
            "type": "assistant",
            "uuid": "assistant-usage",
            "requestId": "request-1",
            "timestamp": "2026-07-28T10:00:02Z",
            "message": [
                "id": "message-1",
                "model": "claude-opus-4-1",
                "usage": usage,
                "content": [["type": "text", "text": "Done"]]
            ]
        ]
        try makeCoworkFixture(auditRecords: [
            assistant,
            assistant,
            [
                "type": "rate_limit_event",
                "uuid": "limit-1",
                "timestamp": "2026-07-28T10:00:03Z",
                "rate_limit_info": [
                    "status": "allowed_warning",
                    "rateLimitType": "five_hour",
                    "utilization": 0.91,
                    "resetsAt": 1_785_236_400,
                    "isUsingOverage": false
                ]
            ],
            [
                "type": "rate_limit_event",
                "uuid": "limit-2",
                "timestamp": "2026-07-28T10:00:04Z",
                "rate_limit_info": [
                    "status": "allowed",
                    "rateLimitType": "five_hour",
                    "resetsAt": 1_785_240_000,
                    "isUsingOverage": false
                ]
            ]
        ])

        let session = try XCTUnwrap(
            scanStats(LocalChatScanner(indexRootURL: root.appendingPathComponent("Indexes")), root)
                .sessions.first
        )

        XCTAssertEqual(session.tokenCount, 68_106)
        XCTAssertEqual(session.latestUsageLimit?.status, .allowed)
        XCTAssertEqual(session.latestUsageLimit?.bucket, "five_hour")
        XCTAssertNil(session.latestUsageLimit?.usedPercent)
        XCTAssertEqual(
            session.latestUsageLimit?.resetsAt,
            Date(timeIntervalSince1970: 1_785_240_000)
        )
        XCTAssertEqual(session.latestUsageLimit?.isUsingOverage, false)
    }

    func testManagedCoworkHistoryUsesProfileIdentity() throws {
        let profileRoot = root.appendingPathComponent("Profiles", isDirectory: true)
        let profile = CodexProfile(
            product: .claude,
            name: "Claude Work",
            slug: "work",
            rootDirectory: profileRoot,
            shortcutDirectory: root.appendingPathComponent("Shortcuts")
        )
        try makeCoworkFixture(userDataURL: profile.claudeUserDataPath)
        let scanner = LocalChatScanner(indexRootURL: root.appendingPathComponent("Indexes"))

        let result = scanner.scanForStats(profile: profile)

        XCTAssertEqual(result.sessions.first?.profileID, profile.id)
        XCTAssertEqual(result.sessions.first?.profileName, "Claude Work")
        XCTAssertEqual(result.sessions.first?.provider, .claude)
    }

    func testManagedClaudeWithoutLocalAgentHistoryIsEmpty() {
        let profile = CodexProfile(
            product: .claude,
            name: "Claude Work",
            slug: "work",
            rootDirectory: root,
            shortcutDirectory: root.appendingPathComponent("Shortcuts")
        )

        let result = LocalChatScanner(indexRootURL: root.appendingPathComponent("Indexes"))
            .scanForStats(profile: profile)

        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertFalse(result.diagnostics.inventoryTruncated)
    }

    func testOfficialClaudeCodeFallbackUsesBoundedIndexAndSourceMetadata() throws {
        let history = root.appendingPathComponent("history.jsonl")
        try writeJSONLines([
            [
                "display": "Earlier title",
                "pastedContents": [:],
                "project": "/private/work/project",
                "sessionId": "code-session",
                "timestamp": 1_785_232_800_000
            ],
            [
                "display": "Latest title",
                "pastedContents": [:],
                "project": "/private/work/project",
                "sessionId": "code-session",
                "timestamp": 1_785_232_860_000
            ]
        ], to: history)
        let body = root.appendingPathComponent(
            "projects/-private-work-project/code-session.jsonl"
        )
        try FileManager.default.createDirectory(
            at: body.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeJSONLines([
            [
                "type": "user",
                "uuid": "user-event",
                "sessionId": "code-session",
                "timestamp": "2026-07-28T10:00:00Z",
                "cwd": "/private/work/project",
                "gitBranch": "feature/history",
                "message": ["role": "user", "content": "Open the history"]
            ],
            [
                "type": "assistant",
                "uuid": "assistant-event",
                "sessionId": "code-session",
                "timestamp": "2026-07-28T10:00:01Z",
                "message": [
                    "role": "assistant",
                    "model": "claude-sonnet-4",
                    "content": [["type": "text", "text": "History opened."]]
                ]
            ]
        ], to: body)
        let scanner = LocalChatScanner(indexRootURL: root.appendingPathComponent("Indexes"))

        let result = scanStats(scanner, root)
        let session = try XCTUnwrap(result.sessions.first)

        XCTAssertEqual(session.id, "code-session")
        XCTAssertEqual(session.model, "claude-sonnet-4")
        XCTAssertNil(session.tokenCount)
        XCTAssertEqual(session.startedAt, Date(timeIntervalSince1970: 1_785_232_800))
        XCTAssertEqual(session.updatedAt, Date(timeIntervalSince1970: 1_785_232_860))
    }

    func testClaudeInventoryRejectsMetadataAndAuditSymlinkEscapes() throws {
        let outsideMetadata = root.appendingPathComponent("outside.json")
        try Data(#"{"sessionId":"escaped","title":"Must not load"}"#.utf8)
            .write(to: outsideMetadata)
        let metadataLink = root.appendingPathComponent(
            "claude-code-sessions/org/workspace/local_escape.json"
        )
        try FileManager.default.createDirectory(
            at: metadataLink.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: metadataLink,
            withDestinationURL: outsideMetadata
        )
        let scanner = LocalChatScanner(indexRootURL: root.appendingPathComponent("Indexes"))
        XCTAssertTrue(scanStats(scanner, root).sessions.isEmpty)

        let fixture = try makeCoworkFixture()
        XCTAssertEqual(scanStats(scanner, root).sessions.map(\.id), ["cowork-session"])
        let outsideAudit = root.appendingPathComponent("outside-audit.jsonl")
        try writeJSONLines([[
            "type": "assistant",
            "message": ["id": "escaped-message", "usage": ["input_tokens": 999]]
        ]], to: outsideAudit)
        try FileManager.default.removeItem(at: fixture.audit)
        try FileManager.default.createSymbolicLink(
            at: fixture.audit,
            withDestinationURL: outsideAudit
        )

        let escaped = scanStats(scanner, root)

        XCTAssertTrue(escaped.sessions.isEmpty)
        XCTAssertTrue(escaped.diagnostics.inventoryTruncated)
    }

    func testClaudeSessionIDsAreDeterministicAndCollisionsUseNewestSource() throws {
        try makeCoworkFixture(
            fixtureName: "local_old",
            sessionID: "collision-id",
            lastActivityAt: 1_785_232_800_000
        )
        try makeCoworkFixture(
            fixtureName: "local_new",
            sessionID: "collision-id",
            lastActivityAt: 1_785_232_900_000
        )
        try makeCoworkFixture(
            fixtureName: "local_invalid",
            sessionID: "invalid id!",
            lastActivityAt: 1_785_232_850_000
        )
        let scanner = LocalChatScanner(indexRootURL: root.appendingPathComponent("Indexes"))

        let first = scanStats(scanner, root)
        let second = scanStats(scanner, root)

        XCTAssertEqual(first.sessions.filter { $0.id == "collision-id" }.count, 1)
        XCTAssertEqual(
            first.sessions.first { $0.id == "collision-id" }?.updatedAt,
            Date(timeIntervalSince1970: 1_785_232_900)
        )
        let derived = try XCTUnwrap(first.sessions.first { $0.id != "collision-id" }?.id)
        XCTAssertTrue(derived.hasPrefix("claude-local-"))
        XCTAssertEqual(
            derived,
            second.sessions.first { $0.id != "collision-id" }?.id
        )
    }

    func testClaudeUsageSkipsOversizedCompleteLinesAndContinuesReading() throws {
        try makeCoworkFixture(auditRecords: [
            [
                "type": "assistant",
                "message": [
                    "id": "oversized-message",
                    "usage": ["input_tokens": 100],
                    "content": String(repeating: "a", count: 1_024)
                ]
            ],
            [
                "type": "assistant",
                "message": ["id": "bounded-message", "usage": ["input_tokens": 7]]
            ]
        ])
        let scanner = LocalChatScanner(
            maximumSummaryLineBytes: 512,
            indexRootURL: root.appendingPathComponent("Indexes")
        )

        let result = scanStats(scanner, root)

        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions.first?.tokenCount, 7)
        XCTAssertTrue(result.diagnostics.inventoryTruncated)
        XCTAssertTrue(scanStats(scanner, root).diagnostics.inventoryTruncated)
    }

    func testClaudeInventoryBoundsFilesAndAggregateMetadataBytes() throws {
        for index in 0..<5 {
            try makeCoworkFixture(
                fixtureName: "local_\(index)",
                sessionID: "session-\(index)",
                lastActivityAt: 1_785_232_800_000 + Double(index * 1_000)
            )
        }
        let fileBounded = scanStats(LocalChatScanner(
            maximumSessions: 10,
            maximumInventoryFiles: 2,
            indexRootURL: root.appendingPathComponent("Indexes")
        ), root)
        let byteBounded = scanStats(LocalChatScanner(
            maximumSessions: 10,
            maximumInventoryFiles: 10,
            maximumMetadataBytes: 1,
            indexRootURL: root.appendingPathComponent("OtherIndexes")
        ), root)

        XCTAssertLessThanOrEqual(fileBounded.sessions.count, 2)
        XCTAssertLessThanOrEqual(fileBounded.diagnostics.sourceFileCount, 2)
        XCTAssertTrue(byteBounded.sessions.isEmpty)
    }

    func testLargeClaudeCodeHistoryUsesRecentTailAndReusesUnchangedIndex() throws {
        let history = root.appendingPathComponent("history.jsonl")
        let project = "/synthetic/project"
        let oldLine = try JSONSerialization.data(withJSONObject: [
            "display": String(repeating: "x", count: 1_024), "project": project,
            "sessionId": "old-session", "timestamp": 1_785_232_800_000
        ]) + Data([0x0A])
        var data = Data()
        for _ in 0..<16_000 { data.append(oldLine) }
        let recentLine = try JSONSerialization.data(withJSONObject: [
            "display": "Recent session", "project": project,
            "sessionId": "recent-session", "timestamp": 1_785_232_860_000
        ]) + Data([0x0A])
        data.append(recentLine)
        XCTAssertGreaterThan(data.count, 16 * 1_024 * 1_024)
        try data.write(to: history)
        for id in ["old-session", "recent-session"] {
            let body = root.appendingPathComponent("projects/-synthetic-project/\(id).jsonl")
            try FileManager.default.createDirectory(at: body.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeJSONLines([["type": "assistant", "message": ["model": "synthetic-model"]]], to: body)
        }
        let scanner = LocalChatScanner(indexRootURL: root.appendingPathComponent("Indexes"))
        let coldStart = Date()
        let cold = scanStats(scanner, root)
        let coldDuration = Date().timeIntervalSince(coldStart)
        let warmStart = Date()
        let warm = scanStats(scanner, root)
        let warmDuration = Date().timeIntervalSince(warmStart)

        XCTAssertEqual(cold.sessions.first?.id, "recent-session")
        XCTAssertEqual(cold.sessions.first?.model, "synthetic-model")
        XCTAssertEqual(cold.diagnostics.inspectedHistoryBytes, 16 * 1_024 * 1_024)
        XCTAssertTrue(cold.diagnostics.inventoryTruncated)
        XCTAssertEqual(warm.sessions.map(\.id), cold.sessions.map(\.id))
        XCTAssertEqual(warm.diagnostics.inspectedHistoryBytes, 0)
        XCTAssertEqual(warm.diagnostics.cacheHitCount, 1)
        XCTAssertTrue(warm.diagnostics.inventoryTruncated)
        print("Synthetic large history reader: cold=\(coldDuration)s warm=\(warmDuration)s bytes=\(data.count)")
    }

    func testClaudeHistoryCacheInvalidatesAppendRewriteAndSymlinkReplacement() throws {
        let history = root.appendingPathComponent("history.jsonl")
        let body = root.appendingPathComponent("projects/-synthetic-project/session.jsonl")
        try FileManager.default.createDirectory(at: body.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeJSONLines([["type": "assistant", "message": ["model": "synthetic-model"]]], to: body)
        func record(_ timestamp: Double) -> [String: Any] {
            ["display": "Synthetic", "project": "/synthetic/project", "sessionId": "session", "timestamp": timestamp]
        }
        func updatedAt(_ result: LocalChatScanResult) -> TimeInterval? {
            result.sessions.first?.updatedAt.timeIntervalSince1970
        }
        try writeJSONLines([record(1_785_232_860_000)], to: history)
        let scanner = LocalChatScanner(indexRootURL: root.appendingPathComponent("Indexes"))
        XCTAssertEqual(updatedAt(scanStats(scanner, root)), 1_785_232_860)
        XCTAssertEqual(scanStats(scanner, root).diagnostics.cacheHitCount, 1)
        let handle = try FileHandle(forWritingTo: history)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x0A]) + JSONSerialization.data(withJSONObject: record(1_785_232_920_000)) + Data([0x0A]))
        try handle.close()
        let appended = scanStats(scanner, root)
        XCTAssertEqual(updatedAt(appended), 1_785_232_920)
        XCTAssertGreaterThan(appended.diagnostics.inspectedHistoryBytes, 0)
        let originalDate = try XCTUnwrap(history.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        try writeJSONLines([record(1_785_232_990_000)], to: history)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: history.path)
        XCTAssertEqual(updatedAt(scanStats(scanner, root)), 1_785_232_990)
        let outside = root.appendingPathComponent("outside.jsonl")
        try writeJSONLines([record(1_785_233_000_000)], to: outside)
        try FileManager.default.removeItem(at: history)
        try FileManager.default.createSymbolicLink(at: history, withDestinationURL: outside)
        let linked = scanStats(scanner, root)
        XCTAssertTrue(linked.sessions.isEmpty)
        XCTAssertEqual(linked.diagnostics.cacheHitCount, 0)
    }

    func testClaudeUsageCacheEvictsOnlyLeastRecentlyUsedSummaryAcrossAccounts() throws {
        let first = root.appendingPathComponent("FirstAccount")
        let second = root.appendingPathComponent("SecondAccount")
        try makeCoworkFixture(userDataURL: first, fixtureName: "local_first", sessionID: "first")
        try makeCoworkFixture(userDataURL: first, fixtureName: "local_second", sessionID: "second")
        let oldest = try makeCoworkFixture(userDataURL: second, fixtureName: "local_oldest", sessionID: "oldest")
        let scanner = LocalChatScanner(
            maximumClaudeUsageCacheEntries: 3,
            indexRootURL: root.appendingPathComponent("Indexes")
        )
        XCTAssertEqual(scanStats(scanner, first).diagnostics.parsedFileCount, 2)
        XCTAssertEqual(scanStats(scanner, second).diagnostics.parsedFileCount, 1)
        XCTAssertEqual(scanStats(scanner, first).diagnostics.cacheHitCount, 2)
        try FileManager.default.removeItem(at: oldest.metadata)
        try makeCoworkFixture(userDataURL: second, fixtureName: "local_newest", sessionID: "newest")
        let added = scanStats(scanner, second)
        XCTAssertEqual(added.diagnostics.parsedFileCount, 1)
        let retained = scanStats(scanner, first)
        XCTAssertEqual(retained.diagnostics.cacheHitCount, 2)
        XCTAssertEqual(retained.diagnostics.parsedFileCount, 0)
        XCTAssertTrue(retained.sessions.allSatisfy { $0.tokenCount != nil })
    }

    func testClaudeUsageCacheInvalidatesSameSizeRewriteAndReplacementWithPreservedDate() throws {
        func usage(_ tokens: Int) -> [String: Any] {
            ["type": "assistant", "message": ["id": "synthetic-message", "usage": ["input_tokens": tokens]]]
        }
        let fixture = try makeCoworkFixture(auditRecords: [usage(100)])
        let scanner = LocalChatScanner(indexRootURL: root.appendingPathComponent("Indexes"))
        XCTAssertEqual(scanStats(scanner, root).sessions.first?.tokenCount, 100)
        let originalDate = try XCTUnwrap(fixture.audit.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        try writeJSONLines([usage(999)], to: fixture.audit)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: fixture.audit.path)
        let rewritten = scanStats(scanner, root)
        XCTAssertEqual(rewritten.sessions.first?.tokenCount, 999)
        XCTAssertEqual(rewritten.diagnostics.parsedFileCount, 1)
        let replacement = try JSONSerialization.data(withJSONObject: usage(888), options: [.sortedKeys])
        try replacement.write(to: fixture.audit, options: [.atomic])
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: fixture.audit.path)
        let replaced = scanStats(scanner, root)
        XCTAssertEqual(replaced.sessions.first?.tokenCount, 888)
        XCTAssertEqual(replaced.diagnostics.parsedFileCount, 1)
        XCTAssertEqual(scanStats(scanner, root).diagnostics.cacheHitCount, 1)
    }

    private func scanStats(_ scanner: LocalChatScanner, _ home: URL) -> LocalChatScanResult {
        scanner.scanOfficialClaudeForStats(claudeHomeURL: home, claudeCodeHomeURL: home)
    }

    @discardableResult
    private func makeCoworkFixture(
        userDataURL: URL? = nil,
        fixtureName: String = "local_fixture",
        sessionID: String = "cowork-session",
        lastActivityAt: Double = 1_785_232_860_000,
        auditRecords: [[String: Any]]? = nil
    ) throws -> (metadata: URL, audit: URL) {
        let userDataURL = userDataURL ?? root!
        let metadata = userDataURL.appendingPathComponent(
            "claude-code-sessions/org/workspace/\(fixtureName).json"
        )
        let audit = userDataURL.appendingPathComponent(
            "local-agent-mode-sessions/org/workspace/\(fixtureName)/audit.jsonl"
        )
        try FileManager.default.createDirectory(
            at: metadata.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: audit.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let metadataObject: [String: Any] = [
            "sessionId": sessionID,
            "title": "Review the release",
            "promptSuggestion": "Check the local release evidence",
            "cwd": "/private/work/AgentDock",
            "model": "claude-opus-4-1",
            "createdAt": 1_785_232_800_000,
            "lastActivityAt": lastActivityAt,
            "isArchived": false
        ]
        try JSONSerialization.data(
            withJSONObject: metadataObject,
            options: [.sortedKeys]
        ).write(to: metadata)
        let records = auditRecords ?? [
            [
                "type": "system",
                "subtype": "init",
                "uuid": "system-event",
                "_audit_timestamp": "2026-07-28T10:00:00Z",
                "cwd": "/private/work/AgentDock",
                "model": "claude-opus-4-1"
            ],
            [
                "type": "user",
                "uuid": "user-event",
                "_audit_timestamp": "2026-07-28T10:00:01Z",
                "message": ["role": "user", "content": "Inspect the package"]
            ],
            [
                "type": "assistant",
                "uuid": "assistant-event",
                "_audit_timestamp": "2026-07-28T10:00:02Z",
                "message": [
                    "role": "assistant",
                    "content": [["type": "text", "text": "The package is valid."]]
                ]
            ]
        ]
        try writeJSONLines(records, to: audit)
        return (metadata, audit)
    }

    private func writeJSONLines(_ records: [[String: Any]], to url: URL) throws {
        let lines = try records.map {
            String(decoding: try JSONSerialization.data(
                withJSONObject: $0,
                options: [.sortedKeys]
            ), as: UTF8.self)
        }
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
    }
}
