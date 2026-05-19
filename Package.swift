// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MTK",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "VolumeRendererComparison",
            targets: ["VolumeRendererComparison"]
        ),
        .library(
            name: "MTKCore",
            targets: ["MTKCore"]
        ),
        .library(
            name: "MTKUI",
            targets: ["MTKUI"]
        ),
        .library(
            name: "MTKDicomBridge",
            targets: ["MTKDicomBridge"]
        ),
        .library(
            name: "MTKFixtures",
            targets: ["MTKFixtures"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/ThalesMMS/DICOM-Decoder.git", exact: "1.1.1"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0")
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
        // MTKUI intentionally stays independent from any legacy 3D wrapper. The
        // clinical UI path is Metal-native and must not widen its public contract.
        .target(
            name: "MTKUI",
            dependencies: [
                "MTKCore"
            ],
            path: "Sources/MTKUI"
        ),
        .target(
            name: "MTKDicomBridge",
            dependencies: [
                "MTKCore",
                .product(name: "DicomCore", package: "DICOM-Decoder")
            ],
            path: "Sources/MTKDicomBridge"
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
            name: "MTKUITests",
            dependencies: [
                "MTKUI"
            ],
            path: "Tests/MTKUITests"
        ),
        .testTarget(
            name: "MTKDicomBridgeTests",
            dependencies: [
                "MTKCore",
                "MTKDicomBridge",
                .product(name: "DicomCore", package: "DICOM-Decoder")
            ],
            path: "Tests/MTKDicomBridgeTests"
        ),
        .testTarget(
            name: "MTKFixturesTests",
            dependencies: [
                "MTKCore",
                "MTKFixtures"
            ],
            path: "Tests/MTKFixturesTests"
        ),
        .executableTarget(
            name: "VolumeRendererComparison",
            dependencies: [
                "MTKCore",
                "MTKDicomBridge",
                .product(name: "DicomCore", package: "DICOM-Decoder")
            ],
            path: "Benchmarks/VolumeRendererComparison",
            resources: [
                .copy("ReferenceVolumeRayMarching.metal")
            ]
        ),
    ]
)
