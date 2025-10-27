// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "VolumeRenderingKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "VolumeRenderingCore",
            targets: ["VolumeRenderingCore"]
        ),
        .library(
            name: "VolumeRenderingSceneKit",
            targets: ["VolumeRenderingSceneKit"]
        ),
        .library(
            name: "VolumeRenderingUI",
            targets: ["VolumeRenderingUI"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19")
    ],
    targets: [
        .target(
            name: "VolumeRenderingCore",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Sources/VolumeRenderingCore",
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "VolumeRenderingSceneKit",
            dependencies: [
                "VolumeRenderingCore"
            ],
            path: "Sources/VolumeRenderingSceneKit"
        ),
        .target(
            name: "VolumeRenderingUI",
            dependencies: [
                "VolumeRenderingCore",
                "VolumeRenderingSceneKit"
            ],
            path: "Sources/VolumeRenderingUI"
        ),
        .testTarget(
            name: "VolumeRenderingCoreTests",
            dependencies: [
                "VolumeRenderingCore"
            ],
            path: "Tests/VolumeRenderingCoreTests"
        ),
        .testTarget(
            name: "VolumeRenderingSceneKitTests",
            dependencies: [
                "VolumeRenderingSceneKit"
            ],
            path: "Tests/VolumeRenderingSceneKitTests"
        ),
        .testTarget(
            name: "VolumeRenderingUITests",
            dependencies: [
                "VolumeRenderingUI"
            ],
            path: "Tests/VolumeRenderingUITests"
        )
    ]
)
