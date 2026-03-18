// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "APEX",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .watchOS(.v9),
        .tvOS(.v16),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "APEX",
            targets: ["APEX"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "APEX",
            dependencies: [],
            path: "Sources/APEX",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "APEXTests",
            dependencies: ["APEX"],
            path: "Tests/APEXTests"
        ),
    ]
)
