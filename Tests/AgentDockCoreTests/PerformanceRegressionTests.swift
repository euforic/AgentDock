import XCTest
@testable import AgentDockCore

final class PerformanceRegressionTests: XCTestCase {
    func testIsolatedInstanceDiscoveryPerformance() {
        let root = URL(fileURLWithPath: "/tmp/AgentDock Performance")
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
            .appendingPathComponent("AgentDockStorePerformance-\(UUID().uuidString)")
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
                to: profile.profileDirectory.appendingPathComponent(".agentdock-profile.json")
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
}

private struct PerformanceNeverInUseChecker: ProfileUsageChecking {
    func isProfileInUse(_: CodexProfile) -> Bool { false }
}
