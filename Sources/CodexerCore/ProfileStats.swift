import Foundation

public struct ProfileStats: Equatable, Sendable {
    public var totalSessions: Int
    public var weeklySessions: Int
    public var activeSessions: Int
    public var archivedSessions: Int
    public var totalTokens: Int
    public var weeklyTokens: Int
    public var averageTokensPerSession: Int
    public var peakSessionTokens: Int
    public var weeklyTokenBuckets: [TokenUsageBucket]
    public var weeklyWarnings: Int
    public var weeklyErrors: Int
    public var dataBytes: Int64
    public var dataSizeIsTruncated: Bool
    public var dataSizeMeasuredAt: Date?
    public var lastActivityAt: Date?
    public var jobCounts: [String: Int]
    public var tokenizedSessions: Int
    public var modelUsage: [ModelUsageSummary]
    public var latestUsageLimit: UsageLimitSignal?
    public var errorMessages: [String]

    public static let empty = ProfileStats(
        totalSessions: 0,
        weeklySessions: 0,
        activeSessions: 0,
        archivedSessions: 0,
        totalTokens: 0,
        weeklyTokens: 0,
        averageTokensPerSession: 0,
        peakSessionTokens: 0,
        weeklyTokenBuckets: [],
        weeklyWarnings: 0,
        weeklyErrors: 0,
        dataBytes: 0,
        dataSizeIsTruncated: false,
        dataSizeMeasuredAt: nil,
        lastActivityAt: nil,
        jobCounts: [:],
        tokenizedSessions: 0,
        modelUsage: [],
        latestUsageLimit: nil,
        errorMessages: []
    )
}

public struct ModelUsageSummary: Equatable, Identifiable, Sendable {
    public var id: String { model }
    public var model: String
    public var sessions: Int
    public var tokens: Int
}

public struct UsageLimitSignal: Equatable, Hashable, Sendable {
    public enum Status: String, Equatable, Hashable, Sendable {
        case allowed
        case warning = "allowed_warning"
        case rejected
    }

    public var status: Status
    public var bucket: String?
    public var usedPercent: Double?
    public var resetsAt: Date?
    public var observedAt: Date
    public var isUsingOverage: Bool?

    public init(
        status: Status,
        bucket: String? = nil,
        usedPercent: Double? = nil,
        resetsAt: Date? = nil,
        observedAt: Date,
        isUsingOverage: Bool? = nil
    ) {
        self.status = status
        self.bucket = bucket
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.observedAt = observedAt
        self.isUsingOverage = isUsingOverage
    }
}

public struct TokenUsageBucket: Equatable, Identifiable, Sendable {
    public var id: Date { dayStart }
    public var dayStart: Date
    public var tokens: Int
    public var sessions: Int
}

public final class ProfileStatsScanner: @unchecked Sendable {
    private let fileManager: FileManager
    private let sqliteExecutable: URL
    private let queryTimeout: TimeInterval
    private let claudeChatScanner: LocalChatScanner
    private let dataSizeMaximumEntries: Int
    private let dataSizeMaximumDepth: Int
    private let dataSizeTimeout: TimeInterval
    private let dataSizeCacheLock = NSLock()
    private var dataSizeCache: [String: (measuredAt: Date, measurement: DirectorySizeMeasurement)] = [:]

    public init(
        fileManager: FileManager = .default,
        sqliteExecutable: URL = URL(fileURLWithPath: "/usr/bin/sqlite3"),
        queryTimeout: TimeInterval = 10,
        claudeChatScanner: LocalChatScanner = LocalChatScanner(maximumSessions: 10_000),
        dataSizeMaximumEntries: Int = 100_000,
        dataSizeMaximumDepth: Int = 64,
        dataSizeTimeout: TimeInterval = 2
    ) {
        self.fileManager = fileManager
        self.sqliteExecutable = sqliteExecutable
        self.queryTimeout = queryTimeout
        self.claudeChatScanner = claudeChatScanner
        self.dataSizeMaximumEntries = max(1, dataSizeMaximumEntries)
        self.dataSizeMaximumDepth = max(1, dataSizeMaximumDepth)
        self.dataSizeTimeout = max(0.01, dataSizeTimeout)
    }

    public func stats(for profile: CodexProfile, now: Date = Date()) -> ProfileStats {
        switch profile.product {
        case .codex:
            stats(
                codexHomeURL: profile.codexHomePath,
                dataRootURL: profile.profileDirectory,
                now: now
            )
        case .claude:
            claudeStats(
                result: claudeChatScanner.scanForStats(profile: profile),
                dataRootURL: profile.profileDirectory,
                now: now
            )
        }
    }

    public func stats(
        claudeUserDataURL: URL,
        claudeCodeHomeURL: URL,
        dataRootURL: URL,
        now: Date = Date()
    ) -> ProfileStats {
        claudeStats(
            result: claudeChatScanner.scanOfficialClaudeForStats(
                claudeHomeURL: claudeUserDataURL,
                claudeCodeHomeURL: claudeCodeHomeURL
            ),
            dataRootURL: dataRootURL,
            now: now
        )
    }

    public func stats(
        codexHomeURL: URL,
        dataRootURL: URL,
        now: Date = Date()
    ) -> ProfileStats {
        let weekStart = Int(now.timeIntervalSince1970) - (7 * 24 * 60 * 60)
        let stateDatabase = codexHomeURL.appendingPathComponent("state_5.sqlite")
        let logsDatabase = codexHomeURL.appendingPathComponent("logs_2.sqlite")

        var stats = ProfileStats.empty
        let dataSize = cachedDirectorySize(dataRootURL, now: now)
        stats.dataBytes = dataSize.bytes
        stats.dataSizeIsTruncated = dataSize.truncated
        stats.dataSizeMeasuredAt = dataSize.measuredAt
        guard !Task.isCancelled else { return stats }

        if fileManager.fileExists(atPath: stateDatabase.path) {
            let columns = tableColumns(
                database: stateDatabase,
                table: "threads",
                errors: &stats.errorMessages
            )
            let stateRows: [[String]]
            if columns.isEmpty {
                stats.errorMessages.append(
                    "Could not read profile state: the threads table is unavailable."
                )
                stateRows = []
            } else {
                stateRows = profileStateRows(
                    database: stateDatabase,
                    columns: columns,
                    weekStart: weekStart,
                    errors: &stats.errorMessages
                )
            }
            if let sessionValues = stateRows.first(where: { $0.first == "summary" }),
               sessionValues.count >= 9
            {
                stats.totalSessions = int(sessionValues[1])
                stats.weeklySessions = int(sessionValues[2])
                stats.activeSessions = int(sessionValues[3])
                stats.archivedSessions = int(sessionValues[4])
                stats.totalTokens = int(sessionValues[5])
                stats.weeklyTokens = int(sessionValues[6])
                stats.peakSessionTokens = int(sessionValues[7])
                stats.averageTokensPerSession = stats.totalSessions == 0 ? 0 : stats.totalTokens / stats.totalSessions
                let lastUpdated = int(sessionValues[8])
                if lastUpdated > 0 {
                    stats.lastActivityAt = Date(timeIntervalSince1970: TimeInterval(lastUpdated))
                }
            }

            guard !Task.isCancelled else { return stats }
            stats.weeklyTokenBuckets = stateRows.compactMap { row in
                guard row.first == "bucket", row.count >= 4 else { return nil }
                return TokenUsageBucket(
                    dayStart: Date(timeIntervalSince1970: TimeInterval(int(row[1]))),
                    tokens: int(row[2]),
                    sessions: int(row[3])
                )
            }
            stats.jobCounts = stateRows.reduce(into: [:]) { result, row in
                guard row.first == "job", row.count >= 3, !row[1].isEmpty else {
                    return
                }
                result[row[1]] = int(row[2])
            }

            var schemaErrors: [String] = []
            let hasAgentJobs = querySingleRow(
                database: stateDatabase,
                sql: "select count(*) from sqlite_schema where type = 'table' and name = 'agent_jobs';",
                operation: "profile schema",
                errors: &schemaErrors
            ).first == "1"
            if hasAgentJobs {
                let jobRows = queryRows(
                    database: stateDatabase,
                    sql: "select 'job', status, count(*) from agent_jobs group by status;",
                    operation: "job summary",
                    errors: &stats.errorMessages
                )
                stats.jobCounts = jobRows.reduce(into: [:]) { result, row in
                    guard row.first == "job", row.count >= 3, !row[1].isEmpty else {
                        return
                    }
                    result[row[1]] = int(row[2])
                }
            }
        }

        guard !Task.isCancelled else { return stats }
        if fileManager.fileExists(atPath: logsDatabase.path) {
            let logValues = querySingleRow(
                database: logsDatabase,
                sql: """
                select
                  coalesce(sum(case when upper(level) in ('WARN', 'WARNING') then 1 else 0 end), 0),
                  coalesce(sum(case when upper(level) = 'ERROR' then 1 else 0 end), 0),
                  (select coalesce(max(ts), 0) from logs)
                from logs
                where ts >= \(weekStart);
                """,
                operation: "log summary",
                errors: &stats.errorMessages
            )
            if logValues.count >= 3 {
                stats.weeklyWarnings = int(logValues[0])
                stats.weeklyErrors = int(logValues[1])
                let lastLog = int(logValues[2])
                if lastLog > 0 {
                    let logDate = Date(timeIntervalSince1970: TimeInterval(lastLog))
                    if stats.lastActivityAt == nil || logDate > (stats.lastActivityAt ?? .distantPast) {
                        stats.lastActivityAt = logDate
                    }
                }
            }
        }

        return stats
    }

    private func claudeStats(
        result: LocalChatScanResult,
        dataRootURL: URL,
        now: Date
    ) -> ProfileStats {
        var stats = ProfileStats.empty
        let dataSize = cachedDirectorySize(dataRootURL, now: now)
        stats.dataBytes = dataSize.bytes
        stats.dataSizeIsTruncated = dataSize.truncated
        stats.dataSizeMeasuredAt = dataSize.measuredAt
        guard !Task.isCancelled else { return stats }

        let sessions = result.sessions
        if result.diagnostics.inventoryTruncated {
            stats.errorMessages.append("Local activity coverage is partial: some records could not be inspected within safety limits. Totals reflect only the inspected records.")
        }
        let weekStart = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let weekly = sessions.filter { $0.updatedAt >= weekStart && $0.updatedAt <= now }
        let tokenized = sessions.filter { $0.tokenCount != nil }

        stats.totalSessions = sessions.count
        stats.weeklySessions = weekly.count
        stats.activeSessions = sessions.filter { $0.status != "Archived" }.count
        stats.archivedSessions = sessions.filter { $0.status == "Archived" }.count
        stats.tokenizedSessions = tokenized.count
        stats.totalTokens = tokenized.reduce(0) {
            Self.saturatingAdd($0, $1.tokenCount ?? 0)
        }
        stats.weeklyTokens = weekly.reduce(0) {
            Self.saturatingAdd($0, $1.tokenCount ?? 0)
        }
        stats.peakSessionTokens = tokenized.compactMap(\.tokenCount).max() ?? 0
        stats.averageTokensPerSession = tokenized.isEmpty
            ? 0
            : stats.totalTokens / tokenized.count
        stats.lastActivityAt = sessions.map(\.updatedAt).max()
        stats.latestUsageLimit = sessions.compactMap(\.latestUsageLimit).max {
            $0.observedAt < $1.observedAt
        }

        let calendar = Calendar(identifier: .gregorian)
        let buckets = Dictionary(grouping: weekly) { calendar.startOfDay(for: $0.updatedAt) }
        stats.weeklyTokenBuckets = buckets.map { day, sessions in
            TokenUsageBucket(
                dayStart: day,
                tokens: sessions.reduce(0) { Self.saturatingAdd($0, $1.tokenCount ?? 0) },
                sessions: sessions.count
            )
        }.sorted { $0.dayStart < $1.dayStart }

        let models = Dictionary(grouping: sessions) { session in
            session.model?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? session.model!
                : "Unknown model"
        }
        stats.modelUsage = models.map { model, sessions in
            ModelUsageSummary(
                model: model,
                sessions: sessions.count,
                tokens: sessions.reduce(0) { Self.saturatingAdd($0, $1.tokenCount ?? 0) }
            )
        }.sorted {
            if $0.tokens == $1.tokens { return $0.sessions > $1.sessions }
            return $0.tokens > $1.tokens
        }
        return stats
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    private func profileStateRows(
        database: URL,
        columns: Set<String>,
        weekStart: Int,
        errors: inout [String]
    ) -> [[String]] {
        let timestampColumn = [
            "recency_at_ms", "updated_at_ms", "updated_at", "created_at_ms", "created_at"
        ].first(where: columns.contains)
        let timestampExpression: String
        if let timestampColumn {
            timestampExpression = timestampColumn.hasSuffix("_ms")
                ? "cast(\(timestampColumn) / 1000 as integer)"
                : timestampColumn
        } else {
            timestampExpression = "0"
        }
        let tokenColumn = ["tokens_used", "token_count"].first(where: columns.contains)
        let tokenExpression = tokenColumn.map { "coalesce(\($0), 0)" } ?? "0"
        let archivedExpression = columns.contains("archived")
            ? "case when archived is not null and archived != 0 then 1 else 0 end"
            : "0"
        let bucketQuery = timestampColumn != nil && tokenColumn != nil
            ? """
              select
                'bucket',
                cast(\(timestampExpression) / 86400 as integer) * 86400 as day_start,
                sum(\(tokenExpression)),
                count(*)
              from threads
              where \(timestampExpression) >= \(weekStart) and \(tokenExpression) > 0
              group by day_start
              order by day_start;
              """
            : ""
        return queryRows(
            database: database,
            sql: """
            select
              'summary',
              count(*),
              coalesce(sum(case when \(timestampExpression) >= \(weekStart) then 1 else 0 end), 0),
              coalesce(sum(case when \(archivedExpression) = 0 then 1 else 0 end), 0),
              coalesce(sum(\(archivedExpression)), 0),
              coalesce(sum(\(tokenExpression)), 0),
              coalesce(sum(case when \(timestampExpression) >= \(weekStart) then \(tokenExpression) else 0 end), 0),
              coalesce(max(\(tokenExpression)), 0),
              coalesce(max(\(timestampExpression)), 0)
            from threads;
            \(bucketQuery)
            """,
            operation: "profile state",
            errors: &errors
        )
    }

    private func tableColumns(
        database: URL,
        table: String,
        errors: inout [String]
    ) -> Set<String> {
        Set(
            queryRows(
                database: database,
                sql: "pragma table_info(\(table));",
                operation: "profile schema",
                errors: &errors
            ).compactMap { row in
                row.count > 1 ? row[1] : nil
            }
        )
    }

    private func querySingleRow(
        database: URL,
        sql: String,
        operation: String,
        errors: inout [String]
    ) -> [String] {
        queryRows(database: database, sql: sql, operation: operation, errors: &errors).first ?? []
    }

    private func queryRows(
        database: URL,
        sql: String,
        operation: String,
        errors: inout [String]
    ) -> [[String]] {
        let databaseArgument: String
        do {
            databaseArgument = try SQLiteReadOnly.databaseArgument(for: database)
        } catch {
            errors.append("Could not read \(operation): the database path is not safe.")
            return []
        }
        let process = Process()
        process.executableURL = sqliteExecutable
        process.arguments = [
            "-nofollow",
            "-readonly",
            "-noheader",
            "-separator",
            "\u{1F}",
            databaseArgument,
            sql
        ]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let capture = StatsProcessCapture(maximumBytes: 8 * 1_024 * 1_024)
        let completion = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            capture.append(handle.availableData)
        }
        process.terminationHandler = { _ in completion.signal() }

        do {
            try process.run()
            let deadline = Date().addingTimeInterval(queryTimeout)
            var completed = false
            while !Task.isCancelled, Date() < deadline {
                if completion.wait(timeout: .now() + 0.1) == .success {
                    completed = true
                    break
                }
            }
            guard !Task.isCancelled else {
                output.fileHandleForReading.readabilityHandler = nil
                SubprocessTerminator.terminateAndWait(process)
                return []
            }
            guard completed else {
                output.fileHandleForReading.readabilityHandler = nil
                SubprocessTerminator.terminateAndWait(process)
                errors.append("Timed out reading \(operation).")
                return []
            }
            output.fileHandleForReading.readabilityHandler = nil
            capture.append(output.fileHandleForReading.readDataToEndOfFile())
            process.waitUntilExit()
            if capture.exceededLimit {
                errors.append("Could not read \(operation): sqlite3 output exceeded the safety limit.")
                return []
            }
            guard process.terminationStatus == 0 else {
                errors.append("Could not read \(operation) (sqlite3 exited with status \(process.terminationStatus)).")
                return []
            }
            let data = capture.data
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                return []
            }
            return text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { line in
                    line.split(separator: "\u{1F}", omittingEmptySubsequences: false)
                        .map(String.init)
                }
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            SubprocessTerminator.terminateAndWait(process)
            errors.append("Could not read \(operation): \(error.localizedDescription)")
            return []
        }
    }

    private func directorySize(_ url: URL) -> DirectorySizeMeasurement {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [
                .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey
            ],
            options: []
        ) else {
            return DirectorySizeMeasurement(bytes: 0, truncated: false, cancelled: false)
        }

        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(dataSizeTimeout * 1_000_000_000)
        var total: Int64 = 0
        var visited = 0
        var depthTruncated = false
        for case let fileURL as URL in enumerator {
            guard !Task.isCancelled else {
                return DirectorySizeMeasurement(bytes: total, truncated: true, cancelled: true)
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                return DirectorySizeMeasurement(bytes: total, truncated: true, cancelled: false)
            }
            guard visited < dataSizeMaximumEntries else {
                return DirectorySizeMeasurement(bytes: total, truncated: true, cancelled: false)
            }
            visited += 1
            if enumerator.level > dataSizeMaximumDepth {
                depthTruncated = true
                enumerator.skipDescendants()
                continue
            }
            guard
                let values = try? fileURL.resourceValues(forKeys: [
                    .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey
                ]),
                values.isSymbolicLink != true,
                values.isRegularFile == true
            else {
                continue
            }
            let size = Int64(max(0, values.fileSize ?? 0))
            let (sum, overflow) = total.addingReportingOverflow(size)
            if overflow {
                return DirectorySizeMeasurement(
                    bytes: Int64.max,
                    truncated: true,
                    cancelled: false
                )
            }
            total = sum
        }
        return DirectorySizeMeasurement(bytes: total, truncated: depthTruncated, cancelled: false)
    }

    private func cachedDirectorySize(_ url: URL, now: Date) -> DirectorySizeMeasurement {
        let key = url.standardizedFileURL.path
        if let cached = dataSizeCacheLock.withLock({ dataSizeCache[key] }),
           now >= cached.measuredAt,
           now.timeIntervalSince(cached.measuredAt) < 10 * 60
        {
            return cached.measurement
        }
        var measurement = directorySize(url)
        measurement.measuredAt = now
        if !measurement.cancelled {
            dataSizeCacheLock.withLock {
                if dataSizeCache.count >= 64, dataSizeCache[key] == nil,
                   let oldest = dataSizeCache.min(by: { $0.value.measuredAt < $1.value.measuredAt })?.key
                {
                    dataSizeCache.removeValue(forKey: oldest)
                }
                dataSizeCache[key] = (now, measurement)
            }
        }
        return measurement
    }

    private func int(_ value: String) -> Int {
        Int(value) ?? 0
    }

}

private struct DirectorySizeMeasurement: Sendable {
    var bytes: Int64
    var truncated: Bool
    var cancelled: Bool
    var measuredAt: Date? = nil
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}

private final class StatsProcessCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var storage = Data()
    private var overflowed = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var exceededLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return overflowed
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !overflowed else { return }
        guard storage.count + data.count <= maximumBytes else {
            overflowed = true
            storage.removeAll(keepingCapacity: false)
            return
        }
        storage.append(data)
    }
}
