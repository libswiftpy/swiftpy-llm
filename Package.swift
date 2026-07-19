// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "swiftpy-llm",
    platforms: [.macOS(.v26), .iOS(.v26), .visionOS(.v26)],
    products: [
        .library(
            name: "Agents",
            targets: ["Agents"],
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/felfoldy/SwiftPy", from: "0.23.0"),
    ],
    targets: [
        .target(
            name: "Agents",
            dependencies: [
                "SwiftPy",
            ],
            resources: [
                .process("Resources")
            ]
        ),
    ]
)
