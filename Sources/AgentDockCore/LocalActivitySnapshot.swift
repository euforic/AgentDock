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
    private static let sqliteURL = URL(fileURLWithPath: "/usr/bin/sqlite3")

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
            PRAGMA query_only=ON;
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
            decode: decodeLogs
        )

        try Task.checkCancellation()

        let threadsResult: ReadResult<LocalArchivedThreadSummary> = readDatabase(
            at: codexHomeURL.appendingPathComponent("state_5.sqlite"),
            source: .archivedThreads,
            query: """
            PRAGMA query_only=ON;
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
        decode: (Data) throws -> [Value]
    ) -> ReadResult<Value> {
        guard fileManager.isReadableFile(atPath: databaseURL.path) else {
            return ReadResult(
                values: [],
                issues: [LocalActivityIssue(source: source, message: "Database is not available.")],
                succeeded: false
            )
        }

        do {
            let databaseArgument = try SQLiteReadOnly.databaseArgument(for: databaseURL)
            let result = try BoundedSubprocess.run(
                executableURL: Self.sqliteURL,
                arguments: [
                    "-nofollow",
                    "-readonly",
                    "-json",
                    databaseArgument,
                    query
                ],
                timeout: timeout,
                maximumOutputBytes: maximumOutputBytes,
                captureStandardError: true
            )
            if Task.isCancelled {
                return ReadResult(values: [], issues: [], succeeded: false)
            }
            guard !result.exceededOutputLimit else {
                return ReadResult(
                    values: [],
                    issues: [LocalActivityIssue(source: source, message: "Database output exceeded the safety limit.")],
                    succeeded: false
                )
            }
            guard result.terminationStatus == 0 else {
                return ReadResult(
                    values: [],
                    issues: [LocalActivityIssue(source: source, message: "Database could not be read.")],
                    succeeded: false
                )
            }
            return ReadResult(values: try decode(result.output), issues: [], succeeded: true)
        } catch {
            return ReadResult(
                values: [],
                issues: [LocalActivityIssue(source: source, message: "Database read timed out or failed.")],
                succeeded: false
            )
        }
    }

    private func decodeLogs(_ data: Data) throws -> [LocalActivityLogEntry] {
        try decode([LogRow].self, from: data).map {
            LocalActivityLogEntry(
                timestamp: Self.date(fromUnixValue: $0.ts),
                level: Self.cleanMetadata($0.level),
                target: Self.cleanMetadata($0.target),
                message: Self.safeMessage($0.message),
                source: Self.safeSource($0.source),
                threadID: Self.nonempty(Self.cleanMetadata($0.threadID ?? ""))
            )
        }
    }

    private func decodeArchivedThreads(_ data: Data) throws -> [LocalArchivedThreadSummary] {
        try decode([ArchivedThreadRow].self, from: data).map {
            LocalArchivedThreadSummary(
                id: Self.cleanMetadata($0.id),
                title: Self.safeMessage($0.title),
                repository: Self.repositoryBasename($0.cwd),
                branch: Self.nonempty(Self.cleanMetadata($0.gitBranch ?? "")),
                updatedAt: Self.date(fromUnixValue: $0.updatedAt),
                archivedAt: $0.archivedAt.map(Self.date(fromUnixValue:)),
                tokenCount: max(0, $0.tokensUsed)
            )
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let input = data.isEmpty ? Data("[]".utf8) : data
        return try JSONDecoder().decode(type, from: input)
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

private struct LogRow: Decodable {
    let ts: Int64
    let level: String
    let target: String
    let message: String
    let source: String?
    let threadID: String?

    enum CodingKeys: String, CodingKey {
        case ts
        case level
        case target
        case message
        case source
        case threadID = "thread_id"
    }
}

private struct ArchivedThreadRow: Decodable {
    let id: String
    let title: String
    let cwd: String
    let gitBranch: String?
    let updatedAt: Int64
    let archivedAt: Int64?
    let tokensUsed: Int

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case cwd
        case gitBranch = "git_branch"
        case updatedAt = "updated_at"
        case archivedAt = "archived_at"
        case tokensUsed = "tokens_used"
    }
}
