// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentDock",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "AgentDock", targets: ["Codexer"]),
        .executable(name: "AgentDockShortcutLauncher", targets: ["CodexerShortcutLauncher"]),
        .executable(name: "TranscriptRendererShowcase", targets: ["TranscriptRendererShowcase"]),
        .library(name: "CodexerCore", targets: ["CodexerCore"]),
        .library(name: "TranscriptRenderer", targets: ["TranscriptRenderer"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle.git",
            exact: "2.9.6"
        ),
        .package(path: "Vendor/streamdown-swift")
    ],
    targets: [
        .executableTarget(
            name: "Codexer",
            dependencies: [
                "CodexerCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            linkerSettings: [
                .unsafeFlags(
                    ["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]
                ),
                .unsafeFlags(
                    ["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../ExecutableModules"],
                    .when(configuration: .debug)
                )
            ]
        ),
        .executableTarget(
            name: "CodexerShortcutLauncher",
            dependencies: ["CodexerCore"]
        ),
        .executableTarget(
            name: "TranscriptRendererShowcase",
            dependencies: ["TranscriptRenderer"]
        ),
        .target(
            name: "CodexerCore"
        ),
        .target(
            name: "TranscriptRenderer",
            dependencies: [
                .product(name: "StreamdownUI", package: "streamdown-swift")
            ]
        ),
        .testTarget(
            name: "CodexerCoreTests",
            dependencies: ["CodexerCore"]
        ),
        .testTarget(
            name: "CodexerAppTests",
            dependencies: ["Codexer", "CodexerCore", "TranscriptRenderer"]
        ),
        .testTarget(
            name: "TranscriptRendererTests",
            dependencies: [
                "TranscriptRenderer",
                .product(name: "StreamdownUI", package: "streamdown-swift")
            ]
        )
    ]
)
