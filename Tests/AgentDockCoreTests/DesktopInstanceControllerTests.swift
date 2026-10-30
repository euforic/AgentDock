import XCTest
@testable import AgentDockCore

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

    func testConcurrentStatusBatchesDoNotHoldCooperativeThreads() async throws {
        let appURL = try executableCodexApp()
        defer { try? FileManager.default.removeItem(at: appURL) }
        let managedProfile = profile(product: .codex)
        let provider = DelayedProcessSnapshotProvider(appURL: appURL, managedProfile: managedProfile)
        // More reads than cooperative threads: reads that blocked on their
        // snapshot would serialize into at least three rounds of one second each.
        let count = ProcessInfo.processInfo.activeProcessorCount * 3
        let start = Date()

        let batches = try await withThrowingTaskGroup(of: ProviderInstanceStatusBatch.self) { group in
            for _ in 0..<count {
                group.addTask {
                    try await CodexInstanceController(processSnapshotProvider: provider)
                        .statusBatch(for: [managedProfile], codexAppURL: appURL)
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5)
        XCTAssertEqual(batches.count, count)
        for batch in batches {
            XCTAssertEqual(batch.managedStatuses, [managedProfile.id: CodexInstanceStatus(processIDs: [222])])
            XCTAssertEqual(batch.officialStatus, CodexInstanceStatus(processIDs: [111]))
        }
    }

    func testStatusReadsOnOneControllerOverlapWhileWaitingForSnapshots() async throws {
        let appURL = try executableCodexApp()
        defer { try? FileManager.default.removeItem(at: appURL) }
        let managedProfile = profile(product: .codex)
        let controller = CodexInstanceController(
            processSnapshotProvider: DelayedProcessSnapshotProvider(
                appURL: appURL,
                managedProfile: managedProfile
            )
        )
        let start = Date()

        // An actor that blocked on each snapshot would run these one at a time.
        async let batch = controller.statusBatch(for: [managedProfile], codexAppURL: appURL)
        async let managed = controller.statuses(for: [managedProfile], codexAppURL: appURL)
        async let official = controller.stockStatus(codexAppURL: appURL)
        let (batchResult, managedResult, officialResult) = try await (batch, managed, official)

        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5)
        XCTAssertEqual(managedResult, [managedProfile.id: CodexInstanceStatus(processIDs: [222])])
        XCTAssertEqual(officialResult, CodexInstanceStatus(processIDs: [111]))
        XCTAssertEqual(batchResult.managedStatuses, managedResult)
        XCTAssertEqual(batchResult.officialStatus, officialResult)
    }

    func testSuspendingSystemSnapshotsListCurrentProcess() async throws {
        let codexSnapshot = try await SystemCodexProcessSnapshotProvider().suspendingProcessSnapshot()
        XCTAssertTrue(codexSnapshot.split(whereSeparator: \.isNewline).contains { line in
            line.split(separator: " ", maxSplits: 1).first.flatMap { Int32($0) } == getpid()
        })

        let claudeSnapshot = try await SystemClaudeProcessSnapshotProvider().suspendingSnapshot()
        XCTAssertEqual(claudeSnapshot.entries[getpid()]?.parentProcessID, getppid())
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

    private func executableCodexApp() throws -> URL {
        let appURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusTest-\(UUID().uuidString).app")
        let executableURL = IsolatedCodexLaunchConfiguration.appExecutableURL(for: appURL)
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
        return appURL
    }
}

/// A child process prints a synthetic official (111) and managed (222) snapshot
/// after one second, so a status read that blocks instead of suspending holds
/// its thread that long.
private struct DelayedProcessSnapshotProvider: CodexProcessSnapshotProviding {
    private let arguments: [String]

    init(appURL: URL, managedProfile: CodexProfile) {
        let executable = IsolatedCodexLaunchConfiguration.appExecutableURL(for: appURL)
            .standardizedFileURL.path
        let snapshot = """
          111 \(executable)
          222 \(executable) --user-data-dir=\(managedProfile.electronUserDataPath.path)
        """
        arguments = ["-c", "sleep 1; printf '%s' \"$1\"", "sh", snapshot]
    }

    func processSnapshot() throws -> String {
        try Self.snapshot(from: BoundedSubprocess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: arguments,
            timeout: 10,
            maximumOutputBytes: 64 * 1_024
        ))
    }

    func suspendingProcessSnapshot() async throws -> String {
        try await Self.snapshot(from: BoundedSubprocess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: arguments,
            timeout: 10,
            maximumOutputBytes: 64 * 1_024
        ))
    }

    private static func snapshot(from result: BoundedSubprocessResult) throws -> String {
        guard result.terminationStatus == 0, !result.exceededOutputLimit else {
            throw CodexLauncherError.processInspectionFailed(result.terminationStatus)
        }
        return String(decoding: result.output, as: UTF8.self)
    }
}
