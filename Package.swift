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
        )
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/ThalesMMS/DICOM-Decoder.git", from: "1.0.1"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "MTKCore",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Sources/MTKCore",
            resources: [
                .process("Resources")
            ],
            plugins: [
                .plugin(name: "MTKShaderPlugin")
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
                "MTKDicomBridge"
            ],
            path: "Tests/MTKDicomBridgeTests"
        ),
        .executableTarget(
            name: "VolumeRendererComparison",
            dependencies: [
                "MTKCore",
                "MTKDicomBridge"
            ],
            path: "Benchmarks/VolumeRendererComparison",
            resources: [
                .copy("ReferenceVolumeRayMarching.metal")
            ]
        ),
        .plugin(
            name: "MTKShaderPlugin",
            capability: .buildTool(),
            path: "Plugins/MTKShaderPlugin"
        )
    ]
)
