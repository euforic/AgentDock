import Foundation
import Darwin

private struct ClaudeUsageSummary: Sendable {
    let totalTokens: Int
    let latestUsageLimit: UsageLimitSignal?
    let isPartial: Bool
}

private struct LocalFileSignature: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
}

private final class ClaudeUsageCache: @unchecked Sendable {
    private struct Entry {
        let signature: LocalFileSignature
        let summary: ClaudeUsageSummary
        var previous: String?
        var next: String?
    }

    private let lock = NSLock()
    private let capacity: Int
    private var entries: [String: Entry] = [:]
    private var oldest: String?
    private var newest: String?

    init(capacity: Int) { self.capacity = max(1, capacity) }

    func value(for path: String, signature: LocalFileSignature) -> ClaudeUsageSummary? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[path], entry.signature == signature
        else { return nil }
        moveToNewest(path)
        return entry.summary
    }

    func store(_ summary: ClaudeUsageSummary, for path: String, signature: LocalFileSignature) {
        lock.lock()
        defer { lock.unlock() }
        if entries[path] != nil { remove(path) }
        if entries.count >= capacity, let oldest { remove(oldest) }
        entries[path] = Entry(
            signature: signature, summary: summary,
            previous: newest, next: nil
        )
        if let newest { entries[newest]?.next = path }
        else { oldest = path }
        newest = path
    }

    private func moveToNewest(_ path: String) {
        guard newest != path, let entry = entries[path] else { return }
        remove(path)
        entries[path] = Entry(
            signature: entry.signature, summary: entry.summary,
            previous: newest, next: nil
        )
        if let newest { entries[newest]?.next = path }
        else { oldest = path }
        newest = path
    }

    private func remove(_ path: String) {
        guard let entry = entries.removeValue(forKey: path) else { return }
        if let previous = entry.previous { entries[previous]?.next = entry.next }
        else { oldest = entry.next }
        if let next = entry.next { entries[next]?.previous = entry.previous }
        else { newest = entry.previous }
    }
}

public struct LocalChatSession: Identifiable, Hashable, Sendable {
    public let id: String
    public let provider: DesktopProduct
    public let profileID: CodexProfile.ID?
    public let profileName: String
    public let model: String?
    public let startedAt: Date
    public let updatedAt: Date
    public let tokenCount: Int?
    public let latestUsageLimit: UsageLimitSignal?
    public let status: String

    public var duration: TimeInterval {
        max(0, updatedAt.timeIntervalSince(startedAt))
    }

    init(
        id: String,
        provider: DesktopProduct,
        profileID: CodexProfile.ID?,
        profileName: String,
        model: String?,
        startedAt: Date,
        updatedAt: Date,
        tokenCount: Int?,
        latestUsageLimit: UsageLimitSignal? = nil,
        status: String
    ) {
        self.id = id
        self.provider = provider
        self.profileID = profileID
        self.profileName = profileName
        self.model = model
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.tokenCount = tokenCount
        self.latestUsageLimit = latestUsageLimit
        self.status = status
    }
}

public struct LocalChatScanDiagnostics: Equatable, Sendable {
    public let cacheHitCount: Int
    public let parsedFileCount: Int
    public let sourceFileCount: Int
    public let inventoryTruncated: Bool
    public let inspectedHistoryBytes: Int

    public init(
        cacheHitCount: Int = 0,
        parsedFileCount: Int = 0,
        sourceFileCount: Int = 0,
        inventoryTruncated: Bool = false,
        inspectedHistoryBytes: Int = 0
    ) {
        self.cacheHitCount = cacheHitCount
        self.parsedFileCount = parsedFileCount
        self.sourceFileCount = sourceFileCount
        self.inventoryTruncated = inventoryTruncated
        self.inspectedHistoryBytes = inspectedHistoryBytes
    }
}

public struct LocalChatScanResult: Sendable {
    public let sessions: [LocalChatSession]
    public let diagnostics: LocalChatScanDiagnostics

    public init(
        sessions: [LocalChatSession],
        diagnostics: LocalChatScanDiagnostics = .init()
    ) {
        self.sessions = sessions
        self.diagnostics = diagnostics
    }
}

public struct LocalChatScanner: @unchecked Sendable {
    private static let indexMutationLock = NSLock()

    private let fileManager: FileManager
    private let maximumSessions: Int
    private let maximumSummaryLineBytes: Int
    private let maximumInventoryFiles: Int
    private let maximumMetadataBytes: Int
    private let maximumClaudeUsageBytes: Int
    private let indexRootURL: URL
    private let claudeUsageCache: ClaudeUsageCache
    private let claudeHistoryCache = ClaudeHistoryCache()

    public init(
        fileManager: FileManager = .default,
        maximumSessions: Int = 1_000,
        maximumSummaryLineBytes: Int = 2 * 1_024 * 1_024,
        maximumInventoryFiles: Int? = nil,
        maximumMetadataBytes: Int = 16 * 1_024 * 1_024,
        maximumClaudeUsageBytes: Int = 512 * 1_024 * 1_024,
        maximumClaudeUsageCacheEntries: Int = 10_000,
        indexRootURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.maximumSessions = maximumSessions
        self.maximumSummaryLineBytes = maximumSummaryLineBytes
        self.maximumInventoryFiles = max(
            1,
            maximumInventoryFiles
                ?? (maximumSessions > 2_500 ? 10_000 : max(1, maximumSessions * 4))
        )
        self.maximumMetadataBytes = max(1, maximumMetadataBytes)
        self.maximumClaudeUsageBytes = max(1, maximumClaudeUsageBytes)
        self.indexRootURL = indexRootURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AgentDock/ChatIndexes", isDirectory: true)
        claudeUsageCache = ClaudeUsageCache(capacity: maximumClaudeUsageCacheEntries)
    }

    func scanForStats(profile: CodexProfile) -> LocalChatScanResult {
        guard profile.product == .claude else { return .init(sessions: []) }
        return scanClaudeUserData(
            userDataURL: profile.claudeUserDataPath,
            profileID: profile.id, profileName: profile.name
        )
    }

    func scanOfficialClaudeForStats(claudeHomeURL: URL, claudeCodeHomeURL: URL) -> LocalChatScanResult {
        let primary = scanClaudeUserData(
            userDataURL: claudeHomeURL,
            profileID: nil,
            profileName: "Official Claude"
        )
        guard !Task.isCancelled else { return primary }
        let fallback = scanClaudeCode(claudeHomeURL: claudeCodeHomeURL)
        let sorted = (primary.sessions + fallback.sessions).sorted {
            if $0.updatedAt == $1.updatedAt { return $0.id > $1.id }
            return $0.updatedAt > $1.updatedAt
        }
        var seenIDs: Set<String> = []
        let sessions = sorted.filter { seenIDs.insert($0.id).inserted }
        return .init(
            sessions: Array(sessions.prefix(maximumSessions)),
            diagnostics: .init(
                cacheHitCount: primary.diagnostics.cacheHitCount + fallback.diagnostics.cacheHitCount,
                parsedFileCount: primary.diagnostics.parsedFileCount
                    + fallback.diagnostics.parsedFileCount,
                sourceFileCount: primary.diagnostics.sourceFileCount
                    + fallback.diagnostics.sourceFileCount,
                inventoryTruncated: primary.diagnostics.inventoryTruncated
                    || fallback.diagnostics.inventoryTruncated || sessions.count > maximumSessions,
                inspectedHistoryBytes: fallback.diagnostics.inspectedHistoryBytes
            )
        )
    }

    public func removeIndex(profileID: CodexProfile.ID) {
        Self.indexMutationLock.lock()
        defer { Self.indexMutationLock.unlock() }
        let scopeKey = "managed-\(profileID.uuidString.lowercased())"
        try? fileManager.removeItem(at: indexURL(scopeKey: scopeKey))
        try? fileManager.removeItem(
            at: indexRootURL.appendingPathComponent("\(scopeKey)-v1.json")
        )
    }

    private func scanClaudeUserData(
        userDataURL: URL,
        profileID: CodexProfile.ID?,
        profileName: String
    ) -> LocalChatScanResult {
        let inventory = claudeUserDataInventory(userDataURL: userDataURL)
        guard !Task.isCancelled else { return .init(sessions: []) }
        return .init(
            sessions: inventory.records.map { record in
                LocalChatSession(
                    id: record.id,
                    provider: .claude,
                    profileID: profileID,
                    profileName: profileName,
                    model: record.model,
                    startedAt: record.startedAt,
                    updatedAt: record.updatedAt,
                    tokenCount: record.tokenCount,
                    latestUsageLimit: record.latestUsageLimit,
                    status: record.status
                )
            },
            diagnostics: .init(
                cacheHitCount: inventory.cacheHits,
                parsedFileCount: inventory.records.count - inventory.cacheHits,
                sourceFileCount: inventory.records.count,
                inventoryTruncated: inventory.truncated
            )
        )
    }

    private func claudeUserDataInventory(userDataURL: URL) -> ClaudeUserDataInventory {
        let metadataInventory = claudeMetadataCandidates(userDataURL: userDataURL)
        let candidates = metadataInventory.candidates.sorted {
            if $0.modifiedAt == $1.modifiedAt { return $0.relativePath < $1.relativePath }
            return $0.modifiedAt > $1.modifiedAt
        }
        var records: [ClaudeUserDataRecord] = []
        var metadataBytes = 0
        var remainingUsageBytes = maximumClaudeUsageBytes
        var cacheHits = 0
        var truncated = metadataInventory.truncated
        for candidate in candidates {
            guard !Task.isCancelled else { break }
            let source = claudeAuditSourceFile(
                userDataURL: userDataURL,
                relativeMetadataPath: candidate.relativePath
            )
            guard
                candidate.fileSize <= maximumSummaryLineBytes,
                metadataBytes <= maximumMetadataBytes - candidate.fileSize,
                let source
            else {
                truncated = true
                continue
            }
            metadataBytes += candidate.fileSize
            guard
                let data = readBoundedFile(
                    at: candidate.url,
                    under: userDataURL,
                    expectedSize: candidate.fileSize,
                    maximumBytes: min(
                        maximumSummaryLineBytes,
                        maximumMetadataBytes - (metadataBytes - candidate.fileSize)
                    )
                ),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                truncated = true
                continue
            }
            let rawID = (object["sessionId"] as? String)
                ?? candidate.url.deletingPathExtension().lastPathComponent
            let id = Self.stableSourceID(
                provider: .claude,
                rawID: rawID,
                relativePath: candidate.relativePath
            )
            let createdAt = Self.claudeDate(object["createdAt"]) ?? source.modifiedAt
            let updatedAt = Self.claudeDate(object["lastActivityAt"])
                ?? Self.claudeDate(object["lastFocusedAt"])
                ?? source.modifiedAt
            let usageResult = claudeUsageSummary(
                at: source, under: userDataURL, maximumBytes: remainingUsageBytes
            )
            let usage = usageResult.summary
            if usageResult.cacheHit { cacheHits += 1 }
            else if usage != nil { remainingUsageBytes -= Int(source.fileSize) }
            if usage == nil || usage?.isPartial == true { truncated = true }
            records.append(.init(
                id: id,
                model: Self.cleanMetadata(object["model"] as? String),
                startedAt: createdAt,
                updatedAt: max(createdAt, updatedAt),
                tokenCount: usage?.totalTokens,
                latestUsageLimit: usage?.latestUsageLimit,
                status: Self.boolValue(object["isArchived"]) ? "Archived" : "Unknown"
            ))
        }
        let bounded = boundedClaudeUserDataRecords(records)
        return .init(
            records: bounded,
            cacheHits: min(cacheHits, bounded.count),
            truncated: truncated || records.count > maximumSessions || Task.isCancelled
        )
    }

    private func claudeMetadataCandidates(userDataURL: URL) -> (candidates: [ClaudeMetadataCandidate], truncated: Bool) {
        let metadataRoot = userDataURL
            .appendingPathComponent("claude-code-sessions", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: metadataRoot,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
                .fileSizeKey, .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return ([], false)
        }
        var candidates: [ClaudeMetadataCandidate] = []
        var inspectedEntries = 0
        var truncated = false
        for case let url as URL in enumerator {
            guard !Task.isCancelled, inspectedEntries < maximumInventoryFiles else {
                truncated = true
                break
            }
            inspectedEntries += 1
            guard
                url.pathExtension == "json",
                url.deletingPathExtension().lastPathComponent.hasPrefix("local_")
            else {
                continue
            }
            guard
                let safe = canonicalRegularFile(url: url, under: metadataRoot),
                safe.fileSize >= 0
            else {
                continue
            }
            candidates.append(.init(
                url: safe.url,
                relativePath: safe.relativePath,
                fileSize: safe.fileSize,
                modifiedAt: safe.modifiedAt
            ))
        }
        return (candidates, truncated)
    }

    private func claudeAuditSourceFile(
        userDataURL: URL,
        relativeMetadataPath: String
    ) -> SourceFile? {
        let sessionDirectory = (relativeMetadataPath as NSString).deletingPathExtension
        guard
            !sessionDirectory.hasPrefix("/"),
            !sessionDirectory.split(separator: "/").contains("..")
        else {
            return nil
        }
        let auditRoot = userDataURL
            .appendingPathComponent("local-agent-mode-sessions", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let candidate = auditRoot
            .appendingPathComponent(sessionDirectory, isDirectory: true)
            .appendingPathComponent("audit.jsonl")
            .standardizedFileURL
        guard
            let safe = canonicalRegularFile(url: candidate, under: auditRoot),
            let relativePath = relativePath(for: safe.url, under: userDataURL)
        else {
            return nil
        }
        return .init(
            url: safe.url,
            relativePath: relativePath,
            fileSize: UInt64(safe.fileSize),
            modifiedAt: safe.modifiedAt
        )
    }

    private func claudeUsageSummary(
        at source: SourceFile,
        under root: URL,
        maximumBytes: Int
    ) -> (summary: ClaudeUsageSummary?, cacheHit: Bool) {
        guard let signature = fileSignature(at: source.url),
              signature.size == Int64(clamping: source.fileSize)
        else { return (nil, false) }
        if let cached = claudeUsageCache.value(for: source.url.path, signature: signature) {
            return (cached, true)
        }

        guard source.fileSize <= UInt64(maximumBytes) else { return (nil, false) }
        var totalTokens = 0
        var seenMessageRequests: Set<String> = []
        var latestUsageLimit: UsageLimitSignal?
        var unreadableUsage = false
        let usageMarker = Data(#""usage""#.utf8)
        let rateLimitMarker = Data(#""rate_limit_event""#.utf8)
        let readResult = forEachForwardLine(
            at: source.url,
            under: root,
            maximumBytes: Int(clamping: source.fileSize)
        ) { line in
            guard line.range(of: usageMarker) != nil
                || line.range(of: rateLimitMarker) != nil
            else {
                return true
            }
            guard
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let type = object["type"] as? String
            else {
                unreadableUsage = true
                return true
            }

            if type == "assistant",
               let message = object["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any]
            {
                let messageID = message["id"] as? String
                let requestID = object["requestId"] as? String
                let dedupeKey = (messageID == nil && requestID == nil)
                    ? nil
                    : "\(messageID ?? ""):\(requestID ?? "")"
                if dedupeKey.map({ seenMessageRequests.insert($0).inserted }) ?? true {
                    for key in [
                        "input_tokens", "cache_read_input_tokens",
                        "cache_creation_input_tokens", "output_tokens"
                    ] {
                        totalTokens = Self.saturatingAdd(
                            totalTokens,
                            Self.nonnegativeInt(usage[key])
                        )
                    }
                }
            }

            if type == "rate_limit_event",
               let info = object["rate_limit_info"] as? [String: Any],
               let rawStatus = info["status"] as? String,
               let status = UsageLimitSignal.Status(rawValue: rawStatus)
            {
                let observedAt = Self.date(object["_audit_timestamp"])
                    ?? Self.date(object["timestamp"])
                    ?? source.modifiedAt
                let rawUtilization = (info["utilization"] as? NSNumber)?.doubleValue
                let usedPercent = rawUtilization.flatMap { value -> Double? in
                    guard value.isFinite, value >= 0 else { return nil }
                    let percent = value <= 1 ? value * 100 : value
                    return percent <= 100 ? percent : nil
                }
                let signal = UsageLimitSignal(
                    status: status,
                    bucket: Self.cleanMetadata(info["rateLimitType"] as? String),
                    usedPercent: usedPercent,
                    resetsAt: Self.claudeDate(info["resetsAt"]),
                    observedAt: observedAt,
                    isUsingOverage: info["isUsingOverage"].map(Self.boolValue)
                )
                if latestUsageLimit == nil
                    || observedAt >= (latestUsageLimit?.observedAt ?? .distantPast)
                {
                    latestUsageLimit = signal
                }
            }
            return true
        }
        guard readResult.completed, !Task.isCancelled else { return (nil, false) }
        let unchanged = fileSignature(at: source.url) == signature
        let summary = ClaudeUsageSummary(
            totalTokens: totalTokens,
            latestUsageLimit: latestUsageLimit,
            isPartial: readResult.skippedLines > 0 || unreadableUsage || !unchanged
        )
        if unchanged {
            claudeUsageCache.store(summary, for: source.url.path, signature: signature)
        }
        return (summary, false)
    }

    private func boundedClaudeUserDataRecords(
        _ records: [ClaudeUserDataRecord]
    ) -> [ClaudeUserDataRecord] {
        let sorted = records.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.id > $1.id }
            return $0.updatedAt > $1.updatedAt
        }
        var seen: Set<String> = []
        return sorted.filter { seen.insert($0.id).inserted }
            .prefix(maximumSessions)
            .map { $0 }
    }

    private func scanClaudeCode(claudeHomeURL: URL) -> LocalChatScanResult {
        let inventory = claudeInventory(claudeHomeURL: claudeHomeURL)
        guard !Task.isCancelled else { return .init(sessions: []) }
        // History and per-session headers have independent bounded budgets.
        var remainingMetadataBytes = maximumMetadataBytes
        var metadataTruncated = false
        let sessions = inventory.records.compactMap { record -> LocalChatSession? in
            guard
                let source = claudeSourceFile(
                    claudeHomeURL: claudeHomeURL,
                    project: record.project,
                    sessionID: record.sourceSessionID
                )
            else {
                return nil
            }
            let metadata = claudeBodyMetadata(
                at: source.url,
                under: claudeHomeURL,
                maximumBytes: min(256 * 1_024, remainingMetadataBytes)
            )
            remainingMetadataBytes -= metadata.inspectedBytes
            metadataTruncated = metadataTruncated || metadata.skippedLines
                || (metadata.model == nil && source.fileSize > UInt64(metadata.inspectedBytes))
            return LocalChatSession(
                id: record.id,
                provider: .claude,
                profileID: nil,
                profileName: "Official Claude",
                model: metadata.model,
                startedAt: record.startedAt ?? source.modifiedAt,
                updatedAt: record.updatedAt ?? source.modifiedAt,
                tokenCount: nil,
                status: "Unknown"
            )
        }
        return .init(
            sessions: sessions,
            diagnostics: .init(
                cacheHitCount: inventory.cacheHit ? 1 : 0,
                parsedFileCount: inventory.inspectedBytes > 0 ? 1 : 0,
                sourceFileCount: sessions.count,
                inventoryTruncated: inventory.truncated || metadataTruncated,
                inspectedHistoryBytes: inventory.inspectedBytes
            )
        )
    }

    private func claudeInventory(claudeHomeURL: URL) -> ClaudeInventory {
        let home = claudeHomeURL.resolvingSymlinksInPath().standardizedFileURL
        let historyURL = home.appendingPathComponent("history.jsonl")
        guard let handle = openNoFollowRegularFile(at: historyURL, under: home) else {
            return .init(records: [])
        }
        defer { try? handle.close() }
        guard let signature = fileSignature(handle) else {
            return .init(records: [], truncated: true)
        }
        let cacheKey = historyURL.path
        if var cached = claudeHistoryCache.value(for: cacheKey, signature: signature) {
            cached.cacheHit = true
            cached.inspectedBytes = 0
            return cached
        }

        let size = UInt64(signature.size)
        let start = size > UInt64(maximumMetadataBytes) ? size - UInt64(maximumMetadataBytes) : 0
        guard let window = readRange(handle: handle, start: start, end: size),
              window.count == Int(size - start)
        else { return .init(records: [], truncated: true) }
        // Drop the first boundary fragment and visit newest complete records first.
        let first = start == 0 ? 0 : window.firstIndex(of: 0x0A).map { $0 + 1 } ?? window.count
        var end = window.count
        var recordsByID: [String: ClaudeHistoryRecord] = [:]
        var inspectedRecords = 0
        var truncated = start > 0
        while end > first, !Task.isCancelled {
            if window[end - 1] == 0x0A { end -= 1 }
            guard end > first else { break }
            let begin = window[first..<end].lastIndex(of: 0x0A).map { $0 + 1 } ?? first
            guard inspectedRecords < maximumInventoryFiles else { truncated = true; break }
            inspectedRecords += 1
            let lineSize = end - begin
            defer { end = begin }
            guard lineSize <= maximumSummaryLineBytes else { truncated = true; continue }
            let line = window.subdata(in: begin..<end)
            guard
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let rawSessionID = object["sessionId"] as? String,
                Self.safeFilename(rawSessionID),
                let project = object["project"] as? String,
                !project.isEmpty, project.utf8.count <= 4_096
            else { truncated = true; continue }
            let relativeSource = "projects/\(project.replacingOccurrences(of: "/", with: "-"))/\(rawSessionID).jsonl"
            let sessionID = Self.stableSourceID(provider: .claude, rawID: rawSessionID, relativePath: relativeSource)
            let timestamp = Self.claudeDate(object["timestamp"])
            if var existing = recordsByID[sessionID] {
                if let timestamp {
                    existing.startedAt = existing.startedAt.map { min($0, timestamp) } ?? timestamp
                    existing.updatedAt = existing.updatedAt.map { max($0, timestamp) } ?? timestamp
                }
                recordsByID[sessionID] = existing
            } else {
                guard recordsByID.count < maximumSessions else { truncated = true; continue }
                recordsByID[sessionID] = .init(
                    id: sessionID, sourceSessionID: rawSessionID, project: project,
                    startedAt: timestamp, updatedAt: timestamp
                )
            }
        }
        let records = recordsByID.values.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.id > $1.id }
            return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }
        let result = ClaudeInventory(
            records: records,
            truncated: truncated || Task.isCancelled,
            inspectedBytes: window.count
        )
        // Never cache a result while a writer changed the descriptor during the read.
        let unchanged = fileSignature(handle) == signature
        if !Task.isCancelled, unchanged {
            claudeHistoryCache.store(result, for: cacheKey, signature: signature)
        }
        var returned = result
        if !unchanged { returned.truncated = true }
        return returned
    }

    private func fileSignature(_ handle: FileHandle) -> LocalFileSignature? {
        var status = Darwin.stat()
        guard Darwin.fstat(handle.fileDescriptor, &status) == 0 else { return nil }
        return fileSignature(status)
    }

    private func fileSignature(at url: URL) -> LocalFileSignature? {
        var status = Darwin.stat()
        guard Darwin.lstat(url.path, &status) == 0 else { return nil }
        return fileSignature(status)
    }

    private func fileSignature(_ status: Darwin.stat) -> LocalFileSignature? {
        guard status.st_mode & S_IFMT == S_IFREG, status.st_size >= 0 else { return nil }
        return .init(
            device: UInt64(bitPattern: Int64(status.st_dev)), inode: status.st_ino, size: status.st_size,
            modifiedSeconds: status.st_mtimespec.tv_sec, modifiedNanoseconds: status.st_mtimespec.tv_nsec,
            changedSeconds: status.st_ctimespec.tv_sec, changedNanoseconds: status.st_ctimespec.tv_nsec
        )
    }

    private func claudeSourceFile(
        claudeHomeURL: URL,
        project: String,
        sessionID: String
    ) -> SourceFile? {
        guard
            Self.safeFilename(sessionID),
            !project.isEmpty
        else {
            return nil
        }
        let projectsRoot = claudeHomeURL
            .appendingPathComponent("projects", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let projectDirectoryName = project.replacingOccurrences(of: "/", with: "-")
        let candidate = projectsRoot
            .appendingPathComponent(projectDirectoryName, isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
            .standardizedFileURL
        guard
            let safe = canonicalRegularFile(url: candidate, under: projectsRoot),
            let relativePath = relativePath(for: safe.url, under: claudeHomeURL)
        else {
            return nil
        }
        return .init(
            url: safe.url,
            relativePath: relativePath,
            fileSize: UInt64(safe.fileSize),
            modifiedAt: safe.modifiedAt
        )
    }

    private func claudeBodyMetadata(
        at url: URL,
        under root: URL,
        maximumBytes: Int
    ) -> ClaudeBodyMetadata {
        guard maximumBytes > 0 else { return .init() }
        var metadata = ClaudeBodyMetadata()
        var inspectedBytes = 0
        let readResult = forEachForwardLine(
            at: url,
            under: root,
            maximumBytes: maximumBytes
        ) { line in
            inspectedBytes += line.count
            guard
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else {
                return inspectedBytes < 256 * 1_024
            }
            if
                let message = object["message"] as? [String: Any],
                let model = message["model"] as? String
            {
                metadata.model = Self.cleanMetadata(model)
            }
            return inspectedBytes < 256 * 1_024 && metadata.model == nil
        }
        metadata.inspectedBytes = readResult.bytesRead
        metadata.skippedLines = readResult.skippedLines > 0 || !readResult.completed
        return metadata
    }

    private func forEachForwardLine(
        at url: URL,
        under root: URL? = nil,
        maximumBytes: Int? = nil,
        body: (Data) -> Bool
    ) -> (completed: Bool, bytesRead: Int, skippedLines: Int) {
        guard maximumBytes.map({ $0 > 0 }) ?? true,
              let handle = openNoFollowRegularFile(at: url, under: root)
        else { return (false, 0, 0) }
        defer { try? handle.close() }
        var buffer = Data()
        var discardingOversized = false
        var bytesRead = 0
        var skippedLines = 0
        while !Task.isCancelled {
            let remaining = maximumBytes.map { $0 - bytesRead }
            guard remaining.map({ $0 > 0 }) ?? true else {
                if !discardingOversized, !buffer.isEmpty { _ = body(buffer) }
                return (true, bytesRead, skippedLines)
            }
            let count = min(64 * 1_024, remaining ?? (64 * 1_024))
            guard let chunk = try? handle.read(upToCount: count), !chunk.isEmpty else {
                if !discardingOversized, !buffer.isEmpty { _ = body(buffer) }
                return (true, bytesRead, skippedLines)
            }
            bytesRead += chunk.count
            var cursor = chunk.startIndex
            if discardingOversized {
                guard let newline = chunk.firstIndex(of: 0x0A) else { continue }
                cursor = chunk.index(after: newline)
                discardingOversized = false
            }
            while cursor < chunk.endIndex {
                if let newline = chunk[cursor...].firstIndex(of: 0x0A) {
                    let lineBytes = chunk.distance(from: cursor, to: newline)
                    if lineBytes <= maximumSummaryLineBytes - buffer.count {
                        buffer.append(chunk[cursor..<newline])
                        if !buffer.isEmpty, !body(buffer) { return (true, bytesRead, skippedLines) }
                    } else {
                        skippedLines += 1
                    }
                    buffer.removeAll(keepingCapacity: true)
                    cursor = chunk.index(after: newline)
                } else {
                    buffer.append(chunk[cursor...])
                    if buffer.count > maximumSummaryLineBytes {
                        buffer.removeAll(keepingCapacity: true)
                        discardingOversized = true
                        skippedLines += 1
                    }
                    break
                }
            }
        }
        return (false, bytesRead, skippedLines)
    }

    private func readRange(handle: FileHandle, start: UInt64, end: UInt64) -> Data? {
        guard end >= start, !Task.isCancelled else { return nil }
        do {
            try handle.seek(toOffset: start)
            return try handle.read(upToCount: Int(end - start)) ?? Data()
        } catch {
            return nil
        }
    }

    private func readBoundedFile(
        at url: URL,
        under root: URL,
        expectedSize: Int,
        maximumBytes: Int
    ) -> Data? {
        guard
            expectedSize >= 0,
            expectedSize <= maximumBytes,
            !Task.isCancelled,
            let handle = openNoFollowRegularFile(at: url, under: root)
        else {
            return nil
        }
        defer { try? handle.close() }
        guard
            let data = try? handle.read(upToCount: expectedSize + 1),
            data.count == expectedSize
        else {
            return nil
        }
        return data
    }

    private func openNoFollowRegularFile(at url: URL, under root: URL? = nil) -> FileHandle? {
        if let root, canonicalRegularFile(url: url, under: root) == nil {
            return nil
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var descriptorStatus = Darwin.stat()
        var pathStatus = Darwin.stat()
        guard
            Darwin.fstat(descriptor, &descriptorStatus) == 0,
            Darwin.lstat(url.path, &pathStatus) == 0,
            descriptorStatus.st_mode & S_IFMT == S_IFREG,
            pathStatus.st_mode & S_IFMT == S_IFREG,
            descriptorStatus.st_dev == pathStatus.st_dev,
            descriptorStatus.st_ino == pathStatus.st_ino,
            root.map({ canonicalRegularFile(url: url, under: $0) != nil }) ?? true
        else {
            Darwin.close(descriptor)
            return nil
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func canonicalRegularFile(
        url: URL,
        under root: URL
    ) -> CanonicalRegularFile? {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let standardized = url.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
        guard
            standardized.path == resolved.path,
            let relativePath = relativePath(for: resolved, under: canonicalRoot),
            !relativePath.isEmpty,
            let values = try? standardized.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
                .fileSizeKey, .contentModificationDateKey
            ]),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let fileSize = values.fileSize,
            fileSize >= 0
        else {
            return nil
        }
        return .init(
            url: resolved,
            relativePath: relativePath,
            fileSize: fileSize,
            modifiedAt: values.contentModificationDate ?? .distantPast
        )
    }

    private func relativePath(for url: URL, under root: URL) -> String? {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(base) else { return nil }
        return String(path.dropFirst(base.count))
    }

    private func indexURL(scopeKey: String) -> URL {
        indexRootURL.appendingPathComponent("\(scopeKey)-v2.json")
    }

    private struct ClaudeInventory {
        let records: [ClaudeHistoryRecord]
        var truncated = false
        var inspectedBytes = 0
        var cacheHit = false
    }

    private final class ClaudeHistoryCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (LocalFileSignature, ClaudeInventory)] = [:]

        func value(for path: String, signature: LocalFileSignature) -> ClaudeInventory? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[path], entry.0 == signature else { return nil }
            return entry.1
        }

        func store(_ inventory: ClaudeInventory, for path: String, signature: LocalFileSignature) {
            lock.lock()
            defer { lock.unlock() }
            if entries.count >= 4, entries[path] == nil, let key = entries.keys.sorted().first {
                entries.removeValue(forKey: key)
            }
            entries[path] = (signature, inventory)
        }
    }

    private struct ClaudeUserDataInventory {
        let records: [ClaudeUserDataRecord]
        let cacheHits: Int
        let truncated: Bool
    }

    private struct ClaudeUserDataRecord {
        let id: String
        let model: String?
        let startedAt: Date
        let updatedAt: Date
        let tokenCount: Int?
        let latestUsageLimit: UsageLimitSignal?
        let status: String
    }

    private struct ClaudeHistoryRecord {
        let id: String
        let sourceSessionID: String
        var project: String
        var startedAt: Date?
        var updatedAt: Date?
    }

    private struct ClaudeMetadataCandidate {
        let url: URL
        let relativePath: String
        let fileSize: Int
        let modifiedAt: Date
    }

    private struct CanonicalRegularFile {
        let url: URL
        let relativePath: String
        let fileSize: Int
        let modifiedAt: Date
    }

    private struct ClaudeBodyMetadata {
        var model: String?
        var inspectedBytes = 0
        var skippedLines = false
    }

    private struct SourceFile {
        let url: URL
        let relativePath: String
        let fileSize: UInt64
        let modifiedAt: Date
    }

    private static func date(_ raw: Any?) -> Date? {
        guard let value = raw as? String else { return nil }
        if let date = try? Date(
            value,
            strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        ) {
            return date
        }
        return try? Date(value, strategy: Date.ISO8601FormatStyle())
    }

    private static func claudeDate(_ raw: Any?) -> Date? {
        if let date = date(raw) { return date }
        guard let number = raw as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1_000 : value)
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if raw is NSNull { return nil }
        if let number = raw as? NSNumber { return number.intValue }
        if let string = raw as? String { return Int(string) }
        return nil
    }

    private static func nonnegativeInt(_ raw: Any?) -> Int {
        guard !(raw is Bool), let value = intValue(raw), value > 0 else { return 0 }
        return value
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    private static func boolValue(_ raw: Any?) -> Bool {
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber { return number.intValue != 0 }
        if let string = raw as? String { return string == "1" || string.lowercased() == "true" }
        return false
    }

    private static func cleanTranscriptText(_ raw: String) -> String {
        var text = raw
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !home.isEmpty { text = text.replacingOccurrences(of: home, with: "~") }
        text = text.replacingOccurrences(
            of: #"(?<![:A-Za-z0-9])/(?:[A-Za-z0-9._-]+/)+([A-Za-z0-9._-]+)"#,
            with: "…/$1",
            options: .regularExpression
        )
        for pattern in [
            #"\bsk-[A-Za-z0-9_-]{12,}\b"#,
            #"\b(?:ghp_|github_pat_|xox[baprs]-)[A-Za-z0-9_-]{12,}\b"#,
            #"\bgAAAAA[A-Za-z0-9_-]{40,}\b"#,
            #"(?i)\b(api[_-]?key|access[_-]?token|password|secret)\s*[:=]\s*[^\s,;]+"#
        ] {
            text = text.replacingOccurrences(
                of: pattern,
                with: "[redacted]",
                options: .regularExpression
            )
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanMetadata(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = cleanTranscriptText(value)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(256))
    }

    private static func cleanIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let allowed = value.unicodeScalars.filter {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
        }
        let cleaned = String(String.UnicodeScalarView(allowed)).prefix(128)
        return cleaned.isEmpty ? nil : String(cleaned)
    }

    private static func unchangedValidIdentifier(_ value: String?) -> String? {
        guard
            let value,
            value.count <= 128,
            cleanIdentifier(value) == value
        else {
            return nil
        }
        return value
    }

    private static func stableSourceID(
        provider: DesktopProduct,
        rawID: String?,
        relativePath: String
    ) -> String {
        if let valid = unchangedValidIdentifier(rawID) { return valid }
        let namespace = "\(provider.rawValue)|\(relativePath)|\(rawID ?? "")"
        return "\(provider.rawValue)-local-\(String(fnv1a64(namespace), radix: 16))"
    }

    private static func safeFilename(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 255
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\0")
    }

    private static func fnv1a64(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
    }
}
