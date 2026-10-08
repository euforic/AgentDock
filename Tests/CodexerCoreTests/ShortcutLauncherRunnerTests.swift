import XCTest
@testable import CodexerCore

final class ShortcutLauncherRunnerTests: XCTestCase {
    func testMissingBundleAndConfigAreReported() async {
        let runner = ShortcutLauncherRunner(opener: RecordingShortcutOpener())
        do {
            _ = try await runner.run(resourceURL: nil)
            XCTFail("Expected missing bundle")
        } catch {
            XCTAssertEqual(error as? ShortcutLauncherError, .missingBundle)
        }

        let resources = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: resources) }
        do {
            _ = try await runner.run(resourceURL: resources)
            XCTFail("Expected missing config")
        } catch {
            XCTAssertEqual(
                error as? ShortcutLauncherError,
                .missingConfig(resources.appendingPathComponent("ShortcutConfig.plist"))
            )
        }
    }

    func testMalformedConfigurationIsRejectedBeforeOpening() async throws {
        let resources = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: resources) }
        try Data("not a plist".utf8).write(
            to: resources.appendingPathComponent("ShortcutConfig.plist")
        )
        let opener = RecordingShortcutOpener()

        await XCTAssertThrowsErrorAsync {
            _ = try await ShortcutLauncherRunner(opener: opener).run(resourceURL: resources)
        }
        let configurations = await opener.configurations()
        XCTAssertEqual(configurations, [])
    }

    func testValidConfigurationIsPassedToController() async throws {
        let resources = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: resources) }
        let configuration = IsolatedCodexLaunchConfiguration(
            codexAppURL: URL(fileURLWithPath: "/Applications/Codex.app"),
            codexHomeURL: URL(fileURLWithPath: "/tmp/profile/CODEX_HOME"),
            electronUserDataURL: URL(fileURLWithPath: "/tmp/profile/ElectronUserData")
        )
        try PropertyListEncoder().encode(configuration).write(
            to: resources.appendingPathComponent("ShortcutConfig.plist")
        )
        let opener = RecordingShortcutOpener(outcome: .focused(processID: 42))

        let outcome = try await ShortcutLauncherRunner(opener: opener).run(resourceURL: resources)

        XCTAssertEqual(outcome, .focused(processID: 42))
        let configurations = await opener.configurations()
        XCTAssertEqual(configurations, [configuration])
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShortcutRunner-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor RecordingShortcutOpener: IsolatedCodexOpening {
    private let outcome: CodexOpenOutcome
    private var recorded: [IsolatedCodexLaunchConfiguration] = []

    init(outcome: CodexOpenOutcome = .launched(processID: 1)) {
        self.outcome = outcome
    }

    func open(configuration: IsolatedCodexLaunchConfiguration) async throws -> CodexOpenOutcome {
        recorded.append(configuration)
        return outcome
    }

    func configurations() -> [IsolatedCodexLaunchConfiguration] {
        recorded
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
