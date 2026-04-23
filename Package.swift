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
        .library(
            name: "MTKCore",
            targets: ["MTKCore"]
        ),
        .library(
            name: "MTKUI",
            targets: ["MTKUI"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(path: "../DICOM-decoder"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "MTKCore",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "DicomCore", package: "DICOM-decoder")
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
        .testTarget(
            name: "MTKCoreTests",
            dependencies: [
                "MTKCore"
            ],
            path: "Tests/MTKCoreTests"
        ),
        .testTarget(
            name: "MTKUITests",
            dependencies: [
                "MTKUI"
            ],
            path: "Tests/MTKUITests"
        ),
        .plugin(
            name: "MTKShaderPlugin",
            capability: .buildTool(),
            path: "Plugins/MTKShaderPlugin"
        )
    ]
)
