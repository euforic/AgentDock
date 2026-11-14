import Foundation

/// Sends one Claude HTTP request and returns its status and a size-bounded body.
/// Production uses `URLSessionClaudeHTTPTransport`; tests supply their own.
public protocol ClaudeHTTPTransport: Sendable {
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (Data, HTTPURLResponse)
}

/// An ephemeral, cookie-free, cache-free URLSession with short timeouts.
public struct URLSessionClaudeHTTPTransport: ClaudeHTTPTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    public func send(
        _ request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ClaudeUsageClientError.invalidResponse
        }
        guard response.expectedContentLength <= maximumResponseBytes else {
            throw ClaudeUsageClientError.responseTooLarge
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(Int(response.expectedContentLength))
        }
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                throw ClaudeUsageClientError.responseTooLarge
            }
            data.append(byte)
        }
        return (data, response)
    }
}

/// Builds the authenticated GET requests sent to Anthropic's OAuth API.
enum ClaudeAPIRequest {
    static func get(_ url: URL, bearer token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")
        return request
    }
}
