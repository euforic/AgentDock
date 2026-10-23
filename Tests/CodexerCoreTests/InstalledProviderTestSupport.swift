import Foundation
@testable import CodexerCore

func installedProviderAppURL(_ product: DesktopProduct) -> URL {
    let key = product == .codex ? "AGENTDOCK_CODEX_APP_PATH" : "AGENTDOCK_CLAUDE_APP_PATH"
    if let path = ProcessInfo.processInfo.environment[key], !path.isEmpty {
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    return DesktopAppRegistry.descriptor(for: product).defaultAppURL
}
