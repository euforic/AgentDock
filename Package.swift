// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentDock",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "AgentDock", targets: ["AgentDock"]),
        .executable(name: "AgentDockShortcutLauncher", targets: ["AgentDockShortcutLauncher"]),
        .executable(name: "TranscriptRendererShowcase", targets: ["TranscriptRendererShowcase"]),
        .library(name: "AgentDockCore", targets: ["AgentDockCore"]),
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
            name: "AgentDock",
            dependencies: [
                "AgentDockCore",
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
            name: "AgentDockShortcutLauncher",
            dependencies: ["AgentDockCore"]
        ),
        .executableTarget(
            name: "TranscriptRendererShowcase",
            dependencies: ["TranscriptRenderer"]
        ),
        .target(
            name: "AgentDockCore"
        ),
        .target(
            name: "TranscriptRenderer",
            dependencies: [
                .product(name: "StreamdownUI", package: "streamdown-swift")
            ]
        ),
        .testTarget(
            name: "AgentDockCoreTests",
            dependencies: ["AgentDockCore"]
        ),
        .testTarget(
            name: "AgentDockAppTests",
            dependencies: ["AgentDock", "AgentDockCore"]
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
