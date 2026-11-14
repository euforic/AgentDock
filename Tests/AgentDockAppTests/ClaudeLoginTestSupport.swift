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

/// A test-only sign-in store built from one in-memory item per profile, plus
/// the items earlier versions wrote (per account key, and the legacy item),
/// so test models never touch the developer's Keychain.
final class InMemoryClaudeLoginAccounts: ClaudeLoginAccountStoring, Sendable {
    private let items: Mutex<[String: InMemoryClaudeLoginStore]>
    private let profileItems: Mutex<[ClaudeCodeProfileID: InMemoryClaudeLoginStore]>
    private let legacy: InMemoryClaudeLoginStore

    init(
        _ accounts: [ClaudeLoginTokens] = [],
        legacy: ClaudeLoginTokens? = nil,
        profiles: [ClaudeCodeProfileID: ClaudeLoginTokens] = [:]
    ) {
        var stores: [String: InMemoryClaudeLoginStore] = [:]
        for tokens in accounts {
            stores[tokens.accountKey] = InMemoryClaudeLoginStore(tokens)
        }
        items = Mutex(stores)
        profileItems = Mutex(profiles.mapValues { InMemoryClaudeLoginStore($0) })
        self.legacy = InMemoryClaudeLoginStore(legacy)
    }

    func tokens(forAccountKey accountKey: String) -> ClaudeLoginTokens? {
        items.withLock { $0[accountKey]?.tokens }
    }

    func tokens(forProfile profile: ClaudeCodeProfileID) -> ClaudeLoginTokens? {
        profileItems.withLock { $0[profile]?.tokens }
    }

    var legacyTokens: ClaudeLoginTokens? { legacy.tokens }

    func accountKeys(allowInteraction _: Bool) throws -> [String] {
        items.withLock { stores in
            stores.filter { $0.value.tokens != nil }.keys.sorted()
        }
    }

    func profileIDs(allowInteraction _: Bool) throws -> [ClaudeCodeProfileID] {
        profileItems.withLock { stores in
            stores.filter { $0.value.tokens != nil }.keys.sorted { $0.storageKey < $1.storageKey }
        }
    }

    func tokenStore(forProfile profile: ClaudeCodeProfileID) -> any ClaudeLoginTokenStoring {
        profileItems.withLock { stores in
            if let existing = stores[profile] { return existing }
            let created = InMemoryClaudeLoginStore()
            stores[profile] = created
            return created
        }
    }

    func tokenStore(forAccountKey accountKey: String) -> any ClaudeLoginTokenStoring {
        items.withLock { stores in
            if let existing = stores[accountKey] { return existing }
            let created = InMemoryClaudeLoginStore()
            stores[accountKey] = created
            return created
        }
    }

    var legacyTokenStore: any ClaudeLoginTokenStoring { legacy }
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
