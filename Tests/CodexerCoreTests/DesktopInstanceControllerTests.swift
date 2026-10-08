import XCTest
@testable import CodexerCore

final class DesktopInstanceControllerTests: XCTestCase {
    func testStatusBatchSkipsUnselectedProviders() async {
        let profiles = DesktopProduct.allCases.map { product in
            profile(product: product)
        }
        let batch = await DesktopInstanceController().statusBatch(for: profiles, appURLs: [:])
        XCTAssertEqual(batch, DesktopInstanceStatusBatch())
    }

    func testFailedClaudeInspectionPreservesCodexBatch() async throws {
        let codexProfile = profile(product: .codex)
        let claudeProfile = profile(product: .claude)
        let missingApp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Missing.app")
        let batch = await DesktopInstanceController().statusBatch(
            for: [codexProfile, claudeProfile],
            appURLs: [.codex: missingApp, .claude: missingApp]
        )
        XCTAssertEqual(batch.managedStatuses, [codexProfile.id: CodexInstanceStatus()])
        XCTAssertEqual(batch.officialStatuses, [.codex: CodexInstanceStatus()])
    }

    func testCancelledBatchReturnsNoStatuses() async {
        let controller = DesktopInstanceController()
        let profiles = DesktopProduct.allCases.map { profile(product: $0) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await controller.statusBatch(
                for: profiles,
                appURLs: [.codex: DesktopAppRegistry.codex.defaultAppURL,
                          .claude: DesktopAppRegistry.claude.defaultAppURL]
            )
        }
        let batch = await task.value
        XCTAssertEqual(batch, DesktopInstanceStatusBatch())
    }

    func testMissingOrNonExecutableCodexProviderBatchReportsStopped() async throws {
        let appURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusTest-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: appURL) }
        let executableURL = IsolatedCodexLaunchConfiguration.appExecutableURL(for: appURL)
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let managedProfile = profile(product: .codex)
        let controller = CodexInstanceController()
        let missing = try await controller.statusBatch(for: [managedProfile], codexAppURL: appURL)
        XCTAssertEqual(missing.managedStatuses, [managedProfile.id: CodexInstanceStatus()])
        XCTAssertEqual(missing.officialStatus, CodexInstanceStatus())

        try Data("Nonexecutable test file".utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executableURL.path)
        XCTAssertFalse(FileManager.default.isExecutableFile(atPath: executableURL.path))
        let nonExecutable = try await controller.statusBatch(for: [managedProfile], codexAppURL: appURL)
        XCTAssertEqual(nonExecutable.managedStatuses, [managedProfile.id: CodexInstanceStatus()])
        XCTAssertEqual(nonExecutable.officialStatus, CodexInstanceStatus())
    }

    func testCancelledClaudeInspectionStopsBeforeInvalidAppValidation() async {
        let controller = ClaudeInstanceController()
        let missingApp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await controller.stockStatus(appURL: missingApp)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        let wasCancelled = await task.value
        XCTAssertTrue(wasCancelled)
    }

    func testEmptyManagedClaudeRequestNeedsNoInstalledApp() async throws {
        let statuses = try await ClaudeInstanceController().statuses(
            for: [],
            appURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        XCTAssertTrue(statuses.isEmpty)
    }

    func testInstalledProviderBatchMatchesSeparateStatusAPIs() async throws {
        guard ProcessInfo.processInfo.environment["AGENTDOCK_INSTALLED_APP_TEST"] == "1",
              ProcessInfo.processInfo.environment["AGENTDOCK_INSTALLED_CLAUDE_TEST"] == "1"
        else {
            throw XCTSkip("Enable both installed-app test flags to inspect signed provider apps.")
        }
        let controller = DesktopInstanceController()
        let profiles = DesktopProduct.allCases.map { profile(product: $0) }
        let appURLs = Dictionary(uniqueKeysWithValues: DesktopProduct.allCases.map {
            ($0, DesktopAppRegistry.descriptor(for: $0).defaultAppURL)
        })
        for (product, appURL) in appURLs {
            try await controller.validateApp(product: product, at: appURL)
        }
        let batch = await controller.statusBatch(for: profiles, appURLs: appURLs)
        let managed = try await controller.statuses(for: profiles, appURLs: appURLs)
        XCTAssertEqual(batch.managedStatuses, managed)
        XCTAssertEqual(batch.officialStatuses.count, DesktopProduct.allCases.count)
        for (product, appURL) in appURLs {
            let official = try await controller.stockStatus(product: product, appURL: appURL)
            XCTAssertEqual(batch.officialStatuses[product], official)
        }
    }

    private func profile(product: DesktopProduct) -> CodexProfile {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return CodexProfile(
            product: product,
            name: "Status test",
            slug: "status-test",
            profileDirectory: root.appendingPathComponent("Profile"),
            shortcutDirectory: root.appendingPathComponent("Shortcut")
        )
    }
}
