import CryptoKit
import Foundation
import Security

/// Claude's public OAuth protocol for AgentDock's own sign-in. Pure request
/// building and response classification; all I/O goes through a transport.
enum ClaudeOAuth {
    /// Claude Code's public client ID. Desktop credential ranking also uses it.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizationEndpoint = URL(string: "https://claude.ai/oauth/authorize")!
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let scopes = "user:profile user:inference"
    /// What a renewal falls back to when the provider refuses to widen scopes.
    static let profileOnlyScopes = "user:profile"
    /// Only a refusal of the refresh token itself ends a sign-in.
    static let refusedRenewalCodes: Set<String> = [
        "invalid_grant",
        "refresh_token_expired",
        "refresh_token_reused",
        "refresh_token_invalidated"
    ]
    static let maximumResponseBytes = 1 * 1_024 * 1_024

    static func authorizeURL(redirectURI: String, challenge: String, state: String) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code", value: "true")
        ]
        return components?.url ?? authorizationEndpoint
    }

    /// The paste path sends the same body, including the loopback redirect URI.
    static func codeExchangeRequest(
        code: String,
        state: String,
        redirectURI: String,
        verifier: String
    ) -> URLRequest {
        tokenRequest([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "state": state,
            "redirect_uri": redirectURI,
            "code_verifier": verifier
        ])
    }

    static func refreshRequest(refreshToken: String, scope: String) -> URLRequest {
        tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "scope": scope
        ])
    }

    private static func tokenRequest(_ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try? encoder.encode(fields)
        return request
    }

    /// Reads the code from a loopback callback, or from what the user pasted:
    /// a whole callback URL, `code#state`, or a bare code (which has no state).
    static func authorizationCode(
        from input: ClaudeAuthorizationInput,
        expectedState: String
    ) throws(ClaudeSignInError) -> String {
        let parsedCode: String?
        let parsedState: String?
        switch input {
        case let .callback(value):
            return value
        case let .pasted(value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            // Only a whole URL is read for its query: `URL(string:)` also accepts
            // a bare code or `code#state` as a relative reference.
            if let url = URL(string: trimmed), url.scheme != nil, url.host != nil {
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                parsedCode = items.first { $0.name == "code" }?.value
                parsedState = items.first { $0.name == "state" }?.value
            } else if let separator = trimmed.firstIndex(of: "#") {
                parsedCode = String(trimmed[..<separator])
                parsedState = String(trimmed[trimmed.index(after: separator)...])
            } else {
                parsedCode = trimmed
                parsedState = nil
            }
        }
        guard let code = parsedCode, !code.isEmpty else { throw ClaudeSignInError.invalidCode }
        guard parsedState == expectedState else { throw ClaudeSignInError.invalidState }
        return code
    }

    /// The OAuth error code: an `error` string, `error.code`, or a top-level `code`.
    static func errorCode(_ body: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        if let error = root["error"] as? String { return error }
        if let error = root["error"] as? [String: Any], let code = error["code"] as? String {
            return code
        }
        return root["code"] as? String
    }

    /// Only an explicit refusal ends the sign-in; anything else is retried later.
    static func classifyRenewal(_ data: Data, _ response: HTTPURLResponse) -> ClaudeRenewalResult {
        if [400, 401, 403].contains(response.statusCode),
           let code = errorCode(data),
           refusedRenewalCodes.contains(code)
        {
            return .refused
        }
        guard (200..<300).contains(response.statusCode),
              let token = try? JSONDecoder().decode(ClaudeTokenResponse.self, from: data),
              !token.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .unavailable }
        return .granted(token)
    }
}

enum ClaudeAuthorizationInput: Sendable {
    case callback(String)
    case pasted(String)
}

struct ClaudeTokenResponse: Decodable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Double?
    var scope: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
    }
}

enum ClaudeRenewalResult: Equatable, Sendable {
    case granted(ClaudeTokenResponse)
    case refused
    case unavailable
}

/// RFC 7636 proof key with the S256 method.
enum ClaudePKCE {
    static func generate() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        if status != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        let verifier = base64URL(Data(bytes))
        return (verifier, challenge(for: verifier))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
