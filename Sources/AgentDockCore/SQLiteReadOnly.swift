import Darwin
import Foundation
import SQLite3

enum SQLiteReadOnly {
    static func databaseArgument(for database: URL, under root: URL? = nil) throws -> String {
        // `SQLITE_OPEN_NOFOLLOW` rejects symlinked path components on macOS.
        // Resolve only the parent, retain the final name, then validate the files.
        let originalParent = database.deletingLastPathComponent()
        guard let resolvedParent = Darwin.realpath(originalParent.path, nil) else {
            throw SQLiteReadOnlyError.unsafeDatabase(database.path)
        }
        defer { Darwin.free(resolvedParent) }
        let parent = URL(fileURLWithPath: String(cString: resolvedParent), isDirectory: true)
        let canonicalDatabase = parent.appendingPathComponent(database.lastPathComponent)
        if let root {
            let rootPath = root.standardizedFileURL.path + "/"
            let databasePath = database.standardizedFileURL.path
            guard databasePath.hasPrefix(rootPath),
                  let resolvedRoot = Darwin.realpath(root.path, nil)
            else { throw SQLiteReadOnlyError.unsafeDatabase(database.path) }
            defer { Darwin.free(resolvedRoot) }
            let expected = URL(fileURLWithPath: String(cString: resolvedRoot), isDirectory: true)
                .appendingPathComponent(String(databasePath.dropFirst(rootPath.count)))
            guard expected.path == canonicalDatabase.path else {
                throw SQLiteReadOnlyError.unsafeDatabase(database.path)
            }
        }
        let wal = URL(fileURLWithPath: canonicalDatabase.path + "-wal")
        let sharedMemory = URL(fileURLWithPath: canonicalDatabase.path + "-shm")
        _ = try validateRegularFile(canonicalDatabase, required: true)
        let hasWAL = try validateRegularFile(wal, required: false)
        let hasSharedMemory = try validateRegularFile(sharedMemory, required: false)
        guard !hasWAL, !hasSharedMemory else {
            return canonicalDatabase.path
        }
        return canonicalDatabase.absoluteString + "?immutable=1"
    }

    private static func validateRegularFile(_ url: URL, required: Bool) throws -> Bool {
        var status = Darwin.stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            if !required, errno == ENOENT { return false }
            throw SQLiteReadOnlyError.unsafeDatabase(url.path)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw SQLiteReadOnlyError.unsafeDatabase(url.path)
        }
        return true
    }
}

enum SQLiteReadOnlyError: Error, LocalizedError, Equatable {
    case unsafeDatabase(String)
    case timedOut
    case cancelled
    case outputLimitExceeded
    case rowLimitExceeded
    case invalidText
    case writableStatement
    case sqlite(Int32)

    var errorDescription: String? {
        switch self {
        case let .unsafeDatabase(path):
            "The database or one of its sidecars is not a safe regular file: \(path)"
        case .timedOut:
            "The database query timed out."
        case .cancelled:
            "The database query was cancelled."
        case .outputLimitExceeded:
            "The database query output exceeded the safety limit."
        case .rowLimitExceeded:
            "The database query returned more rows than allowed."
        case .invalidText:
            "The database returned text that is not valid UTF-8."
        case .writableStatement:
            "The database query was not read-only."
        case let .sqlite(code):
            "SQLite error \(code)."
        }
    }
}

enum SQLiteValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

extension SQLiteReadOnly {
    /// Runs each statement in `sql` in process and returns every result row in
    /// order. The connection is read-only, refuses symlinked paths, and stops at
    /// the deadline, on task cancellation, or when the output budget is spent.
    /// A `root` additionally requires the resolved database to stay inside it.
    static func query(
        database: URL,
        under root: URL? = nil,
        sql: String,
        timeout: TimeInterval,
        maximumOutputBytes: Int,
        maximumRows: Int = .max
    ) throws -> [[SQLiteValue]] {
        guard !Task.isCancelled else { throw SQLiteReadOnlyError.cancelled }
        let filename = try databaseArgument(for: database, under: root)
        let interruption = SQLiteInterruption(timeout: timeout)

        var openedConnection: OpaquePointer?
        let openResult = sqlite3_open_v2(
            filename,
            &openedConnection,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX,
            nil
        )
        defer { sqlite3_close_v2(openedConnection) }
        guard openResult == SQLITE_OK, let connection = openedConnection else {
            throw SQLiteReadOnlyError.sqlite(openResult)
        }
        let context = Unmanaged.passUnretained(interruption).toOpaque()
        sqlite3_progress_handler(connection, 1_000, { context in
            guard let context else { return 1 }
            return Unmanaged<SQLiteInterruption>.fromOpaque(context)
                .takeUnretainedValue()
                .shouldInterrupt() ? 1 : 0
        }, context)
        defer { sqlite3_progress_handler(connection, 0, nil, nil) }

        return try withExtendedLifetime(interruption) {
            // Provider databases are untrusted input: refuse schema-defined
            // side effects and writes in addition to the read-only open.
            _ = try execute(
                "PRAGMA trusted_schema=OFF; PRAGMA query_only=ON;",
                on: connection,
                interruption: interruption,
                budget: SQLiteOutputBudget(maximumBytes: 0, maximumRows: 0)
            )
            return try execute(
                sql,
                on: connection,
                interruption: interruption,
                budget: SQLiteOutputBudget(maximumBytes: maximumOutputBytes, maximumRows: maximumRows)
            )
        }
    }

    private static func execute(
        _ sql: String,
        on connection: OpaquePointer,
        interruption: SQLiteInterruption,
        budget initialBudget: SQLiteOutputBudget
    ) throws -> [[SQLiteValue]] {
        var budget = initialBudget
        var rows: [[SQLiteValue]] = []
        let source = Array(sql.utf8CString)
        try source.withUnsafeBufferPointer { buffer in
            guard var cursor = buffer.baseAddress else { return }
            while cursor.pointee != 0 {
                try interruption.check()
                var preparedStatement: OpaquePointer?
                var tail: UnsafePointer<CChar>?
                let prepareResult = sqlite3_prepare_v2(connection, cursor, -1, &preparedStatement, &tail)
                defer { sqlite3_finalize(preparedStatement) }
                guard prepareResult == SQLITE_OK else {
                    throw interruption.error(for: prepareResult)
                }
                // Whitespace and comments compile to no statement.
                if let statement = preparedStatement {
                    guard sqlite3_stmt_readonly(statement) != 0 else {
                        throw SQLiteReadOnlyError.writableStatement
                    }
                    try collectRows(of: statement, into: &rows, interruption: interruption, budget: &budget)
                }
                guard let tail, tail > cursor else { return }
                cursor = tail
            }
        }
        return rows
    }

    private static func collectRows(
        of statement: OpaquePointer,
        into rows: inout [[SQLiteValue]],
        interruption: SQLiteInterruption,
        budget: inout SQLiteOutputBudget
    ) throws {
        let columnCount = sqlite3_column_count(statement)
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { return }
            guard stepResult == SQLITE_ROW else {
                throw interruption.error(for: stepResult)
            }
            try interruption.check()
            try budget.consumeRow()
            var row: [SQLiteValue] = []
            row.reserveCapacity(Int(columnCount))
            for column in 0..<columnCount {
                row.append(try value(statement, column: column, budget: &budget))
            }
            rows.append(row)
        }
    }

    private static func value(
        _ statement: OpaquePointer,
        column: Int32,
        budget: inout SQLiteOutputBudget
    ) throws -> SQLiteValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_NULL:
            try budget.consume(bytes: 1)
            return .null
        case SQLITE_INTEGER:
            let value = sqlite3_column_int64(statement, column)
            try budget.consume(bytes: String(value).utf8.count + 1)
            return .integer(value)
        case SQLITE_FLOAT:
            let value = sqlite3_column_double(statement, column)
            try budget.consume(bytes: String(value).utf8.count + 1)
            return .real(value)
        case SQLITE_BLOB:
            let pointer = sqlite3_column_blob(statement, column)
            let count = Int(sqlite3_column_bytes(statement, column))
            try budget.consume(bytes: count + 1)
            guard let pointer, count > 0 else { return .blob(Data()) }
            return .blob(Data(bytes: pointer, count: count))
        default:
            let pointer = sqlite3_column_text(statement, column)
            let count = Int(sqlite3_column_bytes(statement, column))
            try budget.consume(bytes: count + 1)
            guard let pointer, count > 0 else { return .text("") }
            guard let text = String(
                validating: UnsafeBufferPointer(start: pointer, count: count),
                as: UTF8.self
            ) else {
                throw SQLiteReadOnlyError.invalidText
            }
            return .text(text)
        }
    }
}

/// Polled by SQLite's progress handler on the querying thread.
private final class SQLiteInterruption {
    private let deadline: UInt64
    private var reason: SQLiteReadOnlyError?

    init(timeout: TimeInterval) {
        let seconds = min(max(0, timeout), 24 * 60 * 60)
        deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
    }

    func shouldInterrupt() -> Bool {
        if reason == nil {
            if Task.isCancelled {
                reason = .cancelled
            } else if DispatchTime.now().uptimeNanoseconds >= deadline {
                reason = .timedOut
            }
        }
        return reason != nil
    }

    func check() throws {
        if shouldInterrupt(), let reason { throw reason }
    }

    func error(for code: Int32) -> SQLiteReadOnlyError {
        if code == SQLITE_INTERRUPT, let reason { return reason }
        return .sqlite(code)
    }
}

private struct SQLiteOutputBudget {
    private var remainingBytes: Int
    private var remainingRows: Int

    init(maximumBytes: Int, maximumRows: Int) {
        remainingBytes = max(0, maximumBytes)
        remainingRows = max(0, maximumRows)
    }

    mutating func consumeRow() throws {
        guard remainingRows > 0 else { throw SQLiteReadOnlyError.rowLimitExceeded }
        remainingRows -= 1
    }

    mutating func consume(bytes: Int) throws {
        guard bytes <= remainingBytes else { throw SQLiteReadOnlyError.outputLimitExceeded }
        remainingBytes -= bytes
    }
}
