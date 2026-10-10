// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "swiftpy-llm",
    platforms: [.macOS(.v27), .iOS(.v27), .visionOS(.v27)],
    products: [
        .library(
            name: "Agents",
            targets: ["Agents"],
        ),
        .library(
            name: "Claude",
            targets: ["Claude"],
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/felfoldy/SwiftPy", from: "0.30.0"),
        .package(url: "https://github.com/libswiftpy/swiftpy-views", branch: "main"),
        // Only beta tags so far, which `from:` doesn't resolve.
        .package(url: "https://github.com/apple/foundation-models-utilities", exact: "1.1.0-beta1"),
        .package(url: "https://github.com/anthropics/ClaudeForFoundationModels", from: "0.2.3"),
    ],
    targets: [
        .target(
            name: "Agents",
            dependencies: [
                "SwiftPy",
                .product(name: "SwiftPyViews", package: "swiftpy-views"),
                .product(name: "FoundationModelsUtilities", package: "foundation-models-utilities"),
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableExperimentalFeature("AnyAppleOSAvailability"),
            ]
        ),
        .target(
            name: "Claude",
            dependencies: [
                "Agents",
                "SwiftPy",
                .product(name: "ClaudeForFoundationModels", package: "ClaudeForFoundationModels"),
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableExperimentalFeature("AnyAppleOSAvailability"),
            ]
        ),
        .testTarget(
            name: "AgentsTests",
            dependencies: ["Agents"]
        ),
        .testTarget(
            name: "ClaudeTests",
            dependencies: ["Claude"]
        ),
    ]
)
