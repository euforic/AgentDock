import Foundation
import XCTest
@testable import CodexerCore

final class CodexAccountRateLimitReaderTests: XCTestCase {
    func testConcurrentReadsShareValidationAndKeepDistinctHomes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First")
        let second = root.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let reader = CodexAccountRateLimitReader()
        let app = root.appendingPathComponent("Missing.app")
        let results = await withTaskGroup(of: ProfileRateLimits.self) { group in
            for home in [first, first, second, second] {
                group.addTask { await reader.fetch(codexHomeURL: home, codexAppURL: app) }
            }
            var values: [ProfileRateLimits] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.count, 4)
        XCTAssertTrue(results.allSatisfy { $0.errorMessage != nil })
        let counts = await reader.counts
        XCTAssertEqual(counts.requests, 4)
        XCTAssertEqual(counts.validationBatches, 1)
        XCTAssertEqual(counts.accountReads, 2)
        XCTAssertEqual(counts.cacheHits, 0)
    }

    func testCancellationDoesNotStartARead() async {
        let reader = CodexAccountRateLimitReader()
        let task = Task {
            try? await Task.sleep(for: .seconds(1))
            return await reader.fetch(codexHomeURL: URL(fileURLWithPath: "/tmp/missing-home"),
                codexAppURL: URL(fileURLWithPath: "/tmp/missing-provider.app"))
        }
        task.cancel()
        let result = await task.value
        XCTAssertNotNil(result.errorMessage)
        let counts = await reader.counts
        XCTAssertEqual(counts.requests, 0)
    }

    func testInstalledSharedAccountReadAndSuccessfulCache() async throws {
        guard ProcessInfo.processInfo.environment["AGENTDOCK_BENCHMARK_LIVE_QUOTA"] == "1" else {
            throw XCTSkip("Signed-in native quota reads are opt in.")
        }
        let reader = CodexAccountRateLimitReader()
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let app = URL(fileURLWithPath: "/Applications/Codex.app")
        async let display = reader.fetch(codexHomeURL: home, codexAppURL: app)
        async let inventory = reader.fetch(codexHomeURL: home, codexAppURL: app)
        let (first, second) = await (display, inventory)
        XCTAssertNil(first.errorMessage)
        XCTAssertEqual(first, second)
        let cached = await reader.fetch(codexHomeURL: home, codexAppURL: app)
        XCTAssertEqual(first, cached)
        let counts = await reader.counts
        XCTAssertEqual(counts.accountReads, 1)
        XCTAssertEqual(counts.validationBatches, 1)
        XCTAssertEqual(counts.cacheHits, 1)
        // A different selected installation cannot reuse the signed app's answer.
        let missing = await reader.fetch(codexHomeURL: home, codexAppURL: app.appendingPathComponent("Missing.app"))
        XCTAssertNotNil(missing.errorMessage)
    }

    func testCancellingOneInstalledReadSubscriberPreservesTheOther() async throws {
        guard ProcessInfo.processInfo.environment["AGENTDOCK_INSTALLED_APP_TEST"] == "1" else {
            throw XCTSkip("Installed signed-app account read is opt in.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = CodexAccountRateLimitReader()
        let app = URL(fileURLWithPath: "/Applications/Codex.app")
        let first = Task { await reader.fetch(codexHomeURL: root, codexAppURL: app) }
        let second = Task { await reader.fetch(codexHomeURL: root, codexAppURL: app) }
        let deadline = Date().addingTimeInterval(2)
        while await reader.counts.validationBatches == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        first.cancel()
        _ = await first.value
        let result = await second.value
        XCTAssertFalse(result.errorMessage?.contains("cancelled") == true)
        let counts = await reader.counts
        XCTAssertEqual(counts.validationBatches, 1)
        XCTAssertEqual(counts.accountReads, 1)
    }

    func testBatchRejectsRealUnsignedProviderForEveryHome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let homes = [root.appendingPathComponent("a"), root.appendingPathComponent("b")]
        let results = AppServerRateLimitClient().fetchRateLimitsBatch(codexHomeURLs: homes,
            codexAppURL: root)
        XCTAssertEqual(Set(results.keys), Set(homes))
        XCTAssertTrue(results.values.allSatisfy { $0.errorMessage != nil })
    }
}
