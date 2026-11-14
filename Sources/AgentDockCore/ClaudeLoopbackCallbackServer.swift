import Foundation
import Network
import Synchronization

/// A one-shot HTTP listener on 127.0.0.1 that receives the OAuth redirect.
/// Requests with the wrong method, path, or `state` are answered and ignored;
/// the first matching callback finishes the wait exactly once.
final class ClaudeLoopbackCallbackServer: Sendable {
    static let callbackPath = "/callback"
    static let headerLimit = 16 * 1_024
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    private struct State {
        var port: UInt16 = 0
        var readiness: CheckedContinuation<Result<UInt16, ClaudeSignInError>, Never>?
        var outcome: Result<String, ClaudeSignInError>?
        var waiter: CheckedContinuation<Result<String, ClaudeSignInError>, Never>?
    }

    private let listener: NWListener
    private let expectedState: String
    private let queue = DispatchQueue(label: "dev.euforic.agentdock.claude-sign-in-callback")
    private let state = Mutex(State())

    private init(listener: NWListener, expectedState: String) {
        self.listener = listener
        self.expectedState = expectedState
    }

    deinit {
        listener.cancel()
    }

    /// Binds to the loopback interface on a system-assigned port.
    static func start(expectedState: String) async throws(ClaudeSignInError) -> ClaudeLoopbackCallbackServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else {
            throw ClaudeSignInError.listenerFailed
        }
        let server = ClaudeLoopbackCallbackServer(listener: listener, expectedState: expectedState)
        let ready: Result<UInt16, ClaudeSignInError> = await withCheckedContinuation { continuation in
            server.begin(readiness: continuation)
        }
        switch ready {
        case .success:
            return server
        case let .failure(error):
            server.cancel()
            throw error
        }
    }

    var port: UInt16 {
        state.withLock { $0.port }
    }

    /// The spelling registered for Claude's public client.
    var redirectURI: String {
        "http://localhost:\(port)\(Self.callbackPath)"
    }

    func waitForCode() async throws(ClaudeSignInError) -> String {
        let result: Result<String, ClaudeSignInError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: Result<String, ClaudeSignInError>? = self.state.withLock { current in
                    if let outcome = current.outcome { return outcome }
                    if current.waiter != nil { return .failure(.alreadyInProgress) }
                    current.waiter = continuation
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            self.cancel()
        }
        switch result {
        case let .success(code): return code
        case let .failure(error): throw error
        }
    }

    /// Ends any wait with `.cancelled` and stops listening.
    func cancel() {
        finish(.failure(.cancelled))
        resolveReadiness(.failure(.cancelled))
        listener.cancel()
    }

    // MARK: - Listener

    private func begin(readiness: CheckedContinuation<Result<UInt16, ClaudeSignInError>, Never>) {
        state.withLock { $0.readiness = readiness }
        listener.stateUpdateHandler = { [weak self] newState in
            self?.listenerStateChanged(newState)
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.accept(connection)
        }
        listener.start(queue: queue)
    }

    private func listenerStateChanged(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            guard let port = listener.port?.rawValue, port != 0 else {
                resolveReadiness(.failure(.listenerFailed))
                listener.cancel()
                return
            }
            state.withLock { $0.port = port }
            resolveReadiness(.success(port))
        case .failed:
            resolveReadiness(.failure(.listenerFailed))
            finish(.failure(.listenerFailed))
            listener.cancel()
        case .cancelled:
            resolveReadiness(.failure(.cancelled))
            finish(.failure(.cancelled))
        default:
            break
        }
    }

    private func resolveReadiness(_ result: Result<UInt16, ClaudeSignInError>) {
        let pending: CheckedContinuation<Result<UInt16, ClaudeSignInError>, Never>? = state.withLock { current in
            let continuation = current.readiness
            current.readiness = nil
            return continuation
        }
        pending?.resume(returning: result)
    }

    private func finish(_ result: Result<String, ClaudeSignInError>) {
        let pending: CheckedContinuation<Result<String, ClaudeSignInError>, Never>? = state.withLock { current in
            guard current.outcome == nil else { return nil }
            current.outcome = result
            let continuation = current.waiter
            current.waiter = nil
            return continuation
        }
        pending?.resume(returning: result)
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffered: Data())
    }

    /// Buffers the request head until its terminator arrives, up to 16 KiB.
    private func receive(on connection: NWConnection, buffered: Data) {
        let remaining = max(1, Self.headerLimit - buffered.count)
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var received = buffered
            if let data { received.append(data) }
            if let end = received.range(of: Self.headerTerminator) {
                self.handle(head: received[..<end.lowerBound], on: connection)
            } else if error == nil, !isComplete, received.count < Self.headerLimit {
                self.receive(on: connection, buffered: received)
            } else {
                self.reply(on: connection, status: 400, body: "The sign-in request was incomplete.")
            }
        }
    }

    private func handle(head: Data, on connection: NWConnection) {
        let text = String(decoding: head, as: UTF8.self)
        let requestLine = text.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "GET" else {
            reply(on: connection, status: 405, body: "Only GET is supported.")
            return
        }
        guard let components = URLComponents(string: String(parts[1])),
              components.path == Self.callbackPath
        else {
            reply(on: connection, status: 404, body: "Not found.")
            return
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard value("state") == expectedState else {
            reply(on: connection, status: 400, body: "Sign-in state did not match.")
            return
        }
        if let error = value("error") {
            finish(.failure(.authorizationFailed(String(error.prefix(100)))))
            reply(
                on: connection,
                status: 400,
                body: "Sign-in was not completed. You can close this tab and return to AgentDock.",
                closesListener: true
            )
            return
        }
        guard let code = value("code"), !code.isEmpty else {
            finish(.failure(.invalidCallback))
            reply(
                on: connection,
                status: 400,
                body: "The sign-in response was incomplete. You can close this tab and return to AgentDock.",
                closesListener: true
            )
            return
        }
        finish(.success(code))
        reply(
            on: connection,
            status: 200,
            body: "Sign-in complete. You can close this tab and return to AgentDock.",
            closesListener: true
        )
    }

    /// Bodies are fixed text; nothing from the request is reflected.
    private func reply(
        on connection: NWConnection,
        status: Int,
        body: String,
        closesListener: Bool = false
    ) {
        let reason = switch status {
        case 200: "OK"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        default: "Bad Request"
        }
        let page = Data(
            "<!doctype html><html><head><meta charset=\"utf-8\"><title>AgentDock</title></head><body><p>\(body)</p></body></html>".utf8
        )
        let head = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(page.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + page, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            if closesListener { self?.listener.cancel() }
        })
    }
}
