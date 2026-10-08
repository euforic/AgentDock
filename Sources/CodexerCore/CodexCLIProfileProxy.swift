import Darwin
import Foundation

public enum CodexCLIProfileProxy {
    static let enabledEnvironmentKey = "AGENTDOCK_CODEX_PROFILE_PROXY"
    static let appPathEnvironmentKey = "AGENTDOCK_CODEX_APP_PATH"
    static let profileEnvironmentKey = "AGENTDOCK_CODEX_CONFIG_PROFILE"

    public static var isRequested: Bool {
        ProcessInfo.processInfo.environment[enabledEnvironmentKey] == "1"
    }

    public static func run() throws -> Never {
        let environment = ProcessInfo.processInfo.environment
        guard environment[enabledEnvironmentKey] == "1",
              let appPath = environment[appPathEnvironmentKey],
              let profileName = environment[profileEnvironmentKey]
        else {
            throw CodexCLIProfileProxyError.invalidEnvironment
        }

        let appURL = URL(fileURLWithPath: appPath, isDirectory: true)
        try OfficialCodexAppValidator().validateCodexApp(at: appURL)
        let profile = try CodexConfigProfile(validating: profileName)
        let codexHomeURL = environment["CODEX_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        guard let codexHomeURL else {
            throw CodexCLIProfileProxyError.invalidEnvironment
        }
        let configOverrides = try profile.appServerConfigOverrides(in: codexHomeURL)

        let executableURL = CodexBundledCLI.executableURL(for: appURL)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CodexCLIProfileProxyError.missingBundledCLI(executableURL.path)
        }

        setenv("CODEX_CLI_PATH", executableURL.path, 1)
        unsetenv(enabledEnvironmentKey)
        unsetenv(appPathEnvironmentKey)
        unsetenv(profileEnvironmentKey)
        guard FileManager.default.changeCurrentDirectoryPath(codexHomeURL.path) else {
            throw CodexCLIProfileProxyError.invalidEnvironment
        }

        let arguments = forwardedArguments(
            executableURL: executableURL,
            configOverrides: configOverrides,
            incomingArguments: Array(CommandLine.arguments.dropFirst())
        )
        let result = arguments.withCStringArray { argumentPointers in
            Darwin.execv(executableURL.path, argumentPointers)
        }
        throw CodexCLIProfileProxyError.executionFailed(result, errno)
    }

    static func launcherURL(bundle: Bundle = .main) -> URL? {
        let candidates = [
            bundle.resourceURL?.appendingPathComponent("AgentDockShortcutLauncher"),
            bundle.executableURL?.deletingLastPathComponent()
                .appendingPathComponent("AgentDockShortcutLauncher"),
            bundle.executableURL?.lastPathComponent == "AgentDockShortcutLauncher"
                ? bundle.executableURL
                : nil
        ].compactMap { $0 }
        return candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        })
    }

    static func forwardedArguments(
        executableURL: URL,
        configOverrides: [String],
        incomingArguments: [String]
    ) -> [String] {
        [executableURL.path]
            + configOverrides.flatMap { ["--config", $0] }
            + incomingArguments
    }
}

public enum CodexCLIProfileProxyError: Error, LocalizedError, Equatable {
    case invalidEnvironment
    case missingBundledCLI(String)
    case executionFailed(Int32, Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidEnvironment:
            "The Codex profile launcher environment is incomplete."
        case let .missingBundledCLI(path):
            "The selected Codex app has no executable bundled CLI at \(path)."
        case let .executionFailed(result, errorNumber):
            "The Codex profile launcher failed with result \(result) and errno \(errorNumber)."
        }
    }
}

private extension Array where Element == String {
    func withCStringArray<Result>(
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) rethrows -> Result {
        let duplicated = map { strdup($0) }
        defer { duplicated.forEach { free($0) } }
        var pointers = duplicated + [nil]
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }
}
