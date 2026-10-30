import XCTest
@testable import AgentDockCore

final class BoundedSubprocessTests: XCTestCase {
    func testCapturesSuccessfulOutputAndExitStatus() throws {
        let result = try BoundedSubprocess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'ready'"],
            timeout: 1,
            maximumOutputBytes: 1_024
        )

        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "ready")
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertFalse(result.exceededOutputLimit)
    }

    func testCapturesStandardErrorWhenRequested() throws {
        let result = try BoundedSubprocess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'failure detail' >&2; exit 7"],
            timeout: 1,
            maximumOutputBytes: 1_024,
            captureStandardError: true
        )

        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "failure detail")
        XCTAssertEqual(result.terminationStatus, 7)
    }

    func testOutputLimitIsFailClosed() throws {
        let result = try BoundedSubprocess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '0123456789abcdef'"],
            timeout: 1,
            maximumOutputBytes: 8
        )

        XCTAssertTrue(result.exceededOutputLimit)
        XCTAssertTrue(result.output.isEmpty)
    }

    func testTimeoutKillsAndReapsTermIgnoringProcess() {
        let start = Date()

        XCTAssertThrowsError(try BoundedSubprocess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; while :; do :; done"],
            timeout: 0.05,
            maximumOutputBytes: 1_024
        )) { error in
            XCTAssertEqual(error as? BoundedSubprocessError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testTimeoutAlsoKillsTermIgnoringDescendant() throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDock-child-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = "trap '' TERM; (trap '' TERM; while :; do sleep 1; done) & echo $! > '\(pidFile.path)'; while :; do sleep 1; done"

        XCTAssertThrowsError(try BoundedSubprocess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            timeout: 0.1,
            maximumOutputBytes: 1_024
        ))

        let processID = try XCTUnwrap(
            Int32(
                String(contentsOf: pidFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        XCTAssertEqual(kill(processID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testTimeoutRemainsBoundedWhenExitedParentLeavesPipeOpen() {
        let start = Date()

        XCTAssertThrowsError(try BoundedSubprocess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 2 &"],
            timeout: 0.05,
            maximumOutputBytes: 1_024
        )) { error in
            XCTAssertEqual(error as? BoundedSubprocessError, .timedOut)
        }

        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testAsyncRunCapturesOutputAndExitStatus() async throws {
        let result = try await BoundedSubprocess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf async; exit 3"],
            timeout: 2,
            maximumOutputBytes: 1_024
        )

        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "async")
        XCTAssertEqual(result.terminationStatus, 3)
        XCTAssertFalse(result.exceededOutputLimit)
    }

    func testAsyncCancellationKillsTermIgnoringGroupPromptly() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDock-async-child-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = "trap '' TERM; sleep 30 & echo $! > '\(pidFile.path)'; wait"
        let start = Date()

        let task = Task {
            try await BoundedSubprocess.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script],
                timeout: 30,
                maximumOutputBytes: 1_024
            )
        }
        while (try? String(contentsOf: pidFile, encoding: .utf8))?.isEmpty != false,
              Date().timeIntervalSince(start) < 2
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected the cancelled run to fail")
        } catch {
            XCTAssertEqual(error as? BoundedSubprocessError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        let processID = try XCTUnwrap(
            Int32(
                String(contentsOf: pidFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        let deadline = Date().addingTimeInterval(1)
        while kill(processID, 0) == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(kill(processID, 0), -1)
    }

    func testConcurrentAsyncRunsDoNotHoldCooperativeThreads() async throws {
        // More waits than cooperative threads: blocking waits would serialize
        // into at least three rounds of one second each.
        let count = ProcessInfo.processInfo.activeProcessorCount * 3
        let start = Date()

        let statuses = try await withThrowingTaskGroup(of: Int32.self) { group in
            for _ in 0..<count {
                group.addTask {
                    try await BoundedSubprocess.run(
                        executableURL: URL(fileURLWithPath: "/bin/sleep"),
                        arguments: ["1"],
                        timeout: 10,
                        maximumOutputBytes: 1_024
                    ).terminationStatus
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(statuses, Array(repeating: 0, count: count))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5)
    }

    func testSystemUsageCheckerFailsClosedForMissingDirectory() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Missing-Usage-Check-\(UUID().uuidString)")
        let profile = CodexProfile(name: "Missing", slug: "missing", rootDirectory: root)

        XCTAssertTrue(SystemProfileUsageChecker().isProfileInUse(profile))
    }

    func testSystemUsageCheckerAcceptsExistingUnusedDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Unused-Usage-Check-\(UUID().uuidString)")
        let profile = CodexProfile(name: "Unused", slug: "unused", rootDirectory: root)
        try FileManager.default.createDirectory(at: profile.profileDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(SystemProfileUsageChecker().isProfileInUse(profile))
    }
}
