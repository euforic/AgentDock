import Foundation
import Synchronization
@testable import AgentDockCore

/// A test-only token store, so test models never touch the developer's Keychain.
final class InMemoryClaudeLoginStore: ClaudeLoginTokenStoring, Sendable {
    private let state: Mutex<ClaudeLoginTokens?>

    init(_ tokens: ClaudeLoginTokens? = nil) {
        state = Mutex(tokens)
    }

    var tokens: ClaudeLoginTokens? { state.withLock { $0 } }

    func load(allowInteraction _: Bool) throws -> ClaudeLoginTokens? {
        state.withLock { $0 }
    }

    func save(_ tokens: ClaudeLoginTokens, allowInteraction _: Bool) throws {
        state.withLock { $0 = tokens }
    }

    func delete(allowInteraction _: Bool) throws {
        state.withLock { $0 = nil }
    }
}

/// A test-only transport that answers from per-path queues and records requests.
actor AppScriptedClaudeTransport: ClaudeHTTPTransport {
    private var queues: [String: [(status: Int, body: String)]] = [:]
    private(set) var requests: [URLRequest] = []

    func enqueue(_ path: String, status: Int, body: String) {
        queues[path, default: []].append((status, body))
    }

    func send(_ request: URLRequest, maximumResponseBytes _: Int) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url?.path ?? ""
        guard var queue = queues[path], !queue.isEmpty else {
            throw URLError(.resourceUnavailable)
        }
        let reply = queue.removeFirst()
        queues[path] = queue
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://invalid.example")!,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (Data(reply.body.utf8), response)
    }
}
