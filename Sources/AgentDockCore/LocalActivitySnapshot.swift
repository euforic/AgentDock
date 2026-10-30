import Foundation

public enum LocalActivityAvailability: Equatable, Sendable {
    case available
    case partial
    case unavailable
}

public enum LocalActivitySource: String, Equatable, Sendable {
    case logs
    case archivedThreads
}

public struct LocalActivityIssue: Hashable, Sendable {
    public let source: LocalActivitySource
    public let message: String

    public init(source: LocalActivitySource, message: String) {
        self.source = source
        self.message = message
    }
}

public struct LocalActivityLogEntry: Hashable, Sendable {
    public let timestamp: Date
    public let level: String
    public let target: String
    public let message: String
    public let source: String?
    public let threadID: String?

    public init(
        timestamp: Date,
        level: String,
        target: String,
        message: String,
        source: String?,
        threadID: String?
    ) {
        self.timestamp = timestamp
        self.level = level
        self.target = target
        self.message = message
        self.source = source
        self.threadID = threadID
    }
}

public struct LocalArchivedThreadSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let repository: String?
    public let branch: String?
    public let updatedAt: Date
    public let archivedAt: Date?
    public let tokenCount: Int

    public init(
        id: String,
        title: String,
        repository: String?,
        branch: String?,
        updatedAt: Date,
        archivedAt: Date?,
        tokenCount: Int
    ) {
        self.id = id
        self.title = title
        self.repository = repository
        self.branch = branch
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
        self.tokenCount = tokenCount
    }
}

public struct LocalActivitySnapshot: Sendable {
    public let availability: LocalActivityAvailability
    public let logs: [LocalActivityLogEntry]
    public let archivedThreads: [LocalArchivedThreadSummary]
    public let issues: [LocalActivityIssue]

    public init(
        availability: LocalActivityAvailability,
        logs: [LocalActivityLogEntry],
        archivedThreads: [LocalArchivedThreadSummary],
        issues: [LocalActivityIssue]
    ) {
        self.availability = availability
        self.logs = logs
        self.archivedThreads = archivedThreads
        self.issues = issues
    }
}

public struct LocalActivityReader: @unchecked Sendable {
    private let fileManager: FileManager
    private let maximumLogEntries: Int
    private let maximumArchivedThreads: Int
    private let timeout: TimeInterval
    private let maximumOutputBytes: Int

    public init(
        fileManager: FileManager = .default,
        maximumLogEntries: Int = 200,
        maximumArchivedThreads: Int = 100,
        timeout: TimeInterval = 2,
        maximumOutputBytes: Int = 512 * 1_024
    ) {
        self.fileManager = fileManager
        self.maximumLogEntries = min(max(0, maximumLogEntries), 200)
        self.maximumArchivedThreads = min(max(0, maximumArchivedThreads), 100)
        self.timeout = min(max(0.1, timeout), 5)
        self.maximumOutputBytes = min(max(1_024, maximumOutputBytes), 1_024 * 1_024)
    }

    public func read(codexHomeURL: URL) async throws -> LocalActivitySnapshot {
        try Task.checkCancellation()

        let logsResult: ReadResult<LocalActivityLogEntry> = readDatabase(
            at: codexHomeURL.appendingPathComponent("logs_2.sqlite"),
            source: .logs,
            query: """
            SELECT
                ts,
                level,
                substr(target, 1, 256) AS target,
                substr(COALESCE(feedback_log_body, ''), 1, 4096) AS message,
                substr(COALESCE(module_path, file), 1, 512) AS source,
                substr(thread_id, 1, 128) AS thread_id
            FROM logs
            ORDER BY ts DESC, ts_nanos DESC, id DESC
            LIMIT \(maximumLogEntries);
            """,
            maximumRows: maximumLogEntries,
            decode: decodeLogs
        )

        try Task.checkCancellation()

        let threadsResult: ReadResult<LocalArchivedThreadSummary> = readDatabase(
            at: codexHomeURL.appendingPathComponent("state_5.sqlite"),
            source: .archivedThreads,
            query: """
            SELECT
                substr(id, 1, 128) AS id,
                substr(title, 1, 512) AS title,
                substr(cwd, 1, 2048) AS cwd,
                substr(git_branch, 1, 256) AS git_branch,
                updated_at,
                archived_at,
                tokens_used
            FROM threads
            WHERE archived = 1
            ORDER BY COALESCE(archived_at, updated_at) DESC, id DESC
            LIMIT \(maximumArchivedThreads);
            """,
            maximumRows: maximumArchivedThreads,
            decode: decodeArchivedThreads
        )

        try Task.checkCancellation()

        let successes = [logsResult.succeeded, threadsResult.succeeded].filter { $0 }.count
        let availability: LocalActivityAvailability
        switch successes {
        case 2:
            availability = .available
        case 1:
            availability = .partial
        default:
            availability = .unavailable
        }

        return LocalActivitySnapshot(
            availability: availability,
            logs: logsResult.values,
            archivedThreads: threadsResult.values,
            issues: logsResult.issues + threadsResult.issues
        )
    }

    private func readDatabase<Value>(
        at databaseURL: URL,
        source: LocalActivitySource,
        query: String,
        maximumRows: Int,
        decode: ([[SQLiteValue]]) throws -> [Value]
    ) -> ReadResult<Value> {
        guard fileManager.isReadableFile(atPath: databaseURL.path) else {
            return ReadResult(
                values: [],
                issues: [LocalActivityIssue(source: source, message: "Database is not available.")],
                succeeded: false
            )
        }

        do {
            let rows = try SQLiteReadOnly.query(
                database: databaseURL,
                sql: query,
                timeout: timeout,
                maximumOutputBytes: maximumOutputBytes,
                maximumRows: maximumRows
            )
            return ReadResult(values: try decode(rows), issues: [], succeeded: true)
        } catch SQLiteReadOnlyError.cancelled {
            return ReadResult(values: [], issues: [], succeeded: false)
        } catch SQLiteReadOnlyError.outputLimitExceeded, SQLiteReadOnlyError.rowLimitExceeded {
            return ReadResult(
                values: [],
                issues: [LocalActivityIssue(source: source, message: "Database output exceeded the safety limit.")],
                succeeded: false
            )
        } catch SQLiteReadOnlyError.sqlite(_) {
            return ReadResult(
                values: [],
                issues: [LocalActivityIssue(source: source, message: "Database could not be read.")],
                succeeded: false
            )
        } catch {
            return ReadResult(
                values: [],
                issues: [LocalActivityIssue(source: source, message: "Database read timed out or failed.")],
                succeeded: false
            )
        }
    }

    private func decodeLogs(_ rows: [[SQLiteValue]]) throws -> [LocalActivityLogEntry] {
        try rows.map { values in
            let row = try ActivityRow(values, columns: 6)
            return LocalActivityLogEntry(
                timestamp: Self.date(fromUnixValue: try row.integer(0)),
                level: Self.cleanMetadata(try row.text(1)),
                target: Self.cleanMetadata(try row.text(2)),
                message: Self.safeMessage(try row.text(3)),
                source: Self.safeSource(try row.optionalText(4)),
                threadID: Self.nonempty(Self.cleanMetadata(try row.optionalText(5) ?? ""))
            )
        }
    }

    private func decodeArchivedThreads(_ rows: [[SQLiteValue]]) throws -> [LocalArchivedThreadSummary] {
        try rows.map { values in
            let row = try ActivityRow(values, columns: 7)
            return LocalArchivedThreadSummary(
                id: Self.cleanMetadata(try row.text(0)),
                title: Self.safeMessage(try row.text(1)),
                repository: Self.repositoryBasename(try row.text(2)),
                branch: Self.nonempty(Self.cleanMetadata(try row.optionalText(3) ?? "")),
                updatedAt: Self.date(fromUnixValue: try row.integer(4)),
                archivedAt: try row.optionalInteger(5).map(Self.date(fromUnixValue:)),
                tokenCount: max(0, Int(try row.integer(6)))
            )
        }
    }

    private static func date(fromUnixValue value: Int64) -> Date {
        let seconds = value > 100_000_000_000 ? Double(value) / 1_000 : Double(value)
        return Date(timeIntervalSince1970: seconds)
    }

    private static func repositoryBasename(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return nonempty(URL(fileURLWithPath: trimmed).lastPathComponent)
    }

    private static func safeSource(_ source: String?) -> String? {
        guard let source = nonempty(cleanMetadata(source ?? "")) else { return nil }
        if source.hasPrefix("/") {
            return URL(fileURLWithPath: source).lastPathComponent
        }
        return source
    }

    private static func safeMessage(_ raw: String) -> String {
        var value = cleanMetadata(raw)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !home.isEmpty {
            value = value.replacingOccurrences(of: home, with: "~")
        }
        value = redactAbsolutePaths(in: value)
        value = replacing(
            pattern: #"(?i)\b(authorization\s*:\s*bearer|bearer)\s+\S+"#,
            in: value,
            with: "$1 [REDACTED]"
        )
        value = replacing(
            pattern: #"(?i)\b(api[_-]?key|access[_-]?token|secret|password)\s*[:=]\s*[^\s,;]+"#,
            in: value,
            with: "$1=[REDACTED]"
        )
        if value.count > 1_000 {
            value = String(value.prefix(1_000)) + "…"
        }
        return value
    }

    private static func redactAbsolutePaths(in value: String) -> String {
        let pattern = #"(?<![:/~])/(?:[^\s'"`;:,()\[\]]+/)*[^\s'"`;:,()\[\]]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let matches = expression.matches(in: value, range: NSRange(value.startIndex..., in: value))
        var result = value
        for match in matches.reversed() {
            guard
                let range = Range(match.range, in: result)
            else {
                continue
            }
            let basename = URL(fileURLWithPath: String(result[range])).lastPathComponent
            result.replaceSubrange(range, with: "…/\(basename)")
        }
        return result
    }

    private static func cleanMetadata(_ raw: String) -> String {
        raw.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(pattern: String, in value: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        return expression.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: replacement
        )
    }

    private static func nonempty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}

private struct ReadResult<Value> {
    let values: [Value]
    let issues: [LocalActivityIssue]
    let succeeded: Bool
}

/// Typed columns from a fixed `SELECT`. A missing, NULL, or mistyped required
/// value fails the whole read rather than inventing a default.
private struct ActivityRow {
    private let values: [SQLiteValue]

    init(_ values: [SQLiteValue], columns: Int) throws {
        guard values.count == columns else { throw ActivityRowError.malformed }
        self.values = values
    }

    func integer(_ column: Int) throws -> Int64 {
        guard let value = try optionalInteger(column) else { throw ActivityRowError.malformed }
        return value
    }

    func optionalInteger(_ column: Int) throws -> Int64? {
        switch values[column] {
        case .null: return nil
        case let .integer(value): return value
        case let .real(value):
            guard let integer = Int64(exactly: value) else { throw ActivityRowError.malformed }
            return integer
        case .text, .blob: throw ActivityRowError.malformed
        }
    }

    func text(_ column: Int) throws -> String {
        guard let value = try optionalText(column) else { throw ActivityRowError.malformed }
        return value
    }

    func optionalText(_ column: Int) throws -> String? {
        switch values[column] {
        case .null: return nil
        case let .text(value): return value
        case .integer, .real, .blob: throw ActivityRowError.malformed
        }
    }
}

private enum ActivityRowError: Error {
    case malformed
}
