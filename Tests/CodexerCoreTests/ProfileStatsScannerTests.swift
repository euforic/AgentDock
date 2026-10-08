import XCTest
@testable import CodexerCore

final class ProfileStatsScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexerStatsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testMissingDatabasesReturnEmptyStatsWithDataSize() throws {
        let profile = CodexProfile(name: "Empty", slug: "empty", rootDirectory: root)
        try FileManager.default.createDirectory(at: profile.codexHomePath, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: profile.codexHomePath.appendingPathComponent("sample.txt"))

        let stats = ProfileStatsScanner().stats(for: profile, now: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(stats.totalSessions, 0)
        XCTAssertEqual(stats.weeklySessions, 0)
        XCTAssertEqual(stats.averageTokensPerSession, 0)
        XCTAssertEqual(stats.peakSessionTokens, 0)
        XCTAssertTrue(stats.weeklyTokenBuckets.isEmpty)
        XCTAssertEqual(stats.dataBytes, 3)
        XCTAssertFalse(stats.dataSizeIsTruncated)
        XCTAssertNil(stats.lastActivityAt)
        XCTAssertTrue(stats.errorMessages.isEmpty, "\(stats.errorMessages)")
    }

    func testDataSizeScanStopsAtEntryBudgetAndReportsLowerBound() throws {
        let profile = CodexProfile(name: "Bounded", slug: "bounded", rootDirectory: root)
        try FileManager.default.createDirectory(at: profile.codexHomePath, withIntermediateDirectories: true)
        for index in 0..<8 {
            try Data(repeating: UInt8(index), count: 16).write(
                to: profile.profileDirectory.appendingPathComponent("sample-\(index).dat")
            )
        }
        let scanner = ProfileStatsScanner(
            dataSizeMaximumEntries: 3,
            dataSizeMaximumDepth: 64,
            dataSizeTimeout: 5
        )

        let stats = scanner.stats(for: profile)

        XCTAssertTrue(stats.dataSizeIsTruncated)
        XCTAssertGreaterThanOrEqual(stats.dataBytes, 0)
        XCTAssertLessThan(stats.dataBytes, 8 * 16)
    }

    func testStorageMeasurementReusesTimestampAtOneAndFiveMinutesThenExpires() throws {
        let profile = CodexProfile(name: "Cached", slug: "cached", rootDirectory: root)
        try FileManager.default.createDirectory(at: profile.codexHomePath, withIntermediateDirectories: true)
        let file = profile.codexHomePath.appendingPathComponent("sample.dat")
        try Data(repeating: 0x61, count: 3).write(to: file)
        let scanner = ProfileStatsScanner()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let initial = scanner.stats(for: profile, now: now)
        try Data(repeating: 0x61, count: 12).write(to: file)
        for interval in [60.0, 300.0] {
            let reused = scanner.stats(for: profile, now: now.addingTimeInterval(interval))
            XCTAssertEqual(reused.dataBytes, 3)
            XCTAssertEqual(reused.dataSizeMeasuredAt, now)
        }
        let refreshed = scanner.stats(for: profile, now: now.addingTimeInterval(600))
        XCTAssertEqual(initial.dataSizeMeasuredAt, now)
        XCTAssertEqual(refreshed.dataBytes, 12)
        XCTAssertEqual(refreshed.dataSizeMeasuredAt, now.addingTimeInterval(600))
    }

    func testClaudeStatsReportPartialHistoryCoverageAndPreserveModelBudget() throws {
        let home = root.appendingPathComponent("ClaudeCode")
        let project = home.appendingPathComponent("projects/-synthetic-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let recent = try JSONSerialization.data(withJSONObject: [
            "display": "Recent", "project": "/synthetic/project", "sessionId": "recent",
            "timestamp": 1_700_000_000_000
        ]) + Data([0x0A])
        try (Data(repeating: 0x78, count: 2_048) + Data([0x0A]) + recent)
            .write(to: home.appendingPathComponent("history.jsonl"))
        let body = try JSONSerialization.data(withJSONObject: [
            "type": "assistant", "message": ["model": "synthetic-model"]
        ]) + Data([0x0A])
        try body.write(to: project.appendingPathComponent("recent.jsonl"))
        let scanner = ProfileStatsScanner(claudeChatScanner: LocalChatScanner(maximumMetadataBytes: 512))
        let stats = scanner.stats(
            claudeUserDataURL: root.appendingPathComponent("UserData"),
            claudeCodeHomeURL: home, dataRootURL: home,
            now: Date(timeIntervalSince1970: 1_700_000_001)
        )
        XCTAssertEqual(stats.totalSessions, 1)
        XCTAssertEqual(stats.modelUsage.first?.model, "synthetic-model")
        XCTAssertTrue(stats.errorMessages.contains { $0.contains("coverage is partial") })
    }

    func testStatsSummarizeSessionsTokensJobsAndWeeklyLogs() throws {
        let profile = CodexProfile(name: "Work", slug: "work", rootDirectory: root)
        try FileManager.default.createDirectory(at: profile.codexHomePath, withIntermediateDirectories: true)
        let state = profile.codexHomePath.appendingPathComponent("state_5.sqlite")
        let logs = profile.codexHomePath.appendingPathComponent("logs_2.sqlite")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = Int(now.timeIntervalSince1970) - 60
        let yesterday = Int(now.timeIntervalSince1970) - (24 * 60 * 60)
        let old = Int(now.timeIntervalSince1970) - (9 * 24 * 60 * 60)

        try runSQLite(state, sql: """
        create table threads (
          id text primary key,
          created_at integer not null,
          updated_at integer not null,
          tokens_used integer not null default 0,
          archived integer not null default 0
        );
        create table agent_jobs (
          id text primary key,
          status text not null
        );
        insert into threads values ('recent', \(recent), \(recent), 1200, 0);
        insert into threads values ('yesterday', \(yesterday), \(yesterday), 600, 0);
        insert into threads values ('old', \(old), \(old), 300, 1);
        insert into agent_jobs values ('job-1', 'running');
        insert into agent_jobs values ('job-2', 'completed');
        """)
        try runSQLite(logs, sql: """
        create table logs (
          id integer primary key autoincrement,
          ts integer not null,
          level text not null,
          estimated_bytes integer not null default 0
        );
        insert into logs (ts, level, estimated_bytes) values (\(recent), 'WARN', 10);
        insert into logs (ts, level, estimated_bytes) values (\(recent), 'ERROR', 20);
        insert into logs (ts, level, estimated_bytes) values (\(old), 'ERROR', 40);
        """)

        let stats = ProfileStatsScanner().stats(for: profile, now: now)

        XCTAssertEqual(stats.totalSessions, 3)
        XCTAssertEqual(stats.weeklySessions, 2)
        XCTAssertEqual(stats.activeSessions, 2)
        XCTAssertEqual(stats.archivedSessions, 1)
        XCTAssertEqual(stats.totalTokens, 2100)
        XCTAssertEqual(stats.weeklyTokens, 1800)
        XCTAssertEqual(stats.averageTokensPerSession, 700)
        XCTAssertEqual(stats.peakSessionTokens, 1200)
        XCTAssertEqual(stats.weeklyTokenBuckets.reduce(0) { $0 + $1.tokens }, 1800)
        XCTAssertEqual(stats.weeklyTokenBuckets.reduce(0) { $0 + $1.sessions }, 2)
        XCTAssertEqual(stats.weeklyTokenBuckets.count, 2)
        XCTAssertEqual(stats.jobCounts["running"], 1)
        XCTAssertEqual(stats.jobCounts["completed"], 1)
        XCTAssertEqual(stats.weeklyWarnings, 1)
        XCTAssertEqual(stats.weeklyErrors, 1)
        XCTAssertEqual(stats.lastActivityAt, Date(timeIntervalSince1970: TimeInterval(recent)))
        XCTAssertTrue(stats.errorMessages.isEmpty, "\(stats.errorMessages)")
    }

    func testMalformedSchemaReportsAnActionableError() throws {
        let profile = CodexProfile(name: "Broken", slug: "broken", rootDirectory: root)
        try FileManager.default.createDirectory(at: profile.codexHomePath, withIntermediateDirectories: true)
        let state = profile.codexHomePath.appendingPathComponent("state_5.sqlite")
        try runSQLite(state, sql: "create table unrelated (id text);")

        let stats = ProfileStatsScanner().stats(for: profile)

        XCTAssertFalse(stats.errorMessages.isEmpty)
        XCTAssertTrue(stats.errorMessages.contains { $0.contains("profile state") })
    }

    func testMissingOptionalAgentJobsTableDoesNotBreakThreadStats() throws {
        let profile = CodexProfile(name: "Enterprise", slug: "enterprise", rootDirectory: root)
        try FileManager.default.createDirectory(at: profile.codexHomePath, withIntermediateDirectories: true)
        let state = profile.codexHomePath.appendingPathComponent("state_5.sqlite")
        let now = Int(Date().timeIntervalSince1970)
        try runSQLite(state, sql: """
        create table threads (
          id text primary key,
          updated_at integer not null,
          tokens_used integer not null default 0,
          archived integer not null default 0
        );
        insert into threads values ('business-thread', \(now), 800, 0);
        """)

        let stats = ProfileStatsScanner().stats(for: profile)

        XCTAssertEqual(stats.totalSessions, 1)
        XCTAssertEqual(stats.totalTokens, 800)
        XCTAssertTrue(stats.jobCounts.isEmpty)
        XCTAssertTrue(stats.errorMessages.isEmpty, "\(stats.errorMessages)")
    }

    func testThreadSchemaWithoutOptionalUsageColumnsStillReportsSessions() throws {
        let profile = CodexProfile(name: "Minimal", slug: "minimal", rootDirectory: root)
        try FileManager.default.createDirectory(at: profile.codexHomePath, withIntermediateDirectories: true)
        let state = profile.codexHomePath.appendingPathComponent("state_5.sqlite")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recentMilliseconds = Int(now.timeIntervalSince1970 * 1_000) - 60_000
        try runSQLite(state, sql: """
        create table threads (
          id text primary key,
          updated_at_ms integer not null
        );
        insert into threads values ('minimal-thread', \(recentMilliseconds));
        """)

        let stats = ProfileStatsScanner().stats(for: profile, now: now)

        XCTAssertEqual(stats.totalSessions, 1)
        XCTAssertEqual(stats.weeklySessions, 1)
        XCTAssertEqual(stats.activeSessions, 1)
        XCTAssertEqual(stats.archivedSessions, 0)
        XCTAssertEqual(stats.totalTokens, 0)
        XCTAssertEqual(stats.lastActivityAt, Date(timeIntervalSince1970: 1_699_999_940))
        XCTAssertTrue(stats.errorMessages.isEmpty, "\(stats.errorMessages)")
    }

    func testClosedWALDatabasesRemainReadableWithoutSidecarFiles() throws {
        let profile = CodexProfile(name: "Closed", slug: "closed", rootDirectory: root)
        try FileManager.default.createDirectory(at: profile.codexHomePath, withIntermediateDirectories: true)
        let state = profile.codexHomePath.appendingPathComponent("state_5.sqlite")
        let logs = profile.codexHomePath.appendingPathComponent("logs_2.sqlite")
        let now = Int(Date().timeIntervalSince1970)

        try runSQLite(state, sql: """
        pragma journal_mode = WAL;
        create table threads (
          id text primary key,
          updated_at integer not null,
          tokens_used integer not null default 0,
          archived integer not null default 0
        );
        insert into threads values ('closed-thread', \(now), 1200, 0);
        """)
        try runSQLite(logs, sql: """
        pragma journal_mode = WAL;
        create table logs (
          id integer primary key autoincrement,
          ts integer not null,
          level text not null,
          estimated_bytes integer not null default 0
        );
        insert into logs (ts, level) values (\(now), 'ERROR');
        """)
        try? FileManager.default.removeItem(atPath: state.path + "-wal")
        try? FileManager.default.removeItem(atPath: state.path + "-shm")
        try? FileManager.default.removeItem(atPath: logs.path + "-wal")
        try? FileManager.default.removeItem(atPath: logs.path + "-shm")
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path + "-shm"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: logs.path + "-shm"))

        let stats = ProfileStatsScanner().stats(for: profile)

        XCTAssertEqual(stats.totalSessions, 1)
        XCTAssertEqual(stats.totalTokens, 1200)
        XCTAssertEqual(stats.weeklyErrors, 1)
        XCTAssertTrue(stats.errorMessages.isEmpty, "\(stats.errorMessages)")
    }

    func testLargeWeeklyHistoryCompletesWithoutPipeDeadlock() throws {
        let profile = CodexProfile(name: "Large", slug: "large", rootDirectory: root)
        try FileManager.default.createDirectory(at: profile.codexHomePath, withIntermediateDirectories: true)
        let state = profile.codexHomePath.appendingPathComponent("state_5.sqlite")
        let now = Int(Date().timeIntervalSince1970)
        try runSQLite(state, sql: """
        create table threads (
          id text primary key,
          created_at integer not null,
          updated_at integer not null,
          tokens_used integer not null default 0,
          archived integer not null default 0
        );
        create table agent_jobs (id text primary key, status text not null);
        with recursive sequence(value) as (
          select 1 union all select value + 1 from sequence where value < 10000
        )
        insert into threads
        select printf('thread-%d', value), \(now), \(now) - (value % 86400), value, 0 from sequence;
        """)
        let start = Date()

        let stats = ProfileStatsScanner().stats(for: profile)

        XCTAssertEqual(stats.totalSessions, 10_000)
        XCTAssertFalse(stats.weeklyTokenBuckets.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertTrue(stats.errorMessages.isEmpty, "\(stats.errorMessages)")
    }

    func testClaudeStatsAggregateProfileScopedUsageAndModels() throws {
        let profile = CodexProfile(
            product: .claude,
            name: "Claude Work",
            slug: "claude-work",
            rootDirectory: root
        )
        let metadata = profile.claudeUserDataPath.appendingPathComponent(
            "claude-code-sessions/org/workspace/local_fixture.json"
        )
        let audit = profile.claudeUserDataPath.appendingPathComponent(
            "local-agent-mode-sessions/org/workspace/local_fixture/audit.jsonl"
        )
        try FileManager.default.createDirectory(
            at: metadata.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: audit.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let now = Date(timeIntervalSince1970: 1_785_232_900)
        try JSONSerialization.data(withJSONObject: [
            "sessionId": "session-1",
            "title": "Measure usage",
            "model": "claude-opus-4-1",
            "createdAt": 1_785_232_800_000,
            "lastActivityAt": 1_785_232_860_000,
            "isArchived": false
        ], options: [.sortedKeys]).write(to: metadata)
        let records: [[String: Any]] = [[
            "type": "assistant",
            "timestamp": "2026-07-28T10:01:00Z",
            "message": [
                "id": "message-1",
                "model": "claude-opus-4-1",
                "usage": [
                    "input_tokens": 10,
                    "cache_read_input_tokens": 20,
                    "cache_creation_input_tokens": 30,
                    "output_tokens": 40
                ]
            ]
        ]]
        let lines = try records.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
        }
        try Data(lines.joined(separator: "\n").utf8).write(to: audit)

        let stats = ProfileStatsScanner().stats(for: profile, now: now)

        XCTAssertEqual(stats.totalSessions, 1)
        XCTAssertEqual(stats.weeklySessions, 1)
        XCTAssertEqual(stats.activeSessions, 1)
        XCTAssertEqual(stats.tokenizedSessions, 1)
        XCTAssertEqual(stats.totalTokens, 100)
        XCTAssertEqual(stats.weeklyTokens, 100)
        XCTAssertEqual(stats.averageTokensPerSession, 100)
        XCTAssertEqual(stats.peakSessionTokens, 100)
        XCTAssertEqual(stats.modelUsage, [
            ModelUsageSummary(model: "claude-opus-4-1", sessions: 1, tokens: 100)
        ])
        XCTAssertEqual(stats.lastActivityAt, Date(timeIntervalSince1970: 1_785_232_860))
    }

    func testHungSQLiteProcessIsTerminatedAtTimeout() throws {
        let profile = CodexProfile(name: "Hung", slug: "hung", rootDirectory: root)
        try FileManager.default.createDirectory(at: profile.codexHomePath, withIntermediateDirectories: true)
        try Data().write(to: profile.codexHomePath.appendingPathComponent("state_5.sqlite"))
        let fakeSQLite = root.appendingPathComponent("slow-sqlite")
        try Data("#!/bin/sh\nsleep 5\n".utf8).write(to: fakeSQLite)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSQLite.path)
        let scanner = ProfileStatsScanner(sqliteExecutable: fakeSQLite, queryTimeout: 0.1)
        let start = Date()

        let stats = scanner.stats(for: profile)

        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertTrue(stats.errorMessages.contains { $0.contains("Timed out") })
    }

    private func runSQLite(_ database: URL, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
