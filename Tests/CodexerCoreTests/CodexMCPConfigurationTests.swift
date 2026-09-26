import XCTest
@testable import CodexerCore

final class CodexMCPConfigurationTests: XCTestCase {
    func testInstalledCodexCLIUsesSupportedBundleLayout() throws {
        let appURL = URL(fileURLWithPath: "/Applications/Codex.app")
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw XCTSkip("Codex.app is not installed")
        }

        let resolved = CodexBundledCLI.executableURL(for: appURL)
        let current = appURL.appendingPathComponent(
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        )
        let legacy = appURL.appendingPathComponent("Contents/Resources/codex")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: resolved.path))
        if FileManager.default.isExecutableFile(atPath: current.path) {
            XCTAssertEqual(resolved, current)
        } else {
            XCTAssertEqual(resolved, legacy)
        }
    }

    func testConfiguredContentPreservesUnrelatedAndNestedSettings() throws {
        let existing = """
        model = "gpt-test"

        [mcp_servers.example]
        mcp_oauth_callback_port = 49999
        url = "https://example.test/mcp"
        """

        let updated = try CodexMCPConfiguration.configuredContent(
            existing,
            callbackPort: 49_152
        )

        XCTAssertTrue(updated.hasPrefix(
            """
            # Codexer MCP OAuth isolation v1
            mcp_oauth_callback_port = 49152
            mcp_oauth_credentials_store = "keyring"

            model = "gpt-test"

            [mcp_servers.example]
            """
        ))
        XCTAssertTrue(updated.contains("mcp_oauth_callback_port = 49999"))
        XCTAssertTrue(updated.contains(#"url = "https://example.test/mcp""#))
        XCTAssertTrue(updated.contains("[features]\nsecret_auth_storage = true"))
    }

    func testConfiguredContentUpdatesManagedTopLevelSettings() throws {
        let existing = """
        mcp_oauth_callback_port = 40000 # old
        mcp_oauth_credentials_store = "file"
        model = "gpt-test"
        """

        let updated = try CodexMCPConfiguration.configuredContent(
            existing,
            callbackPort: 49_153
        )

        XCTAssertTrue(updated.contains("mcp_oauth_callback_port = 49153"))
        XCTAssertTrue(updated.contains(#"mcp_oauth_credentials_store = "keyring""#))
        XCTAssertFalse(updated.contains("40000"))
        XCTAssertFalse(updated.contains(#""file""#))
        XCTAssertTrue(updated.contains(#"model = "gpt-test""#))
    }

    func testDuplicateManagedTopLevelSettingIsRejected() {
        let existing = """
        mcp_oauth_callback_port = 49152
        mcp_oauth_callback_port = 49153
        """

        XCTAssertThrowsError(
            try CodexMCPConfiguration.configuredContent(
                existing,
                callbackPort: 49_154
            )
        ) { error in
            XCTAssertEqual(
                error as? CodexMCPConfigurationError,
                .duplicateTopLevelKey("mcp_oauth_callback_port")
            )
        }
    }

    func testConfigureWritesPrivateValidatedConfig() throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMCPConfig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try FileManager.default.createDirectory(
            at: codexHome,
            withIntermediateDirectories: true
        )

        try CodexMCPConfiguration.configure(
            codexHomeURL: codexHome,
            callbackPort: 49_152
        )
        try CodexMCPConfiguration.validate(
            codexHomeURL: codexHome,
            expectedCallbackPort: 49_152
        )

        let attributes = try FileManager.default.attributesOfItem(
            atPath: codexHome.appendingPathComponent("config.toml").path
        )
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600)
    }

    func testBundledValidationHomeExposesConfigWithoutProfileCredentials() throws {
        let fileManager = FileManager.default
        let codexHome = fileManager.temporaryDirectory
            .appendingPathComponent("CodexMCPConfig-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: codexHome) }
        try fileManager.createDirectory(
            at: codexHome,
            withIntermediateDirectories: true
        )
        let configURL = codexHome.appendingPathComponent("config.toml")
        try Data("[features]\nsecret_auth_storage = true\n".utf8).write(to: configURL)
        try Data("synthetic-auth-state".utf8).write(
            to: codexHome.appendingPathComponent("auth.json")
        )

        let validationHome = try CodexMCPConfiguration.makeIsolatedValidationHome(
            codexHomeURL: codexHome,
            fileManager: fileManager
        )
        defer { try? fileManager.removeItem(at: validationHome) }

        let linkedConfig = validationHome.appendingPathComponent("config.toml")
        let values = try linkedConfig.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(values.isSymbolicLink, true)
        XCTAssertEqual(
            try String(contentsOf: linkedConfig, encoding: .utf8),
            "[features]\nsecret_auth_storage = true\n"
        )
        XCTAssertFalse(fileManager.fileExists(
            atPath: validationHome.appendingPathComponent("auth.json").path
        ))
        let attributes = try fileManager.attributesOfItem(atPath: validationHome.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o700)
    }

    func testConfiguredContentPreservesCRLFAndIgnoresTablesInsideMultilineStrings() throws {
        let existing = [
            "description = \"\"\"",
            "[features]",
            "secret_auth_storage = false",
            "\"\"\"",
            "",
            "[features]",
            "plugins = true"
        ].joined(separator: "\r\n")

        let updated = try CodexMCPConfiguration.configuredContent(
            existing,
            callbackPort: 49_152
        )

        XCTAssertTrue(updated.contains(
            "[features]\r\nsecret_auth_storage = false\r\n\"\"\""
        ))
        XCTAssertTrue(updated.contains(
            "[features]\r\nplugins = true\r\nsecret_auth_storage = true"
        ))
        XCTAssertFalse(updated.hasSuffix("\r\n"))
        XCTAssertFalse(
            updated.replacingOccurrences(of: "\r\n", with: "").contains("\n")
        )
    }
}
