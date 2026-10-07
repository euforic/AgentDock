import Foundation
import XCTest

final class ReleaseWorkflowTests: XCTestCase {
    func testReleaseWorkflowRunsForStableTagsAndDispatchedAlphaTags() throws {
        let workflow = try String(contentsOf: repositoryRoot
            .appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8)
        let triggerBlock = try XCTUnwrap(workflow.components(separatedBy: "\npermissions:").first)

        XCTAssertEqual(triggerBlock, """
        name: Build and Release

        on:
          push:
            tags:
              - "v*"
              - "alpha-*"
          workflow_dispatch:

        """)
    }

    func testAppcastPublicationDependsOnReleaseAssetPublication() throws {
        let workflow = try String(contentsOf: repositoryRoot
            .appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8)

        XCTAssertTrue(workflow.contains("  release:\n"))
        XCTAssertTrue(workflow.contains("  appcast:\n    name: Sign and publish selected appcast last\n    needs: [build, release]\n"))
        XCTAssertTrue(workflow.contains("https://github.com/euforic/AgentDock/releases/download/$GITHUB_REF_NAME/"))
        XCTAssertTrue(workflow.contains("https://gh.euforic.one/AgentDock/$seed_filename"))
        XCTAssertTrue(workflow.contains("feed_filenames+=(appcast-alpha.xml)"))
        XCTAssertTrue(workflow.contains("for output_filename in $FEED_FILENAMES; do"))
        XCTAssertTrue(workflow.contains("appcast-alpha.xml"))
        XCTAssertTrue(workflow.contains("--channel alpha"))
        XCTAssertTrue(workflow.contains("cmp -s \"release-input/$archive_name\" \"$archive_dir/$archive_name\""))
        XCTAssertTrue(workflow.contains("Verify public appcast bytes and signature"))
    }

    func testReleaseIsSerializedMainBoundAndEnvironmentProtected() throws {
        let workflow = try String(contentsOf: repositoryRoot
            .appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8)

        XCTAssertTrue(workflow.contains("group: agentdock-release"))
        XCTAssertTrue(workflow.contains("git merge-base --is-ancestor \"$GITHUB_SHA\" origin/main"))
        XCTAssertTrue(workflow.contains("is not the highest version tag"))
        XCTAssertTrue(workflow.contains("public_version=\"$(./script/latest_appcast_version.sh \"$public_appcast\")\""))
        XCTAssertTrue(workflow.contains("Release version $version must be newer than public appcast version"))
        XCTAssertTrue(workflow.contains("runs-on: macos-26\n    environment: release"))
        XCTAssertTrue(workflow.contains("Alpha releases must point to the current origin/main commit."))
        XCTAssertTrue(workflow.contains("prerelease: ${{ needs.build.outputs.channel == 'alpha' }}"))
        XCTAssertTrue(workflow.contains("make_latest: ${{ needs.build.outputs.channel == 'stable' }}"))
    }

    func testAlphaPublicationIsDebouncedAfterSuccessfulMainQualityRun() throws {
        let workflow = try String(contentsOf: repositoryRoot
            .appendingPathComponent(".github/workflows/alpha-trigger.yml"), encoding: .utf8)

        XCTAssertTrue(workflow.contains("workflow_run:"))
        XCTAssertTrue(workflow.contains("- Quality"))
        XCTAssertTrue(workflow.contains("github.event.workflow_run.conclusion == 'success'"))
        XCTAssertTrue(workflow.contains("github.event.workflow_run.event == 'push'"))
        XCTAssertTrue(workflow.contains("group: agentdock-alpha-trigger"))
        XCTAssertTrue(workflow.contains("cancel-in-progress: true"))
        XCTAssertTrue(workflow.contains("run: sleep 600"))
        XCTAssertTrue(workflow.contains("git rev-parse origin/main"))
        XCTAssertTrue(workflow.contains("git push origin \"refs/tags/$tag\""))
        XCTAssertTrue(workflow.contains("gh workflow run release.yml --repo \"$GITHUB_REPOSITORY\" --ref \"$tag\""))
        XCTAssertTrue(workflow.contains("actions: write"))
    }

    func testAppcastVersionExtractorHandlesSparkleElementAndFailsClosed() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let validAppcast = temporaryDirectory.appendingPathComponent("valid.xml")
        try """
        <?xml version="1.0" encoding="utf-8"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <sparkle:shortVersionString>0.1.19</sparkle:shortVersionString>
            </item>
          </channel>
        </rss>
        """.write(to: validAppcast, atomically: true, encoding: .utf8)

        let validResult = try runAppcastVersionExtractor(with: validAppcast)
        XCTAssertEqual(validResult.status, 0)
        XCTAssertEqual(validResult.standardOutput, "0.1.19\n")

        let invalidAppcast = temporaryDirectory.appendingPathComponent("invalid.xml")
        try "<rss><channel><item /></channel></rss>"
            .write(to: invalidAppcast, atomically: true, encoding: .utf8)

        let invalidResult = try runAppcastVersionExtractor(with: invalidAppcast)
        XCTAssertNotEqual(invalidResult.status, 0)
        XCTAssertTrue(invalidResult.standardError.contains("does not contain a valid semantic short version"))
    }

    func testContinuousIntegrationCoversRootVendorPrivacyAndPackaging() throws {
        let workflow = try String(contentsOf: repositoryRoot
            .appendingPathComponent(".github/workflows/ci.yml"), encoding: .utf8)

        XCTAssertTrue(workflow.contains("pull_request:"))
        XCTAssertTrue(workflow.contains("branches:\n      - main"))
        XCTAssertTrue(workflow.contains("run: swift test\n"))
        XCTAssertTrue(workflow.contains("swift test --package-path Vendor/streamdown-swift"))
        XCTAssertTrue(workflow.contains("./script/audit_privacy.sh"))
        XCTAssertTrue(workflow.contains("./script/build_app.sh"))
        XCTAssertTrue(workflow.contains("./script/package_app.sh"))
    }

    func testReleasePublicationUsesGitHubRunnerWithWritePermission() throws {
        let workflow = try String(contentsOf: repositoryRoot
            .appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8)

        XCTAssertTrue(workflow.contains("""
          release:
            name: Publish immutable release assets
            needs: build
            runs-on: ubuntu-24.04
            permissions:
              contents: write
        """))
        XCTAssertFalse(workflow.contains("target_commitish:"))
    }

    func testSignedFeedAlsoVerifiesUpdatesBeforeExtraction() throws {
        let buildScript = try String(contentsOf: repositoryRoot
            .appendingPathComponent("script/build_app.sh"), encoding: .utf8)
        let packageScript = try String(contentsOf: repositoryRoot
            .appendingPathComponent("script/package_app.sh"), encoding: .utf8)

        XCTAssertTrue(buildScript.contains("""
          <key>SURequireSignedFeed</key>
          <true/>
          <key>SUVerifyUpdateBeforeExtraction</key>
          <true/>
        """))
        XCTAssertTrue(packageScript.contains("PLIST_VERIFY_BEFORE_EXTRACTION"))
        XCTAssertTrue(packageScript.contains("Sparkle updates must be verified before extraction"))
    }

    func testPackagedAppChecksForUpdatesHourly() throws {
        let buildScript = try String(contentsOf: repositoryRoot
            .appendingPathComponent("script/build_app.sh"), encoding: .utf8)
        let packageScript = try String(contentsOf: repositoryRoot
            .appendingPathComponent("script/package_app.sh"), encoding: .utf8)

        XCTAssertTrue(buildScript.contains("""
          <key>SUScheduledCheckInterval</key>
          <real>3600</real>
        """))
        XCTAssertTrue(packageScript.contains("PLIST_UPDATE_CHECK_INTERVAL"))
        XCTAssertTrue(packageScript.contains(#"^3600([.]0+)?$"#))
        XCTAssertTrue(packageScript.contains("Sparkle update checks must run hourly"))
        XCTAssertTrue(buildScript.contains("""
          <key>SUAutomaticallyUpdate</key>
          <false/>
        """))
        XCTAssertTrue(packageScript.contains("Sparkle updates must wait for the update pill by default"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func runAppcastVersionExtractor(with appcast: URL) throws -> (
        status: Int32,
        standardOutput: String,
        standardError: String
    ) {
        let process = Process()
        process.executableURL = repositoryRoot
            .appendingPathComponent("script/latest_appcast_version.sh")
        process.arguments = [appcast.path]

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(
                decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ),
            String(
                decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }
}
