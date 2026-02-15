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
            name: "MTKSceneKit",
            targets: ["MTKSceneKit"]
        ),
        .library(
            name: "MTKUI",
            targets: ["MTKUI"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(path: "../DICOM-Decoder"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "MTKCore",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "DicomCore", package: "DICOM-Decoder")
            ],
            path: "Sources/MTKCore",
            resources: [
                .process("Resources")
            ],
            plugins: [
                .plugin(name: "MTKShaderPlugin")
            ]
        ),
        .target(
            name: "MTKSceneKit",
            dependencies: [
                "MTKCore"
            ],
            path: "Sources/MTKSceneKit"
        ),
        .target(
            name: "MTKUI",
            dependencies: [
                "MTKCore",
                "MTKSceneKit"
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
            name: "MTKSceneKitTests",
            dependencies: [
                "MTKSceneKit"
            ],
            path: "Tests/MTKSceneKitTests"
        ),
        .testTarget(
            name: "MTKUITests",
            dependencies: [
                "MTKUI",
                "MTKSceneKit"
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
