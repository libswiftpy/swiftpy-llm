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
    ],
    dependencies: [
        .package(url: "https://github.com/felfoldy/SwiftPy", from: "0.29.0"),
        .package(url: "https://github.com/felfoldy/swiftpy-views", branch: "main"),
    ],
    targets: [
        .target(
            name: "Agents",
            dependencies: [
                "SwiftPy",
                .product(name: "SwiftPyViews", package: "swiftpy-views"),
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableExperimentalFeature("AnyAppleOSAvailability"),
            ]
        ),
    ]
)
