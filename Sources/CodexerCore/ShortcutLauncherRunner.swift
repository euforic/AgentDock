import Foundation

public protocol IsolatedCodexOpening: Sendable {
    func open(
        configuration: IsolatedCodexLaunchConfiguration
    ) async throws -> CodexOpenOutcome
}

extension DesktopInstanceController: IsolatedCodexOpening {}

public struct ShortcutLauncherRunner {
    private let fileManager: FileManager
    private let opener: any IsolatedCodexOpening

    public init(
        fileManager: FileManager = .default,
        opener: any IsolatedCodexOpening = DesktopInstanceController()
    ) {
        self.fileManager = fileManager
        self.opener = opener
    }

    @discardableResult
    public func run(resourceURL: URL?) async throws -> CodexOpenOutcome {
        guard let resourceURL else {
            throw ShortcutLauncherError.missingBundle
        }
        let configURL = resourceURL.appendingPathComponent("ShortcutConfig.plist")
        guard fileManager.fileExists(atPath: configURL.path) else {
            throw ShortcutLauncherError.missingConfig(configURL)
        }
        let data: Data
        do {
            data = try BoundedFileReader.data(
                at: configURL,
                maximumBytes: LocalControlFileLimit.shortcutConfiguration
            )
        } catch {
            throw ShortcutLauncherError.unsafeConfig(configURL)
        }
        let configuration = try PropertyListDecoder().decode(
            IsolatedCodexLaunchConfiguration.self,
            from: data
        )
        return try await opener.open(configuration: configuration)
    }
}

public enum ShortcutLauncherError: Error, LocalizedError, Equatable {
    case missingBundle
    case missingConfig(URL)
    case unsafeConfig(URL)

    public var errorDescription: String? {
        switch self {
        case .missingBundle:
            "The shortcut launcher is not running from an app bundle."
        case let .missingConfig(url):
            "Missing shortcut config at \(url.path)."
        case let .unsafeConfig(url):
            "The shortcut config is not a safe bounded file: \(url.path)."
        }
    }
}
