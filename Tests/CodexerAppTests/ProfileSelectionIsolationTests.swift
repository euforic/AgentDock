import AppKit
@testable import CodexerCore
import SwiftUI
import XCTest
@testable import Codexer

@MainActor
final class ProfileSelectionIsolationTests: XCTestCase {
    func testOverviewRefreshPreservesProviderHistoryAndExistingIndexes() async throws {
        let fixture = try SyntheticProfileFixture()
        defer { fixture.remove() }
        let history = try fixture.historySnapshot()
        let indexes = try fixture.indexSnapshot()

        fixture.model.selectProfile(fixture.first.id)
        try await fixture.refreshStats()
        fixture.model.selectOfficial(.codex)
        fixture.model.selectHome()
        fixture.model.reload(refreshData: false)

        XCTAssertEqual(try fixture.historySnapshot(), history)
        XCTAssertEqual(try fixture.indexSnapshot(), indexes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Indexes").path))
    }

    func testDirectSelectionChangeKeepsProfileStatsScoped() async throws {
        let fixture = try SyntheticProfileFixture()
        defer { fixture.remove() }
        let model = fixture.model
        try await fixture.refreshStats()
        model.selectProfile(fixture.first.id)
        XCTAssertEqual(model.stats(for: try XCTUnwrap(model.selectedProfile)).totalTokens, 111)

        // Direct bindings and sidebar actions must resolve the same data boundary.
        model.sidebarSelection = .profile(fixture.second.id)

        XCTAssertEqual(model.selectedProfile?.id, fixture.second.id)
        XCTAssertEqual(model.stats(for: try XCTUnwrap(model.selectedProfile)).totalTokens, 222)
        XCTAssertEqual(model.stats(for: fixture.first).totalTokens, 111)
    }

    func testHomeStartsByDefaultAndSurvivesReload() throws {
        let fixture = try SyntheticProfileFixture()
        defer { fixture.remove() }
        XCTAssertTrue(fixture.model.showsHome)
        XCTAssertNil(fixture.model.selectedProfile)
        fixture.model.reload(refreshData: false)
        XCTAssertTrue(fixture.model.showsHome)
    }

    func testHomeClosesSourcePanelsAndReturnsToProfileOverview() async throws {
        let fixture = try SyntheticProfileFixture()
        defer { fixture.remove() }
        let model = fixture.model
        try await fixture.refreshStats()
        model.selectProfile(fixture.first.id)
        model.detailTab = .advanced
        model.resetReminders.showsAvailableResets = true

        model.selectHome()

        XCTAssertTrue(model.showsHome)
        XCTAssertNil(model.selectedProfile)
        XCTAssertFalse(model.resetReminders.showsAvailableResets)
        model.selectProfile(fixture.second.id)
        XCTAssertEqual(model.detailTab, .overview)
        XCTAssertEqual(model.stats(for: try XCTUnwrap(model.selectedProfile)).totalTokens, 222)
    }

    func testInvalidOrEmptySelectionNeverResolvesToAnotherProfile() throws {
        let fixture = try SyntheticProfileFixture()
        defer { fixture.remove() }
        fixture.model.sidebarSelection = .profile(UUID())
        XCTAssertNil(fixture.model.selectedProfile)
        fixture.model.sidebarSelection = nil
        XCTAssertNil(fixture.model.selectedProfile)
    }

    func testOfficialCodexStatsUseOnlyTheConfiguredDataRoot() async throws {
        let fixture = try SyntheticProfileFixture()
        defer { fixture.remove() }
        let officialRoot = fixture.root.appendingPathComponent("Official", isDirectory: true)
        try FileManager.default.createDirectory(at: officialRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.first.codexHomePath,
                                        to: officialRoot.appendingPathComponent(".codex", isDirectory: true))

        fixture.model.selectOfficial(.codex)
        try await fixture.refreshStats()

        XCTAssertNil(fixture.model.selectedProfile)
        XCTAssertEqual(fixture.model.selectedOfficialProduct, .codex)
        XCTAssertEqual(fixture.model.officialCodexStats.totalTokens, 111)
        XCTAssertEqual(fixture.model.stats(for: fixture.second).totalTokens, 222)
    }

    func testOfficialClaudeStatsRemainSourceScopedWithoutBrowserIndexes() async throws {
        let fixture = try SyntheticProfileFixture(includeClaude: true)
        defer { fixture.remove() }
        let managed = try XCTUnwrap(fixture.model.profiles.first { $0.product == .claude })
        try fixture.writeClaudeSession(under: managed.claudeUserDataPath, id: "managed-claude", tokens: 333)
        try fixture.writeClaudeSession(under: fixture.root.appendingPathComponent("Official/Claude"),
                                       id: "official-claude", tokens: 777)
        let history = try fixture.historySnapshot()
        let indexes = try fixture.indexSnapshot()

        fixture.model.selectOfficial(.claude)
        try await fixture.refreshStats()

        XCTAssertEqual(fixture.model.officialClaudeStats.totalSessions, 1)
        XCTAssertEqual(fixture.model.officialClaudeStats.totalTokens, 777)
        XCTAssertEqual(fixture.model.stats(for: managed).totalSessions, 1)
        XCTAssertEqual(fixture.model.stats(for: managed).totalTokens, 333)
        XCTAssertEqual(try fixture.historySnapshot(), history)
        XCTAssertEqual(try fixture.indexSnapshot(), indexes)
    }

    func testRemovingFromListPreservesHistoryAndRemovesOnlySelectedLegacyIndexes() async throws {
        let fixture = try SyntheticProfileFixture()
        defer { fixture.remove() }
        let history = try fixture.historySnapshot()
        let indexes = try fixture.indexSnapshot()
        let selectedPrefix = "managed-\(fixture.first.id.uuidString.lowercased())-v"
        let remainingIndexes = indexes.filter { !($0.key as NSString).lastPathComponent.hasPrefix(selectedPrefix) }
        XCTAssertEqual(indexes.count - remainingIndexes.count, 2)

        fixture.model.removeProfileFromList(fixture.first)
        try await fixture.waitUntil { !fixture.model.storeMutationInProgress }

        XCTAssertNil(fixture.model.errorMessage)
        XCTAssertFalse(fixture.model.profiles.contains { $0.id == fixture.first.id })
        XCTAssertEqual(try fixture.historySnapshot(), history)
        XCTAssertEqual(try fixture.indexSnapshot(), remainingIndexes)
    }

    func testPermanentDeletionRemovesOnlySelectedProfileDataAndLegacyIndexes() async throws {
        let fixture = try SyntheticProfileFixture()
        defer { fixture.remove() }
        let official = fixture.root.appendingPathComponent("Official/.codex", isDirectory: true)
        try FileManager.default.copyItem(at: fixture.first.codexHomePath, to: official)
        let history = try fixture.historySnapshot()
        let selectedHistoryPrefix = String(fixture.first.profileDirectory.path.dropFirst(fixture.root.path.count + 1)) + "/"
        let remainingHistory = history.filter { !$0.key.hasPrefix(selectedHistoryPrefix) }
        let indexes = try fixture.indexSnapshot()
        let selectedIndexPrefix = "managed-\(fixture.first.id.uuidString.lowercased())-v"
        let remainingIndexes = indexes.filter { !($0.key as NSString).lastPathComponent.hasPrefix(selectedIndexPrefix) }
        XCTAssertLessThan(remainingHistory.count, history.count)
        XCTAssertEqual(indexes.count - remainingIndexes.count, 2)

        fixture.model.deleteProfileData(fixture.first)
        try await fixture.waitUntil { !fixture.model.storeMutationInProgress }

        XCTAssertNil(fixture.model.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.first.profileDirectory.path))
        XCTAssertFalse(fixture.model.profiles.contains { $0.id == fixture.first.id })
        XCTAssertEqual(try fixture.historySnapshot(), remainingHistory)
        XCTAssertEqual(try fixture.indexSnapshot(), remainingIndexes)
    }

    func testSyntheticVisualAudit() async throws {
        guard let output = ProcessInfo.processInfo.environment["AGENTDOCK_VISUAL_AUDIT_DIR"] else {
            throw XCTSkip("Set AGENTDOCK_VISUAL_AUDIT_DIR to render synthetic UI acceptance images.")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for size in [(name: "regular", width: 1080.0, height: 720.0),
                     (name: "compact", width: 900.0, height: 600.0)] {
            let fixture = try SyntheticProfileFixture(firstName: size.name == "compact"
                ? "Design Studio — Product and Platform Engineering" : "Design Studio", includeClaude: true)
            defer { fixture.remove() }
            let model = fixture.model
            model.selectProfile(fixture.first.id)
            try await fixture.refreshStats()
            let updater = AppUpdater()
            for appearance in [AgentDockAppearance.light, .dark] {
              for destination in ["home", "overview"] {
                if destination == "home" { model.selectHome() }
                else { model.selectProfile(fixture.first.id) }
                model.preferences.appearance = appearance
                model.detailTab = .overview
                let view = NSHostingView(rootView: ContentView()
                    .environmentObject(model)
                    .environmentObject(updater))
                view.sizingOptions = []
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                                      styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.animationBehavior = .none
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.contentView = view
                window.setContentSize(NSSize(width: size.width, height: size.height))
                NSApplication.shared.setActivationPolicy(.regular)
                NSApplication.shared.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(800))
                view.layoutSubtreeIfNeeded()
                // Capture WindowServer composition, including native glass controls.
                let arguments = ["-x", "-o", "-l", String(window.windowNumber),
                                 directory.appendingPathComponent("\(size.name)-\(appearance.rawValue)-\(destination).png").path]
                var capture = try BoundedSubprocess.run(
                    executableURL: URL(fileURLWithPath: "/usr/sbin/screencapture"),
                    arguments: arguments,
                    timeout: 5,
                    maximumOutputBytes: 1_024
                )
                let imageURL = directory.appendingPathComponent("\(size.name)-\(appearance.rawValue)-\(destination).png")
                let expectedWidth = Int(size.width * window.backingScaleFactor)
                let expectedHeight = Int(size.height * window.backingScaleFactor)
                let initialImage = (try? Data(contentsOf: imageURL)).flatMap(NSBitmapImageRep.init(data:))
                if capture.terminationStatus != 0 || initialImage?.pixelsWide != expectedWidth
                    || initialImage?.pixelsHigh != expectedHeight {
                    // Retry an incomplete WindowServer activation or animation frame.
                    window.orderFrontRegardless()
                    try await Task.sleep(for: .milliseconds(800))
                    capture = try BoundedSubprocess.run(
                        executableURL: URL(fileURLWithPath: "/usr/sbin/screencapture"),
                        arguments: arguments, timeout: 5, maximumOutputBytes: 1_024
                    )
                }
                XCTAssertEqual(capture.terminationStatus, 0, "Could not capture the synthetic window; verify Screen Recording access.")
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: imageURL)))
                XCTAssertEqual(bitmap.pixelsWide, expectedWidth)
                XCTAssertEqual(bitmap.pixelsHigh, expectedHeight)
                window.close()
              }
            }
        }
    }

}

/// Real on-disk provider records and production services, with no live account reads.
@MainActor
private final class SyntheticProfileFixture {
    let root: URL
    let defaultsName: String
    let model: CodexerModel
    let first: CodexProfile
    let second: CodexProfile

    init(firstName: String = "Design Studio", includeClaude: Bool = false) throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDock-Selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        root = temporaryRoot.resolvingSymlinksInPath().standardizedFileURL
        defaultsName = "AgentDock.SelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let store = try ProfileStore(rootDirectory: root,
                                     shortcutDirectory: root.appendingPathComponent("Shortcuts"))
        first = try store.createProfile(name: firstName)
        second = try store.createProfile(name: "Engineering")
        if includeClaude { _ = try store.createProfile(product: .claude, name: "Studio") }
        for (profile, prompt, tokens) in [(first, "First profile conversation", 111),
                                          (second, "Second profile conversation", 222)] {
            let sessions = profile.codexHomePath.appendingPathComponent("sessions/2026/09/07", isDirectory: true)
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let records: [[String: Any]] = [
                ["timestamp": "2026-09-07T10:00:00Z", "type": "session_meta",
                 "payload": ["id": "shared-session-id", "timestamp": "2026-09-07T10:00:00Z"]],
                ["timestamp": "2026-09-07T10:00:01Z", "type": "response_item",
                 "payload": ["type": "message", "role": "user",
                             "content": [["type": "input_text", "text": prompt]]]]
            ]
            let data = try records.map { try JSONSerialization.data(withJSONObject: $0) }
                .reduce(into: Data()) { $0.append($1); $0.append(0x0a) }
            try data.write(to: sessions.appendingPathComponent("rollout-synthetic.jsonl"))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = [profile.codexHomePath.appendingPathComponent("state_5.sqlite").path, """
                CREATE TABLE threads (id TEXT, tokens_used INTEGER, updated_at INTEGER, archived INTEGER);
                INSERT INTO threads VALUES ('shared-session-id', \(tokens), \(Int(Date().timeIntervalSince1970)), 0);
                """]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        let indexRoot = root.appendingPathComponent("Official/ChatIndexes", isDirectory: true)
        try FileManager.default.createDirectory(at: indexRoot, withIntermediateDirectories: true)
        for scope in ["managed-\(first.id.uuidString.lowercased())",
                      "managed-\(second.id.uuidString.lowercased())", "official-0123456789abcdef"] {
            for version in [1, 2] {
                let data = try JSONSerialization.data(withJSONObject: [
                    "version": version, "scopeKey": scope, "sourceRootKey": "synthetic", "records": []
                ] as [String: Any], options: [.sortedKeys])
                try data.write(to: indexRoot.appendingPathComponent("\(scope)-v\(version).json"))
            }
        }
        let resetStore = ResetReminderStore(defaults: defaults)
        let expirationHours: Double = firstName.contains("Engineering") ? 12 : 48
        var snapshot = ResetReminderStore.Snapshot()
        snapshot.accounts = [ResetAccount(id: "synthetic-account", sourceIDs: [first.id.uuidString],
            names: [first.name], summary: ResetCreditsSummary(availableCount: 2, credits: [
                ResetCredit(id: "tomorrow", grantedAt: .now, expiresAt: Date().addingTimeInterval(expirationHours * 3600)),
                ResetCredit(id: "later", grantedAt: .now, expiresAt: Date().addingTimeInterval(10 * 86400))
            ]), checkedAt: .now, identityVerified: true)]
        resetStore.save(snapshot)
        model = CodexerModel(
            store: store,
            officialDataRootURL: root.appendingPathComponent("Official"),
            codexAppURL: root.appendingPathComponent("Unavailable.app"),
            claudeAppURL: root.appendingPathComponent("Unavailable.app"),
            statsScanner: ProfileStatsScanner(claudeChatScanner: LocalChatScanner(indexRootURL: indexRoot)),
            preferencesStore: AgentDockPreferencesStore(defaults: defaults),
            startMonitoring: false,
            loadActivityOnInit: false,
            resetReminders: ResetReminderController(store: resetStore, nativeNotifications: false)
        )
    }

    func writeClaudeSession(under userData: URL, id: String, tokens: Int) throws {
        let metadata = userData.appendingPathComponent("claude-code-sessions/org/workspace/local_fixture.json")
        let audit = userData.appendingPathComponent("local-agent-mode-sessions/org/workspace/local_fixture/audit.jsonl")
        for file in [metadata, audit] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let timestamp = Date().timeIntervalSince1970 * 1_000
        try JSONSerialization.data(withJSONObject: [
            "sessionId": id, "title": "Synthetic Claude session", "model": "claude-opus-4-1",
            "createdAt": timestamp, "lastActivityAt": timestamp, "isArchived": false
        ]).write(to: metadata)
        var data = try JSONSerialization.data(withJSONObject: [
            "type": "assistant", "requestId": "synthetic-request",
            "message": ["id": "synthetic-message", "usage": ["input_tokens": tokens, "output_tokens": 0]]
        ])
        data.append(0x0a)
        try data.write(to: audit)
    }

    func historySnapshot() throws -> [String: Data] {
        try snapshot { url in
            url.lastPathComponent == "state_5.sqlite"
                || url.pathExtension == "jsonl"
                || url.lastPathComponent == "local_fixture.json"
        }
    }

    func indexSnapshot() throws -> [String: Data] {
        try snapshot { $0.path.hasPrefix(root.appendingPathComponent("Official/ChatIndexes").path + "/") }
    }

    private func snapshot(including predicate: (URL) -> Bool) throws -> [String: Data] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey]))
        var files: [String: Data] = [:]
        let rootPrefix = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        for case let enumeratedURL as URL in enumerator {
            let url = enumeratedURL.resolvingSymlinksInPath().standardizedFileURL
            guard predicate(url),
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            XCTAssertTrue(url.path.hasPrefix(rootPrefix), "Fixture record escaped its canonical root")
            guard url.path.hasPrefix(rootPrefix) else { continue }
            files[String(url.path.dropFirst(rootPrefix.count))] = try Data(contentsOf: url)
        }
        return files
    }

    func refreshStats() async throws {
        model.refreshStats()
        try await waitUntil { !self.model.officialStatsLoading && self.model.statsLoadingProfileIDs.isEmpty }
    }

    func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Synthetic profile operation did not finish")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func remove() {
        model.sidebarSelection = nil
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}
