// swift-tools-version: 6.3

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
        .package(url: "https://github.com/felfoldy/SwiftPy", from: "0.28.0"),
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
