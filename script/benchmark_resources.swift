import AppKit
import Darwin
import Foundation

// Compiled alongside unmodified production readers; the runner only adds counters
// at successful process launches and validator entry in temporary source copies.
enum ResourceBenchmarkCounters {
    static let lock = NSLock()
    nonisolated(unsafe) static var processes: [String: Int] = [:]
    nonisolated(unsafe) static var validations = 0
    static func launched(_ name: String) { lock.lock(); defer { lock.unlock() }; processes[name, default: 0] += 1 }
    static func validated() { lock.lock(); defer { lock.unlock() }; validations += 1 }
    static func reset() { lock.lock(); defer { lock.unlock() }; processes = [:]; validations = 0 }
}

func usage() -> rusage_info_v4 {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    precondition(result == 0, "Native process resource counters unavailable")
    return info
}

func measure(_ name: String, operation: () async throws -> [String: Any]) async rethrows {
    ResourceBenchmarkCounters.reset()
    let before = usage(), start = Date()
    let detail = try await operation()
    let elapsed = Date().timeIntervalSince(start), after = usage()
    var timebase = mach_timebase_info_data_t()
    precondition(mach_timebase_info(&timebase) == KERN_SUCCESS)
    let cpuScale = Double(timebase.numer) / Double(timebase.denom) / 1e9
    var result = detail
    result.merge([
        "scenario": name, "wall_seconds": elapsed,
        "cpu_seconds": Double(after.ri_user_time + after.ri_system_time - before.ri_user_time - before.ri_system_time) * cpuScale,
        "cpu_timebase_numer": timebase.numer, "cpu_timebase_denom": timebase.denom,
        "child_cpu_seconds": Double(after.ri_child_user_time + after.ri_child_system_time - before.ri_child_user_time - before.ri_child_system_time) * cpuScale,
        "physical_footprint_bytes": after.ri_phys_footprint,
        "interrupt_wakeups": after.ri_interrupt_wkups - before.ri_interrupt_wkups,
        "package_idle_wakeups": after.ri_pkg_idle_wkups - before.ri_pkg_idle_wkups,
        "disk_read_bytes": after.ri_diskio_bytesread - before.ri_diskio_bytesread,
        "disk_write_bytes": after.ri_diskio_byteswritten - before.ri_diskio_byteswritten,
        "child_launches": ResourceBenchmarkCounters.processes,
        "validation_calls": ResourceBenchmarkCounters.validations
    ]) { _, new in new }
    let json = try! JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
    print(String(decoding: json, as: UTF8.self))
}

@main struct Benchmark {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ResourceBenchmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let code = root.appendingPathComponent("Code")
        let desktop = root.appendingPathComponent("Desktop")
        let source = code.appendingPathComponent("projects/-synthetic/synthetic-session.jsonl")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        try Data("{\"type\":\"assistant\",\"message\":{\"model\":\"synthetic-model\"}}\n".utf8).write(to: source)
        let line = try JSONSerialization.data(withJSONObject: ["sessionId":"synthetic-session", "project":"/synthetic",
            "display":String(repeating: "x", count: 1024), "timestamp":1700000000000]) + Data([10])
        let history = code.appendingPathComponent("history.jsonl")
        for bytes in [8 * 1024 * 1024, 20 * 1024 * 1024] {
            var data = Data()
            while data.count < bytes { data.append(line) }
            try data.write(to: history)
            let scanner = ProfileStatsScanner()
            for iteration in 0..<3 {
                await measure("history-\(bytes / 1024 / 1024)MiB-\(iteration == 0 ? "cold" : "warm")") {
                    let stats = scanner.stats(claudeUserDataURL: desktop, claudeCodeHomeURL: code, dataRootURL: desktop)
                    return ["sessions": stats.totalSessions, "partial_messages": stats.errorMessages.count]
                }
            }
        }
        let storage = root.appendingPathComponent("Storage")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        for i in 0..<10000 { try Data(repeating: 1, count: 128).write(to: storage.appendingPathComponent("file-\(i)")) }
        let scanner = ProfileStatsScanner(), now = Date()
        for offset in [0, 120, 300] {
            await measure("storage-10000-files-\(offset)s") {
                let stats = scanner.stats(codexHomeURL: root.appendingPathComponent("Empty"), dataRootURL: storage, now: now.addingTimeInterval(Double(offset)))
                return ["bytes": stats.dataBytes, "truncated": stats.dataSizeIsTruncated]
            }
        }
        let databaseHome = root.appendingPathComponent("Databases")
        try FileManager.default.createDirectory(at: databaseHome, withIntermediateDirectories: true)
        let timestamp = Int(Date().timeIntervalSince1970)
        for (name, sql) in [
            ("state_5.sqlite", "CREATE TABLE threads(id TEXT,tokens_used INTEGER,updated_at INTEGER,archived INTEGER); WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<50000) INSERT INTO threads SELECT 'session-'||i,i,\(timestamp),0 FROM n; CREATE TABLE agent_jobs(status TEXT); INSERT INTO agent_jobs VALUES('complete');"),
            ("logs_2.sqlite", "CREATE TABLE logs(ts INTEGER,level TEXT); WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<2000000) INSERT INTO logs SELECT \(timestamp)-i,CASE WHEN i%100=0 THEN 'ERROR' ELSE 'INFO' END FROM n;")
        ] {
            let created = try BoundedSubprocess.run(executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
                arguments: [databaseHome.appendingPathComponent(name).path, sql], timeout: 30, maximumOutputBytes: 1024)
            precondition(created.terminationStatus == 0, "Synthetic database creation failed")
        }
        let databaseScanner = ProfileStatsScanner()
        for iteration in 0..<3 {
            await measure("sqlite-50000-sessions-2M-logs-\(iteration)") {
                let stats = databaseScanner.stats(codexHomeURL: databaseHome, dataRootURL: databaseHome)
                return ["sessions": stats.totalSessions, "query_errors": stats.errorMessages.count]
            }
        }
        let profiles = DesktopProduct.allCases.map { product in
            CodexProfile(product: product, name: "Synthetic", slug: "synthetic-\(product.rawValue)",
                profileDirectory: root.appendingPathComponent(product.rawValue), shortcutDirectory: root.appendingPathComponent("Shortcuts"))
        }
        let controller = DesktopInstanceController()
        let apps: [DesktopProduct: URL] = [.codex: URL(fileURLWithPath: "/Applications/Codex.app"), .claude: URL(fileURLWithPath: "/Applications/Claude.app")]
        for iteration in 0..<3 {
            await measure("installed-status-\(iteration)") {
                #if CANDIDATE
                let result = await controller.statusBatch(for: profiles, appURLs: apps)
                return ["managed_results": result.managedStatuses.count, "official_results": result.officialStatuses.count]
                #else
                let managed = (try? await controller.statuses(for: profiles, appURLs: apps)) ?? [:]
                var official = 0
                for (product, app) in apps { if (try? await controller.stockStatus(product: product, appURL: app)) != nil { official += 1 } }
                return ["managed_results": managed.count, "official_results": official]
                #endif
            }
        }
        // Opt in to read signed-in limits; only booleans and resource counters leave memory.
        if ProcessInfo.processInfo.environment["AGENTDOCK_BENCHMARK_LIVE_QUOTA"] == "1" {
            let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            let app = apps[.codex]!
            await measure("live-quota-display-and-inventory") {
                #if CANDIDATE
                let reader = CodexAccountRateLimitReader()
                async let display = reader.fetch(codexHomeURL: home, codexAppURL: app)
                async let inventory = reader.fetch(codexHomeURL: home, codexAppURL: app)
                let values = await [display, inventory]
                let counts = await reader.counts
                return ["successful_reads": values.filter { $0.errorMessage == nil }.count,
                    "coalesced_batches": counts.validationBatches, "account_reads": counts.accountReads]
                #else
                let client = AppServerRateLimitClient()
                let values = [client.fetchRateLimits(codexHomeURL: home, codexAppURL: app),
                    client.fetchRateLimits(codexHomeURL: home, codexAppURL: app, includeAccountDetails: true)]
                return ["successful_reads": values.filter { $0.errorMessage == nil }.count]
                #endif
            }
        }
        await measure("missing-provider-status") {
            let missing = [DesktopProduct.codex: root.appendingPathComponent("Missing.app"), .claude: root.appendingPathComponent("Missing.app")]
            #if CANDIDATE
            _ = await controller.statusBatch(for: profiles, appURLs: missing)
            #else
            _ = try? await controller.statuses(for: profiles, appURLs: missing)
            for (product, app) in missing { _ = try? await controller.stockStatus(product: product, appURL: app) }
            #endif
            return [:]
        }
    }
}
