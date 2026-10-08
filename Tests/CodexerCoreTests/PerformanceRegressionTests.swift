import XCTest
@testable import CodexerCore

final class PerformanceRegressionTests: XCTestCase {
    func testIsolatedInstanceDiscoveryPerformance() {
        let root = URL(fileURLWithPath: "/tmp/Codexer Performance")
        let appURL = URL(fileURLWithPath: "/Applications/Codex.app")
        let configurations = (0..<1_000).map { index in
            IsolatedCodexLaunchConfiguration(
                profile: CodexProfile(
                name: "Profile \(index)",
                slug: "profile-\(index)",
                rootDirectory: root
                ),
                codexAppURL: appURL
            )
        }
        let snapshot = configurations.enumerated().map { index, configuration in
            "\(index + 1000) \(configuration.appExecutableURL.path) --user-data-dir=\(configuration.electronUserDataPath)"
        }
        .joined(separator: "\n")

        let clock = ContinuousClock()
        let start = clock.now
        let baselineMatches = CodexInstanceDiscovery.processIDsByUserDataPath(
            in: snapshot,
            appExecutableURL: configurations[0].appExecutableURL
        )
        let elapsed = start.duration(to: clock.now)
        XCTAssertEqual(baselineMatches.count, configurations.count)
        XCTAssertLessThan(elapsed, .seconds(1))

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let processIDsByPath = CodexInstanceDiscovery.processIDsByUserDataPath(
                in: snapshot,
                appExecutableURL: configurations[0].appExecutableURL
            )
            let matches = configurations.map {
                processIDsByPath[$0.electronUserDataPath] ?? []
            }
            XCTAssertEqual(matches.count, configurations.count)
            XCTAssertTrue(matches.allSatisfy { $0.count == 1 })
        }
    }

    func testLargeProfileStoreLoadStaysWithinBudget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexerStorePerformance-\(UUID().uuidString)")
        let shortcutRoot = root.appendingPathComponent("Shortcuts")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: shortcutRoot, withIntermediateDirectories: true)

        let profiles = try (0..<250).map { index -> CodexProfile in
            let profile = CodexProfile(
                name: "Profile \(index)",
                slug: "profile-\(index)",
                rootDirectory: root,
                shortcutDirectory: shortcutRoot
            )
            try FileManager.default.createDirectory(
                at: profile.codexHomePath,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: profile.electronUserDataPath,
                withIntermediateDirectories: true
            )
            let marker = ["profileID": profile.id.uuidString, "slug": profile.slug]
            try JSONSerialization.data(withJSONObject: marker).write(
                to: profile.profileDirectory.appendingPathComponent(".codexer-profile.json")
            )
            return profile
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(profiles).write(to: root.appendingPathComponent("profiles.json"))

        let clock = ContinuousClock()
        let start = clock.now
        let store = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: shortcutRoot,
            usageChecker: PerformanceNeverInUseChecker()
        )
        let elapsed = start.duration(to: clock.now)

        XCTAssertEqual(store.profiles.count, 250)
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    func testChatIndexAndFirstTranscriptPageStayWithinBudgets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatIndexPerformance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = CodexProfile(
            name: "Performance",
            slug: "performance",
            rootDirectory: root,
            shortcutDirectory: root.appendingPathComponent("Shortcuts")
        )
        let sessions = profile.codexHomePath.appendingPathComponent(
            "sessions/2026/07/28",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        for index in 0..<500 {
            let record = """
            {"timestamp":"2026-07-28T10:00:00Z","type":"session_meta","payload":{"id":"performance-\(index)","timestamp":"2026-07-28T10:00:00Z"}}
            {"timestamp":"2026-07-28T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Performance conversation \(index)"}]}}
            {"timestamp":"2026-07-28T10:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"A bounded response with `inline code` and a list.\\n\\n- one\\n- two"}]}}
            """
            try Data(record.utf8).write(
                to: sessions.appendingPathComponent("rollout-\(index).jsonl")
            )
        }
        let scanner = LocalChatScanner(
            maximumSessions: 500,
            indexRootURL: root.appendingPathComponent("Indexes")
        )
        let clock = ContinuousClock()

        let coldStart = clock.now
        let cold = scanner.scan(profile: profile)
        let coldElapsed = coldStart.duration(to: clock.now)
        let warmStart = clock.now
        let warm = scanner.scan(profile: profile)
        let warmElapsed = warmStart.duration(to: clock.now)
        let pageStart = clock.now
        let page = scanner.loadTranscriptPage(for: try XCTUnwrap(warm.sessions.first))
        let pageElapsed = pageStart.duration(to: clock.now)

        XCTAssertEqual(cold.sessions.count, 500)
        XCTAssertEqual(warm.diagnostics.cacheHitCount, 500)
        XCTAssertEqual(warm.diagnostics.parsedFileCount, 0)
        XCTAssertFalse(page.entries.isEmpty)
        XCTAssertLessThan(coldElapsed, .seconds(2))
        XCTAssertLessThan(warmElapsed, .milliseconds(500))
        XCTAssertLessThan(pageElapsed, .milliseconds(250))
        print(
            "CHAT_INDEX_BENCHMARK sessions=500 cold_ms=\(milliseconds(coldElapsed)) "
                + "warm_ms=\(milliseconds(warmElapsed)) first_page_ms=\(milliseconds(pageElapsed))"
        )

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let result = scanner.scan(profile: profile)
            XCTAssertEqual(result.sessions.count, 500)
            _ = scanner.loadTranscriptPage(for: result.sessions[0])
        }
    }

    private func milliseconds(_ duration: Duration) -> String {
        let components = duration.components
        let value = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return String(format: "%.2f", value)
    }
}

private struct PerformanceNeverInUseChecker: ProfileUsageChecking {
    func isProfileInUse(_: CodexProfile) -> Bool { false }
}
