import Foundation
import XCTest
@testable import AgentDockCore

final class ClaudeOAuthTests: XCTestCase {
    func testPKCEVerifierIsBase64URLAndUnique() {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var verifiers: Set<String> = []
        for _ in 0..<32 {
            let pair = ClaudePKCE.generate()
            XCTAssertEqual(pair.verifier.count, 43)
            XCTAssertTrue(pair.verifier.allSatisfy(allowed.contains))
            XCTAssertFalse(pair.verifier.contains("="))
            XCTAssertEqual(pair.challenge, ClaudePKCE.challenge(for: pair.verifier))
            verifiers.insert(pair.verifier)
        }
        XCTAssertEqual(verifiers.count, 32)
    }

    func testPKCEChallengeMatchesRFC7636AppendixB() {
        XCTAssertEqual(
            ClaudePKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testAuthorizeURLQueryItems() throws {
        let url = ClaudeOAuth.authorizeURL(
            redirectURI: "http://localhost:54321/callback",
            challenge: "synthetic-challenge",
            state: "synthetic-state"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "claude.ai")
        XCTAssertEqual(components.path, "/oauth/authorize")
        let items = try XCTUnwrap(components.queryItems)
        XCTAssertEqual(items.map(\.name), [
            "client_id", "response_type", "redirect_uri", "scope",
            "code_challenge", "code_challenge_method", "state", "code"
        ])
        XCTAssertEqual(items.map(\.value), [
            "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            "code",
            "http://localhost:54321/callback",
            "user:profile user:inference",
            "synthetic-challenge",
            "S256",
            "synthetic-state",
            "true"
        ])
    }

    func testAuthorizationCodeExchangeRequest() throws {
        let request = ClaudeOAuth.codeExchangeRequest(
            code: "synthetic-code",
            state: "synthetic-state",
            redirectURI: "http://localhost:54321/callback",
            verifier: "synthetic-verifier"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, URL(string: "https://platform.claude.com/v1/oauth/token"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try JSONDecoder().decode([String: String].self, from: try XCTUnwrap(request.httpBody))
        XCTAssertEqual(body, [
            "grant_type": "authorization_code",
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            "code": "synthetic-code",
            "state": "synthetic-state",
            "redirect_uri": "http://localhost:54321/callback",
            "code_verifier": "synthetic-verifier"
        ])
    }

    func testRefreshRequestBody() throws {
        let request = ClaudeOAuth.refreshRequest(
            refreshToken: "synthetic-refresh",
            scope: ClaudeOAuth.scopes
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, ClaudeOAuth.tokenURL)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try JSONDecoder().decode([String: String].self, from: try XCTUnwrap(request.httpBody))
        XCTAssertEqual(body, [
            "grant_type": "refresh_token",
            "refresh_token": "synthetic-refresh",
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            "scope": "user:profile user:inference"
        ])
    }

    func testPastedCodeParsing() {
        func parse(_ value: String) -> Result<String, ClaudeSignInError> {
            Result { () throws(ClaudeSignInError) -> String in
                try ClaudeOAuth.authorizationCode(from: .pasted(value), expectedState: "s")
            }
        }

        XCTAssertEqual(parse("c#s"), .success("c"))
        XCTAssertEqual(parse("http://localhost:54321/callback?code=c&state=s"), .success("c"))
        XCTAssertEqual(parse("  c#s \n"), .success("c"))
        XCTAssertEqual(parse("c#x"), .failure(.invalidState))
        XCTAssertEqual(parse("c"), .failure(.invalidState))
        XCTAssertEqual(parse(""), .failure(.invalidCode))
        XCTAssertEqual(parse("#s"), .failure(.invalidCode))
        XCTAssertEqual(
            Result { () throws(ClaudeSignInError) -> String in
                try ClaudeOAuth.authorizationCode(from: .callback("c"), expectedState: "s")
            },
            .success("c")
        )
    }

    func testRenewalClassification() throws {
        func classify(_ status: Int, _ body: String) throws -> ClaudeRenewalResult {
            let response = try XCTUnwrap(HTTPURLResponse(
                url: ClaudeOAuth.tokenURL,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            ))
            return ClaudeOAuth.classifyRenewal(Data(body.utf8), response)
        }

        XCTAssertEqual(
            try classify(200, #"{"access_token":"synthetic-access","expires_in":3600}"#),
            .granted(ClaudeTokenResponse(
                accessToken: "synthetic-access",
                refreshToken: nil,
                expiresIn: 3_600,
                scope: nil
            ))
        )
        XCTAssertEqual(try classify(200, #"{"access_token":""}"#), .unavailable)
        XCTAssertEqual(try classify(200, "not json"), .unavailable)
        XCTAssertEqual(try classify(400, #"{"error":"invalid_grant"}"#), .refused)
        XCTAssertEqual(try classify(401, #"{"error":"refresh_token_expired"}"#), .refused)
        XCTAssertEqual(try classify(400, #"{"error":{"code":"refresh_token_reused"}}"#), .refused)
        XCTAssertEqual(try classify(403, #"{"code":"refresh_token_invalidated"}"#), .refused)
        XCTAssertEqual(try classify(400, #"{"error":"invalid_request"}"#), .unavailable)
        XCTAssertEqual(try classify(429, #"{"error":"invalid_grant"}"#), .unavailable)
        XCTAssertEqual(try classify(503, ""), .unavailable)
    }
}
