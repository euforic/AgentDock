import XCTest
@testable import CodexerCore

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
            .appendingPathComponent("Codexer-child-\(UUID().uuidString).pid")
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
