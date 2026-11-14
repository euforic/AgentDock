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

/// A test-only transport: records every request, answers from per-path queues
/// (optionally per bearer token), and can hold requests to chosen paths until
/// `release()`. It also records when each request started and how many were
/// in flight at once. Nothing leaves the process.
actor ScriptedClaudeTransport: ClaudeHTTPTransport {
    static let tokenPath = "/v1/oauth/token"
    static let profilePath = "/api/oauth/profile"
    static let usagePath = "/api/oauth/usage"

    struct Start: Sendable {
        var path: String
        var authorization: String?
        var at: ContinuousClock.Instant
    }

    private var queues: [String: [ScriptedReply]] = [:]
    private var heldPaths: Set<String> = []
    private var heldRequests: [CheckedContinuation<Void, Never>] = []
    private(set) var requests: [URLRequest] = []
    private(set) var starts: [Start] = []
    private var inFlight = 0
    private var inFlightByAuthorization: [String: Int] = [:]
    /// The most requests that were ever in flight at once.
    private(set) var maximumInFlight = 0
    /// The most requests with the same bearer token that were ever in flight at once.
    private(set) var maximumInFlightPerAuthorization = 0

    func enqueue(_ path: String, _ replies: ScriptedReply...) {
        queues[path, default: []].append(contentsOf: replies)
    }

    /// Replies used only for requests that carry `Bearer <token>`; they win
    /// over the path's shared queue.
    func enqueue(_ path: String, token: String, _ replies: ScriptedReply...) {
        queues[Self.queueKey(path, authorization: "Bearer \(token)"), default: []].append(contentsOf: replies)
    }

    func count(_ path: String, token: String) -> Int {
        requests.filter {
            $0.url?.path == path && $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)"
        }.count
    }

    private static func queueKey(_ path: String, authorization: String) -> String {
        "\(path)#\(authorization)"
    }

    private func begin(_ authorization: String?) {
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        if let authorization {
            let current = (inFlightByAuthorization[authorization] ?? 0) + 1
            inFlightByAuthorization[authorization] = current
            maximumInFlightPerAuthorization = max(maximumInFlightPerAuthorization, current)
        }
    }

    private func end(_ authorization: String?) {
        inFlight -= 1
        if let authorization {
            inFlightByAuthorization[authorization, default: 1] -= 1
        }
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
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        starts.append(Start(path: path, authorization: authorization, at: ContinuousClock.now))
        begin(authorization)
        defer { end(authorization) }
        if heldPaths.contains(path) {
            await withCheckedContinuation { heldRequests.append($0) }
        }
        var queueKey = path
        if let authorization, queues[Self.queueKey(path, authorization: authorization)]?.isEmpty == false {
            queueKey = Self.queueKey(path, authorization: authorization)
        }
        guard var queue = queues[queueKey], !queue.isEmpty else {
            throw URLError(.resourceUnavailable)
        }
        let reply = queue.removeFirst()
        queues[queueKey] = queue
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

/// A test-only multi-account store: one in-memory item per account key plus
/// the legacy item. Like the Keychain store, an account's item refuses another
/// account's sign-in. Each item can be told to fail its next load, save, or
/// delete, or to drop its next save so the read-back finds nothing.
final class InMemoryClaudeLoginAccounts: ClaudeLoginAccountStoring, Sendable {
    enum Item: Hashable, Sendable {
        case legacy
        case account(String)
    }

    private struct State {
        var items: [Item: ClaudeLoginTokens] = [:]
        var loadFailures: [Item: ClaudeLoginStoreError] = [:]
        var saveFailures: [Item: ClaudeLoginStoreError] = [:]
        var deleteFailures: [Item: ClaudeLoginStoreError] = [:]
        var droppedSaves: Set<Item> = []
        var listFailure: ClaudeLoginStoreError?
        var saves: [Item: Int] = [:]
        var deletes: [Item: Int] = [:]
    }

    private let state = Mutex(State())

    init(legacy: ClaudeLoginTokens? = nil, accounts: [ClaudeLoginTokens] = []) {
        state.withLock { current in
            if let legacy { current.items[.legacy] = legacy }
            for tokens in accounts { current.items[.account(tokens.accountKey)] = tokens }
        }
    }

    func tokens(_ item: Item) -> ClaudeLoginTokens? { state.withLock { $0.items[item] } }
    func saveCount(_ item: Item) -> Int { state.withLock { $0.saves[item] ?? 0 } }
    func deleteCount(_ item: Item) -> Int { state.withLock { $0.deletes[item] ?? 0 } }

    /// Every account item's key, legacy excluded, sorted.
    var storedAccountKeys: [String] {
        state.withLock { current in
            current.items.keys.compactMap { item -> String? in
                if case let .account(key) = item { return key }
                return nil
            }.sorted()
        }
    }

    func replace(_ item: Item, with tokens: ClaudeLoginTokens?) {
        state.withLock { $0.items[item] = tokens }
    }

    func failNextLoad(_ item: Item, with error: ClaudeLoginStoreError = .interactionRequired) {
        state.withLock { $0.loadFailures[item] = error }
    }

    func failNextSave(_ item: Item, with error: ClaudeLoginStoreError = .failed(-25_300)) {
        state.withLock { $0.saveFailures[item] = error }
    }

    func failNextDelete(_ item: Item, with error: ClaudeLoginStoreError = .failed(-25_300)) {
        state.withLock { $0.deleteFailures[item] = error }
    }

    func dropNextSave(_ item: Item) {
        state.withLock { _ = $0.droppedSaves.insert(item) }
    }

    func failNextList(with error: ClaudeLoginStoreError = .interactionRequired) {
        state.withLock { $0.listFailure = error }
    }

    func accountKeys(allowInteraction _: Bool) throws -> [String] {
        let failure: ClaudeLoginStoreError? = state.withLock { current in
            defer { current.listFailure = nil }
            return current.listFailure
        }
        if let failure { throw failure }
        return storedAccountKeys
    }

    func tokenStore(forAccountKey accountKey: String) -> any ClaudeLoginTokenStoring {
        InMemoryClaudeLoginItem(owner: self, item: .account(accountKey))
    }

    var legacyTokenStore: any ClaudeLoginTokenStoring {
        InMemoryClaudeLoginItem(owner: self, item: .legacy)
    }

    fileprivate func load(_ item: Item) throws -> ClaudeLoginTokens? {
        let result: Result<ClaudeLoginTokens?, ClaudeLoginStoreError> = state.withLock { current in
            if let failure = current.loadFailures.removeValue(forKey: item) { return .failure(failure) }
            guard let tokens = current.items[item] else { return .success(nil) }
            if case let .account(key) = item, tokens.accountKey != key { return .failure(.unreadable) }
            return .success(tokens)
        }
        return try result.get()
    }

    fileprivate func save(_ tokens: ClaudeLoginTokens, to item: Item) throws {
        let failure: ClaudeLoginStoreError? = state.withLock { current in
            if let failure = current.saveFailures.removeValue(forKey: item) { return failure }
            if case let .account(key) = item, tokens.accountKey != key { return .unreadable }
            current.saves[item, default: 0] += 1
            if current.droppedSaves.remove(item) == nil {
                current.items[item] = tokens
            }
            return nil
        }
        if let failure { throw failure }
    }

    fileprivate func delete(_ item: Item) throws {
        let failure: ClaudeLoginStoreError? = state.withLock { current in
            if let failure = current.deleteFailures.removeValue(forKey: item) { return failure }
            current.items[item] = nil
            current.deletes[item, default: 0] += 1
            return nil
        }
        if let failure { throw failure }
    }
}

/// One item of `InMemoryClaudeLoginAccounts`.
struct InMemoryClaudeLoginItem: ClaudeLoginTokenStoring {
    let owner: InMemoryClaudeLoginAccounts
    let item: InMemoryClaudeLoginAccounts.Item

    func load(allowInteraction _: Bool) throws -> ClaudeLoginTokens? {
        try owner.load(item)
    }

    func save(_ tokens: ClaudeLoginTokens, allowInteraction _: Bool) throws {
        try owner.save(tokens, to: item)
    }

    func delete(allowInteraction _: Bool) throws {
        try owner.delete(item)
    }
}

/// Synthetic accounts, tokens, and provider answers.
enum ClaudeLoginFixture {
    static let account = "00000000-0000-0000-0000-000000000001"
    static let organization = "00000000-0000-0000-0000-000000000002"
    static let email = "synthetic@example.invalid"

    static let secondAccount = "00000000-0000-0000-0000-000000000003"
    static let secondOrganization = "00000000-0000-0000-0000-000000000004"
    static let secondEmail = "second@example.invalid"

    static let thirdAccount = "00000000-0000-0000-0000-000000000005"
    static let thirdOrganization = "00000000-0000-0000-0000-000000000006"
    static let thirdEmail = "third@example.invalid"

    static var accountKey: String {
        ClaudeLoginAccountKey.make(accountUUID: account, organizationUUID: organization)
    }

    static var secondAccountKey: String {
        ClaudeLoginAccountKey.make(accountUUID: secondAccount, organizationUUID: secondOrganization)
    }

    static var thirdAccountKey: String {
        ClaudeLoginAccountKey.make(accountUUID: thirdAccount, organizationUUID: thirdOrganization)
    }

    static func tokens(
        access: String = "synthetic-access-a",
        refresh: String? = "synthetic-refresh-a",
        expiresAt: Date? = Date().addingTimeInterval(3_600),
        account: String = ClaudeLoginFixture.account,
        organization: String = ClaudeLoginFixture.organization,
        email: String = ClaudeLoginFixture.email,
        addedAt: Date? = nil
    ) -> ClaudeLoginTokens {
        ClaudeLoginTokens(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: expiresAt,
            scopes: ["user:profile", "user:inference"],
            accountUUID: account,
            organizationUUID: organization,
            accountLabel: email,
            subscriptionType: "max",
            addedAt: addedAt
        )
    }

    static func secondTokens(access: String = "synthetic-access-second") -> ClaudeLoginTokens {
        tokens(
            access: access,
            refresh: "synthetic-refresh-second",
            account: secondAccount,
            organization: secondOrganization,
            email: secondEmail,
            addedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
    }

    static func thirdTokens(access: String = "synthetic-access-third") -> ClaudeLoginTokens {
        tokens(
            access: access,
            refresh: "synthetic-refresh-third",
            account: thirdAccount,
            organization: thirdOrganization,
            email: thirdEmail,
            addedAt: Date(timeIntervalSince1970: 1_800_000_200)
        )
    }

    static func profileReply(account: String, organization: String, email: String) -> ScriptedReply {
        .json(200, #"""
        {"account":{"uuid":"\#(account)","email":"\#(email)"},
         "organization":{"uuid":"\#(organization)","organization_type":"claude_max"}}
        """#)
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
