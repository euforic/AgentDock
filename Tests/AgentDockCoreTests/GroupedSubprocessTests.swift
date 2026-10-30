import Darwin
import XCTest
@testable import AgentDockCore

final class GroupedSubprocessTests: XCTestCase {
    func testWritingAfterChildExitThrowsWithoutTerminatingTheParent() throws {
        let process = try GroupedSubprocess(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            environment: [:]
        )
        defer { process.terminateAndWait() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while process.isRunning, ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertFalse(process.isRunning)
        // Assert descriptor policy even if the test host happens to ignore SIGPIPE.
        XCTAssertEqual(fcntl(process.standardInput.fileDescriptor, F_GETNOSIGPIPE), 1)
        XCTAssertThrowsError(try process.standardInput.write(contentsOf: Data("request\n".utf8)))
    }

    func testConcurrentSessionDoesNotInheritAnotherSessionsPipes() throws {
        let first = try GroupedSubprocess(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            environment: [:]
        )
        defer { first.terminateAndWait() }
        let probe = try GroupedSubprocess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "test -e /dev/fd/\(first.standardInput.fileDescriptor) && printf leaked || printf closed"
            ],
            environment: [:]
        )
        defer { probe.terminateAndWait() }

        let output = probe.standardOutput.readDataToEndOfFile()
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "closed")
    }
}
