import Foundation

enum CodexBundledCLI {
    static func executableURL(for appURL: URL) -> URL {
        let current = appURL.appendingPathComponent(
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        )
        let legacy = appURL.appendingPathComponent("Contents/Resources/codex")
        if FileManager.default.isExecutableFile(atPath: current.path) {
            return current
        }
        if FileManager.default.isExecutableFile(atPath: legacy.path) {
            return legacy
        }
        return current
    }
}
