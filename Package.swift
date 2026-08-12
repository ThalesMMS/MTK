// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MTK",
    defaultLocalization: "en",
    platforms: [
        .iOS("26.0"),
        .visionOS("26.0"),
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "MTKCore",
            targets: ["MTKCore"]
        ),
        .library(
            name: "MTKFixtures",
            targets: ["MTKFixtures"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.4.6")
    ],
    targets: [
        .target(
            name: "MTKCore",
            dependencies: [],
            path: "Sources/MTKCore",
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "MTKFixtures",
            dependencies: [
                "MTKCore"
            ],
            path: "Sources/MTKFixtures",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "MTKCoreTests",
            dependencies: [
                "MTKCore"
            ],
            path: "Tests/MTKCoreTests",
            resources: [
                .process("Fixtures")
            ]
        ),
        .testTarget(
            name: "MTKFixturesTests",
            dependencies: [
                "MTKCore",
                "MTKFixtures"
            ],
            path: "Tests/MTKFixturesTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
