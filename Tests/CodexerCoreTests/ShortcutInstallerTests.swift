import XCTest
@testable import CodexerCore

final class ShortcutInstallerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexerShortcutTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testInstallShortcutCreatesBundleWithNativeHelperConfigAndInfoPlist() throws {
        let profile = CodexProfile(
            name: "Work Account",
            slug: "work-account",
            rootDirectory: root,
            codexLaunchProfileSelection: .named(CodexConfigProfile(rawValue: "ollama"))
        )
        let codexApp = URL(fileURLWithPath: "/Applications/Codex.app")
        let helper = try makeHelper()
        let installer = ShortcutInstaller(
            fileManager: .default,
            helperExecutableURL: helper,
            helperVersion: "42"
        )

        try installer.installShortcut(for: profile, codexAppURL: codexApp)

        let executable = profile.shortcutPath
            .appendingPathComponent("Contents/MacOS/AgentDockShortcutLauncher")
        let infoPlist = profile.shortcutPath
            .appendingPathComponent("Contents/Info.plist")
        let configPlist = profile.shortcutPath
            .appendingPathComponent("Contents/Resources/ShortcutConfig.plist")
        let configData = try Data(contentsOf: configPlist)
        let config = try PropertyListDecoder().decode(IsolatedCodexLaunchConfiguration.self, from: configData)
        let plistData = try Data(contentsOf: infoPlist)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        )

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        XCTAssertEqual(config.codexAppPath, codexApp.path)
        XCTAssertEqual(config.codexHomePath, profile.codexHomePath.path)
        XCTAssertEqual(config.electronUserDataPath, profile.electronUserDataPath.path)
        XCTAssertEqual(config.profileID, profile.id)
        XCTAssertEqual(config.profileSlug, profile.slug)
        XCTAssertEqual(
            config.codexLaunchProfileSelection,
            .named(CodexConfigProfile(rawValue: "ollama"))
        )
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "AgentDockShortcutLauncher")
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "26.0")
        XCTAssertEqual(
            plist["CFBundleIdentifier"] as? String,
            "dev.euforic.agentdock.profile.codex.work-account"
        )
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "Work Account")
        XCTAssertEqual(plist["CFBundleVersion"] as? String, "42")
    }

    func testRemoveShortcutDeletesOnlyShortcutBundle() throws {
        let profile = CodexProfile(name: "Personal", slug: "personal", rootDirectory: root)
        let installer = ShortcutInstaller(fileManager: .default)
        try FileManager.default.createDirectory(
            at: profile.profileDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: profile.shortcutPath,
            withIntermediateDirectories: true
        )

        try installer.removeShortcut(for: profile)

        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.shortcutPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.profileDirectory.path))
    }

    func testInstallClaudeShortcutUsesProductScopedLaunchConfiguration() throws {
        let profile = CodexProfile(
            product: .claude,
            name: "Personal",
            slug: "personal",
            rootDirectory: root
        )
        let claudeApp = URL(fileURLWithPath: "/Applications/Claude.app")
        let helper = try makeHelper()
        let installer = ShortcutInstaller(fileManager: .default, helperExecutableURL: helper)

        try installer.installShortcut(for: profile, codexAppURL: claudeApp)

        let contents = profile.shortcutPath.appendingPathComponent("Contents")
        let configData = try Data(
            contentsOf: contents.appendingPathComponent("Resources/ShortcutConfig.plist")
        )
        let config = try PropertyListDecoder().decode(
            IsolatedCodexLaunchConfiguration.self,
            from: configData
        )
        let plistData = try Data(contentsOf: contents.appendingPathComponent("Info.plist"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, format: nil)
                as? [String: Any]
        )

        XCTAssertEqual(profile.shortcutDirectory, root.appendingPathComponent("Shortcuts/claude"))
        XCTAssertEqual(config.resolvedProduct, .claude)
        XCTAssertEqual(config.appURL, claudeApp)
        XCTAssertEqual(config.claudeUserDataURL, profile.claudeUserDataPath)
        XCTAssertEqual(config.codexHomePath, "")
        XCTAssertEqual(config.electronUserDataPath, "")
        XCTAssertEqual(
            plist["CFBundleIdentifier"] as? String,
            "dev.euforic.agentdock.profile.claude.personal"
        )
    }

    func testFailedReinstallKeepsExistingShortcut() throws {
        let profile = CodexProfile(name: "Stable", slug: "stable", rootDirectory: root)
        try FileManager.default.createDirectory(at: profile.shortcutPath, withIntermediateDirectories: true)
        let sentinel = profile.shortcutPath.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        let missingHelper = root.appendingPathComponent("missing-helper")
        let installer = ShortcutInstaller(fileManager: .default, helperExecutableURL: missingHelper)

        XCTAssertThrowsError(try installer.installShortcut(
            for: profile,
            codexAppURL: URL(fileURLWithPath: "/Applications/Codex.app")
        ))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep")
    }

    func testOlderShortcutIsDetectedAndRebuiltWithoutChangingProfileIdentity() throws {
        let profile = CodexProfile(name: "Stable", slug: "stable", rootDirectory: root)
        let helper = try makeHelper()
        let oldInstaller = ShortcutInstaller(
            fileManager: .default,
            helperExecutableURL: helper,
            helperVersion: "10"
        )
        try oldInstaller.installShortcut(
            for: profile,
            codexAppURL: URL(fileURLWithPath: "/Applications/Codex.app")
        )

        let currentInstaller = ShortcutInstaller(
            fileManager: .default,
            helperExecutableURL: helper,
            helperVersion: "11"
        )
        XCTAssertTrue(currentInstaller.shortcutNeedsRefresh(for: profile))

        try currentInstaller.installShortcut(
            for: profile,
            codexAppURL: URL(fileURLWithPath: "/Applications/Codex.app")
        )

        XCTAssertFalse(currentInstaller.shortcutNeedsRefresh(for: profile))
        let configURL = profile.shortcutPath
            .appendingPathComponent("Contents/Resources/ShortcutConfig.plist")
        let config = try PropertyListDecoder().decode(
            IsolatedCodexLaunchConfiguration.self,
            from: Data(contentsOf: configURL)
        )
        XCTAssertEqual(config.profileID, profile.id)
        XCTAssertEqual(config.profileSlug, profile.slug)
        XCTAssertEqual(config.codexHomePath, profile.codexHomePath.path)
    }

    private func makeHelper() throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let helper = root.appendingPathComponent("CodexerShortcutLauncher")
        try Data("native-helper".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return helper
    }
}
