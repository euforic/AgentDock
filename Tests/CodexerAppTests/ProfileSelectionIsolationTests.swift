import AppKit
@testable import CodexerCore
import SwiftUI
import XCTest
@testable import Codexer

@MainActor
final class ProfileSelectionIsolationTests: XCTestCase {
    func testOverviewSelectionDoesNotReadChatsOrWriteAnIndex() async throws {
        let fixture = try SyntheticProfileFixture()
        defer { fixture.remove() }
        fixture.model.selectProfile(fixture.first.id)
        try await fixture.waitForChats()

        XCTAssertTrue(fixture.model.chatSessions.isEmpty)
        XCTAssertTrue(fixture.model.chatTranscriptEntries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("Indexes").path
        ))
    }

    func testDirectSelectionChangeImmediatelyClearsPreviousProfileContent() async throws {
        let fixture = try SyntheticProfileFixture()
        defer { fixture.remove() }
        let model = fixture.model
        fixture.showChats()
        model.selectProfile(fixture.first.id)
        try await fixture.waitForChats()
        XCTAssertFalse(model.chatTranscriptEntries.isEmpty)
        let previousChat = try XCTUnwrap(model.selectedChatID)

        // Direct bindings and reloads must provide the same boundary as sidebar actions.
        model.sidebarSelection = .profile(fixture.second.id)

        XCTAssertEqual(model.selectedProfile?.id, fixture.second.id)
        XCTAssertTrue(model.chatSessions.isEmpty)
        XCTAssertTrue(model.chatTranscriptEntries.isEmpty)
        XCTAssertNil(model.selectedChatID)
        XCTAssertFalse(model.hasMoreChatTranscript)
        model.selectChat(previousChat)
        XCTAssertNil(model.selectedChatID)

        model.refreshChats()
        try await fixture.waitForChats()
        XCTAssertEqual(model.chatSessions.map(\.profileID), [fixture.second.id])
        XCTAssertEqual(model.chatTranscriptEntries.filter { $0.kind == .message }.map(\.text), ["Second profile conversation"])
    }

    func testHomeStartsByDefaultAndSurvivesReload() throws {
        let fixture = try SyntheticProfileFixture()
        defer { fixture.remove() }
        XCTAssertTrue(fixture.model.showsHome)
        XCTAssertNil(fixture.model.selectedProfile)
        fixture.model.reload(refreshData: false)
        XCTAssertTrue(fixture.model.showsHome)
    }

    func testHomeClearsPreviousTranscriptAndReturnsToProfileOverview() async throws {
        let fixture = try SyntheticProfileFixture()
        defer { fixture.remove() }
        let model = fixture.model
        fixture.showChats()
        model.selectProfile(fixture.first.id)
        try await fixture.waitForChats()
        XCTAssertFalse(model.chatTranscriptEntries.isEmpty)
        model.detailTab = .chats
        model.resetReminders.showsAvailableResets = true
        model.selectHome()
        XCTAssertTrue(model.showsHome)
        XCTAssertFalse(model.resetReminders.showsAvailableResets)
        XCTAssertTrue(model.chatSessions.isEmpty)
        XCTAssertTrue(model.chatTranscriptEntries.isEmpty)
        XCTAssertNil(model.selectedChatID)
        model.refreshChats()
        try await fixture.waitForChats()
        XCTAssertTrue(model.chatSessions.isEmpty)
        model.selectProfile(fixture.second.id)
        XCTAssertEqual(model.detailTab, .overview)
        try await fixture.waitForChats()
        XCTAssertTrue(model.chatSessions.isEmpty)
        fixture.showChats()
        try await fixture.waitForChats()
        XCTAssertEqual(model.chatSessions.map(\.profileID), [fixture.second.id])
    }

    func testInvalidOrEmptySelectionNeverResolvesToAnotherProfile() throws {
        let fixture = try SyntheticProfileFixture()
        defer { fixture.remove() }
        fixture.model.sidebarSelection = .profile(UUID())
        XCTAssertNil(fixture.model.selectedProfile)
        fixture.model.sidebarSelection = nil
        XCTAssertNil(fixture.model.selectedProfile)
    }

    func testOfficialSelectionUsesOnlyTheConfiguredDataRoot() async throws {
        let fixture = try SyntheticProfileFixture()
        defer { fixture.remove() }
        let officialRoot = fixture.root.appendingPathComponent("Official", isDirectory: true)
        try FileManager.default.createDirectory(at: officialRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture.first.codexHomePath,
            to: officialRoot.appendingPathComponent(".codex", isDirectory: true)
        )

        fixture.showChats()
        fixture.model.selectOfficial(.codex)
        try await fixture.waitForChats()

        XCTAssertEqual(fixture.model.chatSessions.count, 1)
        XCTAssertEqual(fixture.model.chatTranscriptEntries.filter { $0.kind == .message }.map(\.text),
                       ["First profile conversation"])
        XCTAssertTrue(fixture.model.chatSessions.allSatisfy {
            $0.sourceURL.path.hasPrefix(officialRoot.path + "/")
        })
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
            fixture.showChats()
            model.selectProfile(fixture.first.id)
            try await fixture.waitForChats()
            let updater = AppUpdater()
            for appearance in [AgentDockAppearance.light, .dark] {
              for destination in ["home", "overview", "chats"] {
                if destination == "home" { model.selectHome() }
                else { model.selectProfile(fixture.first.id) }
                let tab: AgentDockDetailTab = destination == "chats" ? .chats : .overview
                model.preferences.appearance = appearance
                model.detailTab = tab
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

    func testChatPollingStopsWhileHiddenAndWhileInactive() async throws {
        let fixture = try SyntheticProfileFixture(startMonitoring: true)
        defer { fixture.remove() }
        let model = fixture.model
        model.selectProfile(fixture.first.id)
        fixture.showChats()
        try await fixture.waitForChats()
        XCTAssertEqual(model.chatSessions.count, 1)

        for inactive in [false, true] {
            if inactive { model.setApplicationActive(false) }
            else {
                model.detailTab = .overview
                fixture.hideChats()
            }
            let previousEntries = model.chatTranscriptEntries
            let indexes = fixture.root.appendingPathComponent("Indexes")
            let indexFiles = try FileManager.default.contentsOfDirectory(
                at: indexes, includingPropertiesForKeys: nil
            )
            XCTAssertFalse(indexFiles.isEmpty)
            let previousDates = try indexFiles.map {
                try FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date
            }
            let message = inactive ? "Updated while inactive" : "Updated while hidden"
            try fixture.appendAssistantMessage(message)
            model.refreshChats()
            model.loadMoreChatTranscript()
            // Two five-second polls would reload this changed source if monitoring leaked.
            try await Task.sleep(for: .seconds(11))

            XCTAssertFalse(model.chatsLoading)
            XCTAssertFalse(model.chatTranscriptLoading)
            XCTAssertFalse(model.chatOlderTranscriptLoading)
            XCTAssertEqual(model.chatTranscriptEntries, previousEntries)
            XCTAssertEqual(try indexFiles.map {
                try FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date
            }, previousDates)

            if inactive { model.setApplicationActive(true) }
            else { fixture.showChats() }
            try await fixture.waitForChats()
            XCTAssertEqual(model.chatTranscriptEntries.last?.text, message)
        }

        try fixture.appendAssistantMessage("Updated while visible")
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while model.chatTranscriptEntries.last?.text != "Updated while visible",
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.chatTranscriptEntries.last?.text, "Updated while visible")
    }

    func testHidingChatsCancelsLoadingWithoutLeavingSpinners() async throws {
        let fixture = try SyntheticProfileFixture()
        defer { fixture.remove() }
        fixture.model.selectProfile(fixture.first.id)
        fixture.showChats()
        XCTAssertTrue(fixture.model.chatsLoading)
        fixture.hideChats()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(fixture.model.chatsLoading)
        XCTAssertFalse(fixture.model.chatTranscriptLoading)
        XCTAssertTrue(fixture.model.chatSessions.isEmpty)
        fixture.showChats()
        try await fixture.waitForChats()
        XCTAssertEqual(fixture.model.chatSessions.count, 1)
    }

    func testClosingOneChatBrowserKeepsTheOtherBrowserActive() async throws {
        let fixture = try SyntheticProfileFixture()
        defer { fixture.remove() }
        let model = fixture.model
        model.selectProfile(fixture.first.id)
        fixture.showChats()
        try await fixture.waitForChats()
        let otherBrowser = UUID()
        model.setChatBrowserVisible(true, browserID: otherBrowser)
        fixture.hideChats()
        try fixture.appendAssistantMessage("Other window remains visible")
        model.refreshChats()
        try await fixture.waitForChats()
        XCTAssertEqual(model.chatTranscriptEntries.last?.text, "Other window remains visible")

        model.setChatBrowserVisible(false, browserID: otherBrowser)
        model.refreshChats()
        XCTAssertFalse(model.chatsLoading)
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
    private let chatBrowserID = UUID()

    init(firstName: String = "Design Studio", includeClaude: Bool = false,
         startMonitoring: Bool = false) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDock-Selection-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        defaultsName = "AgentDock.SelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let store = try ProfileStore(rootDirectory: root,
                                     shortcutDirectory: root.appendingPathComponent("Shortcuts"))
        first = try store.createProfile(name: firstName)
        second = try store.createProfile(name: "Engineering")
        if includeClaude { _ = try store.createProfile(product: .claude, name: "Studio") }
        for (profile, prompt) in [(first, "First profile conversation"), (second, "Second profile conversation")] {
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
            preferencesStore: AgentDockPreferencesStore(defaults: defaults),
            chatScanner: LocalChatScanner(indexRootURL: root.appendingPathComponent("Indexes")),
            startMonitoring: startMonitoring,
            loadActivityOnInit: false,
            resetReminders: ResetReminderController(store: resetStore, nativeNotifications: false)
        )
    }

    func showChats() {
        model.detailTab = .chats
        model.setChatBrowserVisible(true, browserID: chatBrowserID)
    }

    func hideChats() {
        model.setChatBrowserVisible(false, browserID: chatBrowserID)
    }

    func appendAssistantMessage(_ text: String) throws {
        let transcript = first.codexHomePath
            .appendingPathComponent("sessions/2026/09/07/rollout-synthetic.jsonl")
        let writer = try FileHandle(forWritingTo: transcript)
        defer { try? writer.close() }
        try writer.seekToEnd()
        let record: [String: Any] = [
            "timestamp": "2026-09-07T10:00:02Z", "type": "response_item",
            "payload": ["type": "message", "role": "assistant",
                        "content": [["type": "output_text", "text": text]]]
        ]
        var data = try JSONSerialization.data(withJSONObject: record)
        data.append(0x0a)
        try writer.write(contentsOf: data)
    }

    func waitForChats() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.chatsLoading || model.chatTranscriptLoading {
            guard ContinuousClock.now < deadline else {
                XCTFail("Synthetic transcript did not finish loading")
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
