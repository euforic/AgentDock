import SQLite3
import XCTest
@testable import AgentDockCore

final class SQLiteReadOnlyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteReadOnlyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testRegularDatabaseUsesImmutableURIWithoutSidecars() throws {
        let database = root.appendingPathComponent("state.sqlite")
        try Data("synthetic sqlite bytes".utf8).write(to: database)
        let canonicalDatabase = canonical(database)

        XCTAssertEqual(
            try SQLiteReadOnly.databaseArgument(for: database),
            canonicalDatabase.absoluteString + "?immutable=1"
        )
    }

    func testRegularSidecarDisablesImmutableMode() throws {
        let database = root.appendingPathComponent("state.sqlite")
        try Data("synthetic sqlite bytes".utf8).write(to: database)
        try Data().write(to: URL(fileURLWithPath: database.path + "-wal"))

        XCTAssertEqual(try SQLiteReadOnly.databaseArgument(for: database), canonical(database).path)
    }

    func testRejectsSymlinkedDatabaseAndSidecars() throws {
        let outside = root.appendingPathComponent("outside.sqlite")
        try Data("synthetic sqlite bytes".utf8).write(to: outside)

        let linkedDatabase = root.appendingPathComponent("linked.sqlite")
        try FileManager.default.createSymbolicLink(at: linkedDatabase, withDestinationURL: outside)
        XCTAssertThrowsError(try SQLiteReadOnly.databaseArgument(for: linkedDatabase))

        let database = root.appendingPathComponent("state.sqlite")
        try Data("synthetic sqlite bytes".utf8).write(to: database)
        let linkedWAL = URL(fileURLWithPath: database.path + "-wal")
        try FileManager.default.createSymbolicLink(at: linkedWAL, withDestinationURL: outside)
        XCTAssertThrowsError(try SQLiteReadOnly.databaseArgument(for: database))
    }

    func testScopedDatabaseRejectsSymlinkedParentFromAnotherProfile() throws {
        let profile = root.appendingPathComponent("Profile", isDirectory: true)
        let otherProfile = root.appendingPathComponent("OtherProfile", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherProfile, withIntermediateDirectories: true)
        let database = otherProfile.appendingPathComponent("Cookies")
        try Data("synthetic sqlite bytes".utf8).write(to: database)
        let network = profile.appendingPathComponent("Network", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: network, withDestinationURL: otherProfile)

        XCTAssertThrowsError(try SQLiteReadOnly.databaseArgument(
            for: network.appendingPathComponent("Cookies"),
            under: profile
        ))
        XCTAssertEqual(
            try SQLiteReadOnly.databaseArgument(for: database, under: otherProfile),
            canonical(database).absoluteString + "?immutable=1"
        )
    }

    func testQueryReturnsTypedRowsFromEveryStatementInOrder() throws {
        let database = try makeDatabase("""
        create table items (id integer, label text, score real, payload blob, note text);
        insert into items values (1, 'first', 1.5, x'00ff', null), (2, 'second', 2.0, x'', 'kept');
        """)

        let rows = try SQLiteReadOnly.query(
            database: database,
            sql: """
            select id, label, score, payload, note from items order by id;
            -- Comments and empty statements produce no rows.
            ;
            select count(*) from items;
            """,
            timeout: 2,
            maximumOutputBytes: 1_024
        )

        XCTAssertEqual(rows, [
            [.integer(1), .text("first"), .real(1.5), .blob(Data([0x00, 0xFF])), .null],
            [.integer(2), .text("second"), .real(2.0), .blob(Data()), .text("kept")],
            [.integer(2)]
        ])
    }

    func testQueryRefusesWritesAndLeavesDatabaseUnchanged() throws {
        let database = try makeDatabase("create table items (id integer);")

        XCTAssertThrowsError(try SQLiteReadOnly.query(
            database: database,
            sql: "insert into items values (1);",
            timeout: 2,
            maximumOutputBytes: 1_024
        )) { error in
            XCTAssertEqual(error as? SQLiteReadOnlyError, .writableStatement)
        }
        XCTAssertEqual(
            try SQLiteReadOnly.query(
                database: database,
                sql: "select count(*) from items;",
                timeout: 2,
                maximumOutputBytes: 1_024
            ),
            [[.integer(0)]]
        )
    }

    func testQueryIsInterruptedAtTimeout() throws {
        let database = try makeDatabase("create table items (id integer);")
        let start = Date()

        XCTAssertThrowsError(try SQLiteReadOnly.query(
            database: database,
            sql: Self.endlessQuery,
            timeout: 0.1,
            maximumOutputBytes: 1_024
        )) { error in
            XCTAssertEqual(error as? SQLiteReadOnlyError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testQueryIsInterruptedWhenTaskIsCancelled() async throws {
        let database = try makeDatabase("create table items (id integer);")
        let sql = Self.endlessQuery
        let start = Date()

        let task = Task.detached {
            try SQLiteReadOnly.query(
                database: database,
                sql: sql,
                timeout: 30,
                maximumOutputBytes: 1_024
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? SQLiteReadOnlyError, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testQueryEnforcesOutputAndRowBudgets() throws {
        let label = String(repeating: "x", count: 600)
        let database = try makeDatabase("""
        create table items (label text);
        insert into items values ('\(label)'), ('\(label)');
        """)

        XCTAssertThrowsError(try SQLiteReadOnly.query(
            database: database,
            sql: "select label from items;",
            timeout: 2,
            maximumOutputBytes: 1_000
        )) { error in
            XCTAssertEqual(error as? SQLiteReadOnlyError, .outputLimitExceeded)
        }
        XCTAssertThrowsError(try SQLiteReadOnly.query(
            database: database,
            sql: "select label from items;",
            timeout: 2,
            maximumOutputBytes: 10_000,
            maximumRows: 1
        )) { error in
            XCTAssertEqual(error as? SQLiteReadOnlyError, .rowLimitExceeded)
        }
    }

    func testQueryRejectsTextThatIsNotUTF8() throws {
        let database = try makeDatabase("""
        create table items (label text);
        insert into items values (cast(x'ff' as text));
        """)

        XCTAssertThrowsError(try SQLiteReadOnly.query(
            database: database,
            sql: "select label from items;",
            timeout: 2,
            maximumOutputBytes: 1_024
        )) { error in
            XCTAssertEqual(error as? SQLiteReadOnlyError, .invalidText)
        }
    }

    func testQueryRejectsSymlinkedDatabase() throws {
        let outside = try makeDatabase("create table items (id integer);")
        let linked = root.appendingPathComponent("linked.sqlite")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)

        XCTAssertThrowsError(try SQLiteReadOnly.query(
            database: linked,
            sql: "select count(*) from items;",
            timeout: 2,
            maximumOutputBytes: 1_024
        )) { error in
            XCTAssertEqual(error as? SQLiteReadOnlyError, .unsafeDatabase(canonical(linked).path))
        }
    }

    func testScopedQueryRejectsSymlinkedParentFromAnotherProfile() throws {
        let profile = root.appendingPathComponent("Profile", isDirectory: true)
        let otherProfile = root.appendingPathComponent("OtherProfile", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherProfile, withIntermediateDirectories: true)
        let database = try makeDatabase("""
        create table items (id integer);
        insert into items values (3);
        """)
        let otherDatabase = otherProfile.appendingPathComponent("Cookies")
        try FileManager.default.moveItem(at: database, to: otherDatabase)
        let network = profile.appendingPathComponent("Network", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: network, withDestinationURL: otherProfile)
        let linked = network.appendingPathComponent("Cookies")
        let sql = "select id from items;"

        // Only the parent is resolved, so an unscoped query follows the link.
        XCTAssertEqual(
            try SQLiteReadOnly.query(database: linked, sql: sql, timeout: 2, maximumOutputBytes: 1_024),
            [[.integer(3)]]
        )
        XCTAssertThrowsError(try SQLiteReadOnly.query(
            database: linked,
            under: profile,
            sql: sql,
            timeout: 2,
            maximumOutputBytes: 1_024
        )) { error in
            XCTAssertEqual(error as? SQLiteReadOnlyError, .unsafeDatabase(linked.path))
        }
        XCTAssertEqual(
            try SQLiteReadOnly.query(
                database: otherDatabase,
                under: otherProfile,
                sql: sql,
                timeout: 2,
                maximumOutputBytes: 1_024
            ),
            [[.integer(3)]]
        )
    }

    func testQueryReadsCommittedWALContentWhileWriterIsOpen() throws {
        let database = root.appendingPathComponent("live.sqlite")
        var writer: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(database.path, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
            SQLITE_OK
        )
        defer { sqlite3_close_v2(writer) }
        XCTAssertEqual(sqlite3_exec(writer, """
        pragma journal_mode = WAL;
        pragma wal_autocheckpoint = 0;
        create table items (id integer);
        insert into items values (7);
        """, nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path + "-wal"))

        let rows = try SQLiteReadOnly.query(
            database: database,
            sql: "select id from items;",
            timeout: 2,
            maximumOutputBytes: 1_024
        )

        XCTAssertEqual(rows, [[.integer(7)]])
    }

    private static let endlessQuery = """
    with recursive sequence(value) as (select 1 union all select value + 1 from sequence)
    select count(*) from sequence;
    """

    private func makeDatabase(_ sql: String) throws -> URL {
        let database = root.appendingPathComponent("\(UUID().uuidString).sqlite")
        var connection: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
            SQLITE_OK
        )
        defer { sqlite3_close_v2(connection) }
        XCTAssertEqual(sqlite3_exec(connection, sql, nil, nil, nil), SQLITE_OK)
        return database
    }

    private func canonical(_ database: URL) -> URL {
        let parent = database.deletingLastPathComponent()
        let resolved = realpath(parent.path, nil)!
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent(database.lastPathComponent)
    }
}
