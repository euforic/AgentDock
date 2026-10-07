import AppKit
import SwiftUI
import Foundation
import XCTest
@testable import CodexerCore
@testable import Codexer

@MainActor
final class ResetReminderControllerTests: XCTestCase {
    func testSyntheticResetViews() async throws {
        guard let path = ProcessInfo.processInfo.environment["AGENTDOCK_RESET_VISUAL_AUDIT_DIR"] else {
            throw XCTSkip("Synthetic visual capture is opt in.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "ResetViews.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ResetReminderStore(defaults: defaults)
        let now = Date()
        var accounts: [ResetAccount] = []
        for (index, name) in ["Personal", "Studio", "Development", "Research"].enumerated() {
            let credits = (0..<12).map { offset in
                ResetCredit(id: "synthetic-\(index)-\(offset)", grantedAt: now,
                    expiresAt: offset == 11 ? nil : now.addingTimeInterval(Double(offset * 86400 + index * 7200 + 3600)),
                    title: "Full reset", description: "Weekly + 5-hour reset")
            }
            var account = ResetAccount(id: "synthetic-account-\(index)", sourceIDs: [name.lowercased()], names: [name],
                summary: ResetCreditsSummary(availableCount: credits.count + (index == 1 ? 1 : 0), credits: credits),
                checkedAt: now, identityVerified: true)
            account.accountEmail = "\(name.lowercased())@example.com"
            account.sourceNames = [name.lowercased(): name]
            accounts.append(account)
        }
        var snapshot = ResetReminderStore.Snapshot(); snapshot.accounts = accounts; snapshot.policy.enabled = true
        store.save(snapshot)
        let controller = ResetReminderController(store: store, nativeNotifications: false)
        for dark in [false, true] {
            for compact in [false, true] {
                let size = NSSize(width: compact ? 640 : 860, height: 640)
                for settings in [false, true] {
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    let view: NSView
                    if settings {
                        view = NSHostingView(rootView: ScrollView { ResetNotificationSettings(controller: controller).padding(24) }
                            .preferredColorScheme(dark ? .dark : .light))
                    } else {
                        view = NSHostingView(rootView: AvailableResetsView(controller: controller, openAccount: { _ in })
                            .preferredColorScheme(dark ? .dark : .light))
                    }
                    view.frame = NSRect(origin: .zero, size: size)
                    window.contentView = view
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    NSApplication.shared.setActivationPolicy(.regular)
                    window.makeKeyAndOrderFront(nil)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    try await Task.sleep(for: .milliseconds(800))
                    view.layoutSubtreeIfNeeded()
                    let file = directory.appendingPathComponent("\(settings ? "settings" : "resets")-\(dark ? "dark" : "light")-\(compact ? "compact" : "regular").png")
                    let result = try BoundedSubprocess.run(executableURL: URL(fileURLWithPath: "/usr/sbin/screencapture"),
                        arguments: ["-x", "-o", "-l", String(window.windowNumber), file.path], timeout: 5, maximumOutputBytes: 1024)
                    XCTAssertEqual(result.terminationStatus, 0)
                    window.close()
                }
            }
        }
    }

    func testSnoozeStopResumeAndGlobalSettingsPersistWithRealPreferences() throws {
        let suite = "ResetReminderControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ResetReminderStore(defaults: defaults)
        let now = Date()
        let credit = ResetCredit(id: "synthetic-credit", grantedAt: now, expiresAt: now.addingTimeInterval(7200))
        let account = ResetAccount(id: "synthetic-account", sourceIDs: ["synthetic-source"], names: ["Synthetic Account"],
            summary: ResetCreditsSummary(availableCount: 1, credits: [credit]), checkedAt: now)
        var saved = ResetReminderStore.Snapshot(); saved.accounts = [account]
        store.save(saved)
        let controller = ResetReminderController(store: store, nativeNotifications: false)
        let key = account.key(for: credit)
        let until = now.addingTimeInterval(3600)
        XCTAssertTrue(controller.snooze(key: key, until: until, now: now))
        XCTAssertEqual(ResetReminderController(store: store, nativeNotifications: false).state(for: key).snoozedUntil, until)
        XCTAssertFalse(controller.snooze(key: key, until: now.addingTimeInterval(7200), now: now))
        XCTAssertFalse(controller.snooze(key: key, until: now, now: now))
        XCTAssertEqual(controller.state(for: key).snoozedUntil, until)
        controller.stop(key: key)
        XCTAssertTrue(ResetReminderController(store: store, nativeNotifications: false).state(for: key).stopped)
        controller.resume(key: key)
        XCTAssertEqual(controller.state(for: key), ResetReminderState())
        controller.policy.enabled = true
        controller.policy.warningMinutes = [1440, 60, 15]
        controller.policy.repeatHours = 12
        let restored = ResetReminderController(store: store, nativeNotifications: false)
        XCTAssertEqual(restored.policy, controller.policy)
        XCTAssertEqual(restored.policy.warningMinutes, [1440, 60, 15])
        XCTAssertEqual(restored.policy.repeatHours, 12)
    }
}
