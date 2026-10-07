import AppKit
@testable import CodexerCore
import SwiftUI
import XCTest
@testable import Codexer

@MainActor
final class HomeUsageResetVisualTests: XCTestCase {
    func testSyntheticResetDatesAtHomeMeterWidth() async throws {
        guard let output = ProcessInfo.processInfo.environment["AGENTDOCK_VISUAL_AUDIT_DIR"] else {
            throw XCTSkip("Set AGENTDOCK_VISUAL_AUDIT_DIR to render synthetic usage reset dates.")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let snapshots: [(String, ProfileRateLimits)] = [
            ("Two usage windows", ProfileRateLimits(buckets: [RateLimitBucket(id: "codex", name: "Usage",
                primary: RateLimitWindowUsage(usedPercent: 32, windowDurationMins: 300,
                    resetsAt: now.addingTimeInterval(3 * 3600 + 15 * 60)),
                secondary: RateLimitWindowUsage(usedPercent: 8, windowDurationMins: 10080,
                    resetsAt: now.addingTimeInterval(2 * 86400 + 3 * 3600)))])),
            ("Reset due", ProfileRateLimits(buckets: [RateLimitBucket(id: "codex", name: "Usage",
                primary: nil, secondary: RateLimitWindowUsage(usedPercent: 14, windowDurationMins: 10080,
                    resetsAt: now.addingTimeInterval(-60)))])),
            ("Reset not reported", ProfileRateLimits(buckets: [RateLimitBucket(id: "codex", name: "Usage",
                primary: nil, secondary: RateLimitWindowUsage(usedPercent: 2, windowDurationMins: 10080,
                    resetsAt: nil))]))
        ]
        for scheme in [ColorScheme.light, .dark] {
            let content = HStack(alignment: .top, spacing: 24) {
                ForEach(snapshots.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(snapshots[index].0).font(.headline)
                        HomeUsageSummary(limits: snapshots[index].1, accent: .blue)
                    }
                    .frame(width: 220, alignment: .leading)
                }
            }
            .padding(20)
            .frame(width: 748, height: 230, alignment: .topLeading)
            .foregroundStyle(scheme == .dark ? Color.white : .black)
            .background(scheme == .dark ? Color(white: 0.12) : .white)
            .environment(\.colorScheme, scheme)
            let view = NSHostingView(rootView: content)
            view.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 748, height: 230),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = view
            defer { window.close() }
            NSApplication.shared.setActivationPolicy(.regular)
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(800))
            view.layoutSubtreeIfNeeded()
            let imageURL = directory.appendingPathComponent("usage-resets-\(scheme == .dark ? "dark" : "light").png")
            let capture = try BoundedSubprocess.run(executableURL: URL(fileURLWithPath: "/usr/sbin/screencapture"),
                arguments: ["-x", "-o", "-l", String(window.windowNumber), imageURL.path],
                timeout: 5, maximumOutputBytes: 1024)
            XCTAssertEqual(capture.terminationStatus, 0)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: imageURL)))
            XCTAssertEqual(bitmap.pixelsWide, Int(748 * window.backingScaleFactor))
            XCTAssertEqual(bitmap.pixelsHigh, Int(230 * window.backingScaleFactor))
        }
    }
}
