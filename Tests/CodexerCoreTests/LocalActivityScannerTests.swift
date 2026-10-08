import Foundation
import XCTest
@testable import CodexerCore

final class LocalActivityScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalActivityScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testReadsRealDatabasesAndReturnsSanitizedBoundedActivity() async throws {
        try createLogsDatabase(rowCount: 205)
        try createStateDatabase()

        let snapshot = try await LocalActivityReader().read(codexHomeURL: root)

        XCTAssertEqual(snapshot.availability, .available)
        XCTAssertTrue(snapshot.issues.isEmpty)
        XCTAssertEqual(snapshot.logs.count, 200)
        XCTAssertEqual(snapshot.logs.first?.level, "INFO")
        XCTAssertEqual(snapshot.logs.first?.target, "codex_core::runner")
        XCTAssertEqual(snapshot.logs.first?.source, "activity.rs")
        XCTAssertEqual(snapshot.logs.first?.threadID, "thread-204")
        XCTAssertFalse(snapshot.logs.first?.message.contains(root.path) ?? true)
        XCTAssertFalse(snapshot.logs.first?.message.contains("super-secret") ?? true)
        XCTAssertTrue(snapshot.logs.first?.message.contains("[REDACTED]") ?? false)

        XCTAssertEqual(snapshot.archivedThreads.count, 1)
        let thread = try XCTUnwrap(snapshot.archivedThreads.first)
        XCTAssertEqual(thread.id, "archived-thread")
        XCTAssertEqual(thread.title, "Archived activity")
        XCTAssertEqual(thread.repository, "SensitiveRepository")
        XCTAssertEqual(thread.branch, "feature/activity")
        XCTAssertEqual(thread.tokenCount, 12_345)
        XCTAssertEqual(thread.updatedAt, Date(timeIntervalSince1970: 1_722_000_000))
        XCTAssertEqual(thread.archivedAt, Date(timeIntervalSince1970: 1_722_000_100))
    }

    func testMissingDatabaseProducesPartialAvailabilityAndScopedIssue() async throws {
        try createLogsDatabase(rowCount: 1)

        let snapshot = try await LocalActivityReader().read(codexHomeURL: root)

        XCTAssertEqual(snapshot.availability, .partial)
        XCTAssertEqual(snapshot.logs.count, 1)
        XCTAssertTrue(snapshot.archivedThreads.isEmpty)
        XCTAssertEqual(snapshot.issues.count, 1)
        XCTAssertEqual(snapshot.issues.first?.source, .archivedThreads)
        XCTAssertEqual(snapshot.issues.first?.message, "Database is not available.")
    }

    func testCancellationIsPropagated() async throws {
        try createLogsDatabase(rowCount: 1)
        try createStateDatabase()
        let root = try XCTUnwrap(root)

        let task = Task {
            try Task.checkCancellation()
            return try await LocalActivityReader().read(codexHomeURL: root)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    private func createLogsDatabase(rowCount: Int) throws {
        var statements = [
            """
            CREATE TABLE logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts INTEGER NOT NULL,
                ts_nanos INTEGER NOT NULL,
                level TEXT NOT NULL,
                target TEXT NOT NULL,
                feedback_log_body TEXT,
                module_path TEXT,
                file TEXT,
                line INTEGER,
                thread_id TEXT,
                process_uuid TEXT,
                estimated_bytes INTEGER NOT NULL DEFAULT 0
            );
            """
        ]
        for index in 0..<rowCount {
            statements.append(
                """
                INSERT INTO logs (
                    ts, ts_nanos, level, target, feedback_log_body, module_path, file, thread_id
                ) VALUES (
                    \(1_722_000_000 + index), \(index), 'INFO', 'codex_core::runner',
                    'Opened \(sqlLiteral(root.path))/private/file password=super-secret',
                    '/private/build/activity.rs', '/private/build/activity.rs', 'thread-\(index)'
                );
                """
            )
        }
        try runSQLite(database: root.appendingPathComponent("logs_2.sqlite"), sql: statements.joined())
    }

    private func createStateDatabase() throws {
        let sql = """
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            rollout_path TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            source TEXT NOT NULL,
            model_provider TEXT NOT NULL,
            cwd TEXT NOT NULL,
            title TEXT NOT NULL,
            sandbox_policy TEXT NOT NULL,
            approval_mode TEXT NOT NULL,
            tokens_used INTEGER NOT NULL DEFAULT 0,
            has_user_event INTEGER NOT NULL DEFAULT 0,
            archived INTEGER NOT NULL DEFAULT 0,
            archived_at INTEGER,
            git_sha TEXT,
            git_branch TEXT,
            git_origin_url TEXT
        );
        INSERT INTO threads (
            id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
            sandbox_policy, approval_mode, tokens_used, archived, archived_at, git_branch
        ) VALUES (
            'active-thread', '/private/rollout.jsonl', 1721000000, 1722000200, 'app', 'openai',
            '/private/work/ActiveRepository', 'Active activity', '{}', 'never', 999, 0, NULL, 'main'
        );
        INSERT INTO threads (
            id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
            sandbox_policy, approval_mode, tokens_used, archived, archived_at, git_branch
        ) VALUES (
            'archived-thread', '/private/rollout.jsonl', 1721000000, 1722000000, 'app', 'openai',
            '/Users/person/Secret/Path/SensitiveRepository', 'Archived activity', '{}', 'never',
            12345, 1, 1722000100, 'feature/activity'
        );
        """
        try runSQLite(database: root.appendingPathComponent("state_5.sqlite"), sql: sql)
    }

    private func runSQLite(database: URL, sql: String) throws {
        let result = try BoundedSubprocess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: [database.path, sql],
            timeout: 5,
            maximumOutputBytes: 64 * 1_024,
            captureStandardError: true
        )
        XCTAssertEqual(result.terminationStatus, 0, String(decoding: result.output, as: UTF8.self))
        XCTAssertFalse(result.exceededOutputLimit)
    }

    private func sqlLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
