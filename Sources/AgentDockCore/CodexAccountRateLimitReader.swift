import Darwin
import Foundation

/// Shares bounded account reads between quota display and reset inventory.
/// Cached data is at most a minute old; it never authorizes launch or other actions.
public actor CodexAccountRateLimitReader {
    public static let shared = CodexAccountRateLimitReader()

    private struct Key: Hashable, Sendable {
        let home: URL
        let app: URL
        let metadata: [String]
    }
    private let client: AppServerRateLimitClient
    public struct Counts: Sendable, Equatable {
        public var requests = 0
        public var cacheHits = 0
        public var validationBatches = 0
        public var accountReads = 0
    }
    public private(set) var counts = Counts()
    private var cached: [Key: ProfileRateLimits] = [:]
    private var waiters: [Key: [UUID: CheckedContinuation<ProfileRateLimits, Never>]] = [:]
    private var queued: Set<Key> = []
    private var working: Set<Key> = []
    private var worker: Task<Void, Never>?
    private var dispatchTask: Task<Void, Never>?

    public init(client: AppServerRateLimitClient = AppServerRateLimitClient()) {
        self.client = client
    }

    public func fetch(codexHomeURL: URL, codexAppURL: URL) async -> ProfileRateLimits {
        guard !Task.isCancelled else { return Self.cancelled }
        counts.requests += 1
        let key = Self.key(home: codexHomeURL, app: codexAppURL)
        if let value = cached[key], Date().timeIntervalSince(value.fetchedAt) < 60 {
            counts.cacheHits += 1
            return value
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[key, default: [:]][id] = continuation
                if !working.contains(key) || worker?.isCancelled == true { queued.insert(key) }
                scheduleDispatch()
            }
        } onCancel: {
            Task { await self.cancel(key: key, id: id) }
        }
    }

    private func scheduleDispatch() {
        guard worker == nil, dispatchTask == nil, !queued.isEmpty else { return }
        dispatchTask = Task { [weak self] in
            // Gather simultaneous Home and inventory requests into one validation batch.
            try? await Task.sleep(for: .milliseconds(30))
            await self?.dispatch()
        }
    }

    private func dispatch() {
        dispatchTask = nil
        guard worker == nil, let first = queued.first else { return }
        let keys = Set(queued.filter { $0.app == first.app }.sorted { $0.home.path < $1.home.path }.prefix(4))
        counts.validationBatches += 1
        counts.accountReads += keys.count
        queued.subtract(keys)
        working = keys
        let client = client
        worker = Task {
            let read = Task.detached(priority: .utility) {
                client.fetchRateLimitsBatch(codexHomeURLs: keys.map(\.home), codexAppURL: first.app)
            }
            let results = await withTaskCancellationHandler { await read.value } onCancel: { read.cancel() }
            finish(keys: keys, results: Task.isCancelled ? [:] : results, cancelled: Task.isCancelled)
        }
    }

    private func finish(keys: Set<Key>, results: [URL: ProfileRateLimits], cancelled: Bool) {
        for key in keys {
            // A new subscriber can arrive after all previous subscribers cancel.
            // Keep that subscriber queued for a new worker, rather than giving it
            // the cancelled worker's result.
            if cancelled, queued.contains(key) { continue }
            let value = results[key.home] ?? Self.cancelled
            let current = Self.key(home: key.home, app: key.app)
            // An account or installation changed during the read. Do not cache or publish it.
            let unchanged = current == key
            let delivered = unchanged ? value : ProfileRateLimits(errorMessage: "The account or app changed during the refresh. Refresh again.")
            if unchanged, value.errorMessage == nil { cached[key] = value }
            for continuation in waiters.removeValue(forKey: key)?.values ?? [:].values {
                continuation.resume(returning: delivered)
            }
        }
        cached = cached.filter { Date().timeIntervalSince($0.value.fetchedAt) < 60 }
        while cached.count > 256, let oldest = cached.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key {
            cached.removeValue(forKey: oldest)
        }
        working.removeAll()
        worker = nil
        scheduleDispatch()
    }

    private func cancel(key: Key, id: UUID) {
        waiters[key]?.removeValue(forKey: id)?.resume(returning: Self.cancelled)
        if waiters[key]?.isEmpty == true {
            waiters.removeValue(forKey: key)
            queued.remove(key)
        }
        if !working.isEmpty, working.allSatisfy({ waiters[$0] == nil }) { worker?.cancel() }
    }

    private static var cancelled: ProfileRateLimits {
        ProfileRateLimits(errorMessage: "Usage-limit refresh was cancelled.")
    }

    private static func key(home: URL, app: URL) -> Key {
        let home = home.standardizedFileURL
        let app = app.standardizedFileURL
        let paths = [home, home.appendingPathComponent("auth.json"), home.appendingPathComponent("config.toml"),
            app, app.appendingPathComponent("Contents/_CodeSignature/CodeResources"),
            app.appendingPathComponent("Contents/Resources/app.asar"), app.appendingPathComponent("Contents/MacOS/Codex"),
            CodexBundledCLI.executableURL(for: app)]
        // Metadata only invalidates a cached answer. Full signature validation still runs
        // before every new batch; metadata is never proof of executable trust.
        let metadata = paths.map { url -> String in
            var value = stat()
            guard lstat(url.path, &value) == 0 else { return "missing:\(errno)" }
            if (value.st_mode & S_IFMT) == S_IFDIR {
                return "\(value.st_dev):\(value.st_ino):\(value.st_mode)"
            }
            return "\(value.st_dev):\(value.st_ino):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
        }
        return Key(home: home, app: app, metadata: metadata)
    }
}
