import Foundation
import XCTest
@testable import AgentDockCore

/// Uses a real listener on 127.0.0.1 and URLSession to it; nothing reaches the internet.
final class ClaudeLoopbackCallbackServerTests: XCTestCase {
    func testCallbackRejectsStateMismatchAndKeepsWaiting() async throws {
        let server = try await ClaudeLoopbackCallbackServer.start(expectedState: "s")
        defer { server.cancel() }
        let port = server.port
        XCTAssertGreaterThan(port, 0)
        XCTAssertEqual(server.redirectURI, "http://localhost:\(port)/callback")
        let waiter = Task { try await server.waitForCode() }

        let mismatch = try await status("/callback?code=c&state=wrong", port: port)
        let favicon = try await status("/favicon.ico", port: port)
        let post = try await status("/callback?code=c&state=s", port: port, method: "POST")
        XCTAssertEqual(mismatch, 400)
        XCTAssertEqual(favicon, 404)
        XCTAssertEqual(post, 405)

        let accepted = try await status("/callback?code=c&state=s", port: port)
        XCTAssertEqual(accepted, 200)
        let code = try await waiter.value
        XCTAssertEqual(code, "c")
    }

    func testCallbackErrorParameterFails() async throws {
        let server = try await ClaudeLoopbackCallbackServer.start(expectedState: "s")
        defer { server.cancel() }
        let waiter = Task { try await server.waitForCode() }

        let rejected = try await status("/callback?error=access_denied&state=s", port: server.port)
        XCTAssertEqual(rejected, 400)
        do {
            _ = try await waiter.value
            XCTFail("Expected the authorization error")
        } catch {
            XCTAssertEqual(error as? ClaudeSignInError, .authorizationFailed("access_denied"))
        }
    }

    func testCancelResumesWaiter() async throws {
        let server = try await ClaudeLoopbackCallbackServer.start(expectedState: "s")
        let waiter = Task { try await server.waitForCode() }
        try await Task.sleep(for: .milliseconds(50))
        server.cancel()
        do {
            _ = try await waiter.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? ClaudeSignInError, .cancelled)
        }

        // Cancelling the waiting task also ends the wait.
        let other = try await ClaudeLoopbackCallbackServer.start(expectedState: "s")
        defer { other.cancel() }
        let cancelled = Task { try await other.waitForCode() }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? ClaudeSignInError, .cancelled)
        }
    }

    private func status(_ target: String, port: UInt16, method: String = "GET") async throws -> Int {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(target)")))
        request.httpMethod = method
        request.timeoutInterval = 5
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }
}
