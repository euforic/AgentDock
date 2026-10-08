import XCTest
@testable import CodexerCore

final class CodexConfigProfileTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexConfigProfileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testProfileNamesMatchCodexCLIContract() throws {
        XCTAssertEqual(try CodexConfigProfile(validating: "ollama-local").name, "ollama-local")
        XCTAssertEqual(try CodexConfigProfile(validating: "work_2").name, "work_2")
        XCTAssertThrowsError(try CodexConfigProfile(validating: ""))
        XCTAssertThrowsError(try CodexConfigProfile(validating: "../unsafe"))
        XCTAssertThrowsError(try CodexConfigProfile(validating: "has spaces"))
    }

    func testDiscoveryFindsOnlySafeNamedConfigFiles() throws {
        try Data("model_provider = \"ollama\"\n".utf8)
            .write(to: root.appendingPathComponent("ollama.config.toml"))
        try Data("model = \"gpt-test\"\n".utf8)
            .write(to: root.appendingPathComponent("deep-review.config.toml"))
        try Data("model = \"base\"\n".utf8)
            .write(to: root.appendingPathComponent("config.toml"))
        try Data("ignored\n".utf8)
            .write(to: root.appendingPathComponent("notes.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.config.toml"),
            withDestinationURL: root.appendingPathComponent("ollama.config.toml")
        )

        XCTAssertEqual(
            CodexConfigProfile.discover(in: root).map(\.name),
            ["deep-review", "ollama"]
        )
    }

    func testSelectionRoundTripsThroughProfileMetadata() throws {
        let configProfile = try CodexConfigProfile(validating: "ollama")
        let profile = CodexProfile(
            name: "Local",
            slug: "local",
            rootDirectory: root,
            codexLaunchProfileSelection: .named(configProfile),
            codexDefaultConfigProfile: configProfile
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(CodexProfile.self, from: data)

        XCTAssertEqual(decoded.codexLaunchProfileSelection, .named(configProfile))
        XCTAssertEqual(decoded.codexDefaultConfigProfile, configProfile)
    }

    func testDesktopOverridesPreserveProfileTablesAndMultilineValues() throws {
        try Data(#"""
        model_provider = "ollama"
        tools = [
          "shell",
          "search", # retained as values without comments
        ]

        [model_providers.ollama]
        name = "Ollama"
        base_url = "http://127.0.0.1:11434/v1"
        """#.utf8).write(to: root.appendingPathComponent("ollama.config.toml"))
        let configProfile = try CodexConfigProfile(validating: "ollama")

        XCTAssertEqual(
            try configProfile.appServerConfigOverrides(in: root),
            [
                "model_provider=\"ollama\"",
                "tools=[\n  \"shell\",\n  \"search\", \n]",
                "model_providers.ollama.name=\"Ollama\"",
                "model_providers.ollama.base_url=\"http://127.0.0.1:11434/v1\""
            ]
        )
    }

    func testDesktopProxyUsesConfigOverridesAcceptedByAppServer() throws {
        let executableURL = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")

        XCTAssertEqual(
            CodexCLIProfileProxy.forwardedArguments(
                executableURL: executableURL,
                configOverrides: [
                    "model_provider=\"cursor_bridge\"",
                    "model=\"synthetic-model\""
                ],
                incomingArguments: ["app-server", "--analytics-default-enabled"]
            ),
            [
                executableURL.path,
                "--config", "model_provider=\"cursor_bridge\"",
                "--config", "model=\"synthetic-model\"",
                "app-server", "--analytics-default-enabled"
            ]
        )
    }

    func testDiscoveryStaysInsideCurrentManagedProfile() throws {
        let otherRoot = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        try Data("model_provider = \"ollama\"\n".utf8)
            .write(to: root.appendingPathComponent("ollama.config.toml"))
        try Data("model_provider = \"cursor_bridge\"\n".utf8)
            .write(to: otherRoot.appendingPathComponent("cursor-bridge.config.toml"))

        XCTAssertEqual(CodexConfigProfile.discover(in: root).map(\.name), ["ollama"])
        XCTAssertEqual(CodexConfigProfile.discover(in: otherRoot).map(\.name), ["cursor-bridge"])
    }

    func testDesktopOverridesRejectArrayTables() throws {
        try Data("[[agents]]\nname = \"reviewer\"\n".utf8)
            .write(to: root.appendingPathComponent("review.config.toml"))
        let configProfile = try CodexConfigProfile(validating: "review")

        XCTAssertThrowsError(try configProfile.appServerConfigOverrides(in: root)) { error in
            XCTAssertEqual(error as? CodexConfigProfileError, .unsupportedArrayTable)
        }
    }

    func testDesktopOverridesRejectCredentialValuesInProcessArguments() throws {
        try Data(#"""
        [model_providers.private]
        experimental_bearer_token = "synthetic-secret"
        """#.utf8).write(to: root.appendingPathComponent("private.config.toml"))
        let configProfile = try CodexConfigProfile(validating: "private")

        XCTAssertThrowsError(try configProfile.appServerConfigOverrides(in: root)) { error in
            XCTAssertEqual(
                error as? CodexConfigProfileError,
                .sensitiveSetting("model_providers.private.experimental_bearer_token")
            )
        }
    }

    func testInstalledAppServerAcceptsSelectedProfileOverridesWhenEnabled() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let homePath = environment["AGENTDOCK_INSTALLED_CONFIG_PROFILE_HOME"],
              let profileName = environment["AGENTDOCK_INSTALLED_CONFIG_PROFILE_NAME"]
        else {
            throw XCTSkip(
                "Set AGENTDOCK_INSTALLED_CONFIG_PROFILE_HOME and AGENTDOCK_INSTALLED_CONFIG_PROFILE_NAME to validate an installed profile."
            )
        }
        let executableURL = CodexBundledCLI.executableURL(
            for: URL(fileURLWithPath: "/Applications/Codex.app")
        )
        let profile = try CodexConfigProfile(validating: profileName)
        let overrides = try profile.appServerConfigOverrides(
            in: URL(fileURLWithPath: homePath, isDirectory: true)
        )
        let arguments = overrides.flatMap { ["--config", $0] } + ["app-server", "--help"]

        let result = try BoundedSubprocess.run(
            executableURL: executableURL,
            arguments: arguments,
            timeout: 5,
            maximumOutputBytes: 128 * 1_024,
            captureStandardError: true,
            environmentOverrides: ["CODEX_HOME": homePath]
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertFalse(result.exceededOutputLimit)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = overrides.flatMap { ["--config", $0] }
            + ["app-server"]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["CODEX_HOME": homePath]
        ) { _, selected in selected }
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            SubprocessTerminator.terminateAndWait(process)
        }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(process.isRunning, "The selected profile app-server exited during startup")
    }

    func testBuiltProxyStartsSelectedInstalledAppServerWhenEnabled() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let proxyPath = environment["AGENTDOCK_BUILT_PROFILE_PROXY"],
              let homePath = environment["AGENTDOCK_INSTALLED_CONFIG_PROFILE_HOME"],
              let profileName = environment["AGENTDOCK_INSTALLED_CONFIG_PROFILE_NAME"]
        else {
            throw XCTSkip(
                "Set AGENTDOCK_BUILT_PROFILE_PROXY and the installed config-profile variables to validate the built proxy."
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: proxyPath)
        process.arguments = ["app-server"]
        process.environment = environment.merging([
            "CODEX_HOME": homePath,
            CodexCLIProfileProxy.enabledEnvironmentKey: "1",
            CodexCLIProfileProxy.appPathEnvironmentKey: "/Applications/Codex.app",
            CodexCLIProfileProxy.profileEnvironmentKey: profileName
        ]) { _, selected in selected }
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            SubprocessTerminator.terminateAndWait(process)
        }
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(process.isRunning, "The built profile proxy exited during startup")
    }
}
