import CodexerCore
import Darwin
import Foundation

@main
struct CodexerShortcutLauncher {
    static func main() async {
        if CodexCLIProfileProxy.isRequested {
            do {
                try CodexCLIProfileProxy.run()
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                Darwin.exit(EXIT_FAILURE)
            }
        }
        do {
            _ = try await ShortcutLauncherRunner().run(resourceURL: Bundle.main.resourceURL)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            FileHandle.standardError.write(Data("AgentDock shortcut failed: \(message)\n".utf8))
            exit(1)
        }
    }
}
