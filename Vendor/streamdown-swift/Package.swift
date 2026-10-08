// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Streamdown",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "Streamdown", targets: ["Streamdown"]),
        .library(name: "StreamdownUI", targets: ["StreamdownUI"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/LiYanan2004/MarkdownView.git",
            from: "3.0.0",
            traits: []
        ),
    ],
    targets: [
        .target(name: "Streamdown"),
        .target(
            name: "StreamdownUI",
            dependencies: [
                "Streamdown",
                .product(name: "MarkdownView", package: "MarkdownView"),
            ]
        ),
        .testTarget(
            name: "StreamdownTests",
            dependencies: ["Streamdown"]
        ),
        .testTarget(
            name: "StreamdownUITests",
            dependencies: ["Streamdown", "StreamdownUI"]
        ),
    ]
)
