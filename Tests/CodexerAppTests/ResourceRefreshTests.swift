import Foundation
import XCTest
import CodexerCore

@testable import Codexer

final class ResourceRefreshTests: XCTestCase {
    @MainActor func testInventoryPollingKeepsDisabledInventoryUsefulAndReplenishesMilestones() {
        let now = Date()
        XCTAssertEqual(ResetReminderController.pollDelay(active: true, remindersEnabled: false, nextMilestone: nil, now: now), 300)
        XCTAssertEqual(ResetReminderController.pollDelay(active: false, remindersEnabled: false, nextMilestone: now.addingTimeInterval(60), now: now), 1800)
        XCTAssertEqual(ResetReminderController.pollDelay(active: false, remindersEnabled: true, nextMilestone: nil, now: now), 1800)
        XCTAssertEqual(ResetReminderController.pollDelay(active: false, remindersEnabled: true, nextMilestone: now.addingTimeInterval(400), now: now), 400)
        XCTAssertEqual(ResetReminderController.pollDelay(active: false, remindersEnabled: true, nextMilestone: now.addingTimeInterval(20), now: now), 60)
    }
}

@MainActor
final class ResourceRefreshIntegrationTests: XCTestCase {
    func testActivationFreshnessAndProfileDiscoveryUseProductionReaders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ResourceRefresh.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = try ProfileStore(rootDirectory: root, shortcutDirectory: root.appendingPathComponent("Shortcuts"))
        let profile = try store.createProfile(name: "Synthetic")
        let model = CodexerModel(store: store, officialDataRootURL: root.appendingPathComponent("Official"),
            codexAppURL: root.appendingPathComponent("Missing.app"), claudeAppURL: root.appendingPathComponent("Missing.app"),
            preferencesStore: AgentDockPreferencesStore(defaults: defaults), startMonitoring: false,
            resetReminders: ResetReminderController(store: ResetReminderStore(defaults: defaults), nativeNotifications: false))
        try Data("model_provider = \"openai\"\n".utf8).write(to: profile.codexHomePath.appendingPathComponent("work.config.toml"))
        model.refreshConfigProfiles()
        try await eventually { model.lastStatsRefreshAt != nil && model.codexConfigProfiles(for: profile).count == 1 }
        let first = try XCTUnwrap(model.lastStatsRefreshAt)
        model.refreshActivityIfStale(now: first.addingTimeInterval(10))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.lastStatsRefreshAt, first)
        model.setApplicationActive(false)
        model.refreshActivityIfStale(now: first.addingTimeInterval(3600))
        XCTAssertEqual(model.lastStatsRefreshAt, first)
        model.setApplicationActive(true)
        model.refreshActivityIfStale(now: first.addingTimeInterval(3600))
        try await eventually { model.lastStatsRefreshAt != first }
        XCTAssertEqual(model.codexConfigProfiles(for: profile).first?.name, "work")
    }

    func testConcurrentStatusRequestsCoalesceAndRecentActivationIsThrottled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "StatusRefresh.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = try ProfileStore(rootDirectory: root, shortcutDirectory: root.appendingPathComponent("Shortcuts"))
        _ = try store.createProfile(name: "Synthetic")
        let model = CodexerModel(store: store, officialDataRootURL: root.appendingPathComponent("Official"),
            codexAppURL: root.appendingPathComponent("Missing.app"), claudeAppURL: root.appendingPathComponent("Missing.app"),
            preferencesStore: AgentDockPreferencesStore(defaults: defaults), loadActivityOnInit: false,
            resetReminders: ResetReminderController(store: ResetReminderStore(defaults: defaults), nativeNotifications: false))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<30 { group.addTask { await model.refreshInstanceStatuses(force: false) } }
        }
        XCTAssertEqual(model.completedStatusBatches, 1)
        await model.refreshInstanceStatuses(force: false)
        XCTAssertEqual(model.completedStatusBatches, 1)
        await model.refreshInstanceStatuses()
        XCTAssertEqual(model.completedStatusBatches, 2)
        model.setApplicationActive(false)
        model.scheduleWorkspaceStatusRefresh()
        model.setApplicationActive(true)
        await model.refreshInstanceStatuses(force: false)
        XCTAssertEqual(model.completedStatusBatches, 3, "Provider events while inactive must invalidate a recent status result.")
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }
}
