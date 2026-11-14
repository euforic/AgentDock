import Foundation
import Synchronization
@testable import AgentDockCore

/// One scripted HTTP answer, or a thrown transport error.
struct ScriptedReply: Sendable {
    var status: Int
    var body: String
    var headers: [String: String] = [:]
    var failure: URLError.Code?

    static func json(_ status: Int, _ body: String, headers: [String: String] = [:]) -> Self {
        ScriptedReply(status: status, body: body, headers: headers)
    }

    static func failure(_ code: URLError.Code = .notConnectedToInternet) -> Self {
        ScriptedReply(status: 0, body: "", failure: code)
    }
}

/// A test-only transport: records every request, answers from per-path queues,
/// and can hold requests to chosen paths until `release()`. Nothing leaves the process.
actor ScriptedClaudeTransport: ClaudeHTTPTransport {
    static let tokenPath = "/v1/oauth/token"
    static let profilePath = "/api/oauth/profile"
    static let usagePath = "/api/oauth/usage"

    private var queues: [String: [ScriptedReply]] = [:]
    private var heldPaths: Set<String> = []
    private var heldRequests: [CheckedContinuation<Void, Never>] = []
    private(set) var requests: [URLRequest] = []

    func enqueue(_ path: String, _ replies: ScriptedReply...) {
        queues[path, default: []].append(contentsOf: replies)
    }

    func hold(_ path: String) {
        heldPaths.insert(path)
    }

    func release() {
        heldPaths.removeAll()
        let waiting = heldRequests
        heldRequests.removeAll()
        waiting.forEach { $0.resume() }
    }

    var heldCount: Int { heldRequests.count }

    var paths: [String] { requests.map { $0.url?.path ?? "" } }

    func count(_ path: String) -> Int {
        paths.filter { $0 == path }.count
    }

    /// The decoded JSON bodies sent to `path`, in order.
    func bodies(_ path: String) -> [[String: String]] {
        requests
            .filter { $0.url?.path == path }
            .compactMap { request in
                request.httpBody.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
            }
    }

    func send(_ request: URLRequest, maximumResponseBytes _: Int) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url?.path ?? ""
        if heldPaths.contains(path) {
            await withCheckedContinuation { heldRequests.append($0) }
        }
        guard var queue = queues[path], !queue.isEmpty else {
            throw URLError(.resourceUnavailable)
        }
        let reply = queue.removeFirst()
        queues[path] = queue
        if let failure = reply.failure { throw URLError(failure) }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://invalid.example")!,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: reply.headers
        )!
        return (Data(reply.body.utf8), response)
    }
}

/// A test-only token store that can be told to fail its next save or load.
final class InMemoryClaudeLoginStore: ClaudeLoginTokenStoring, Sendable {
    private struct State {
        var tokens: ClaudeLoginTokens?
        var saveFailure: ClaudeLoginStoreError?
        var loadFailure: ClaudeLoginStoreError?
        var saves = 0
        var deletes = 0
    }

    private let state: Mutex<State>

    init(_ tokens: ClaudeLoginTokens? = nil) {
        state = Mutex(State(tokens: tokens))
    }

    var tokens: ClaudeLoginTokens? { state.withLock { $0.tokens } }
    var saveCount: Int { state.withLock { $0.saves } }
    var deleteCount: Int { state.withLock { $0.deletes } }

    func replace(_ tokens: ClaudeLoginTokens?) {
        state.withLock { $0.tokens = tokens }
    }

    func failNextSave(with error: ClaudeLoginStoreError = .interactionRequired) {
        state.withLock { $0.saveFailure = error }
    }

    func failNextLoad(with error: ClaudeLoginStoreError = .interactionRequired) {
        state.withLock { $0.loadFailure = error }
    }

    func load(allowInteraction _: Bool) throws -> ClaudeLoginTokens? {
        let result: Result<ClaudeLoginTokens?, ClaudeLoginStoreError> = state.withLock { current in
            if let failure = current.loadFailure {
                current.loadFailure = nil
                return .failure(failure)
            }
            return .success(current.tokens)
        }
        return try result.get()
    }

    func save(_ tokens: ClaudeLoginTokens, allowInteraction _: Bool) throws {
        let failure: ClaudeLoginStoreError? = state.withLock { current in
            if let failure = current.saveFailure {
                current.saveFailure = nil
                return failure
            }
            current.tokens = tokens
            current.saves += 1
            return nil
        }
        if let failure { throw failure }
    }

    func delete(allowInteraction _: Bool) throws {
        state.withLock { current in
            current.tokens = nil
            current.deletes += 1
        }
    }
}

/// Synthetic accounts, tokens, and provider answers.
enum ClaudeLoginFixture {
    static let account = "00000000-0000-0000-0000-000000000001"
    static let organization = "00000000-0000-0000-0000-000000000002"
    static let email = "synthetic@example.invalid"

    static func tokens(
        access: String = "synthetic-access-a",
        refresh: String? = "synthetic-refresh-a",
        expiresAt: Date? = Date().addingTimeInterval(3_600)
    ) -> ClaudeLoginTokens {
        ClaudeLoginTokens(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: expiresAt,
            scopes: ["user:profile", "user:inference"],
            accountUUID: account,
            organizationUUID: organization,
            accountLabel: email,
            subscriptionType: "max"
        )
    }

    static func tokenReply(
        access: String,
        refresh: String? = nil,
        expiresIn: Int = 3_600,
        scope: String? = nil
    ) -> ScriptedReply {
        var fields: [String: Any] = ["access_token": access, "expires_in": expiresIn, "token_type": "Bearer"]
        if let refresh { fields["refresh_token"] = refresh }
        if let scope { fields["scope"] = scope }
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return .json(200, String(decoding: data, as: UTF8.self))
    }

    static func errorReply(_ status: Int, _ code: String) -> ScriptedReply {
        .json(status, #"{"error":"\#(code)"}"#)
    }

    static let profileReply = ScriptedReply.json(200, #"""
    {"account":{"uuid":"\#(account)","email":"\#(email)"},
     "organization":{"uuid":"\#(organization)","organization_type":"claude_max"}}
    """#)

    static let usageReply = ScriptedReply.json(200, #"""
    {"five_hour":{"utilization":12.5,"resets_at":"2099-01-01T05:00:00.000Z"},
     "seven_day":{"utilization":41,"resets_at":"2099-01-07T00:00:00Z"}}
    """#)
}

/// Polls an async condition until it holds or two seconds pass.
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
