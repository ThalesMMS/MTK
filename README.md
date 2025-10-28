# MTK — Metal Toolkit

MTK is a modern Swift/Metal toolkit for high-fidelity medical imaging, delivering fast volume rendering, interactive 3D exploration, and reusable components for building advanced diagnostic viewers.

## Features

- GPU-accelerated volume rendering with configurable transfer functions, sampling, and dataset streaming.
- SceneKit integration that turns volumetric datasets into interactive 3D scenes with camera and lighting utilities.
- SwiftUI-ready UI components for iOS and macOS, including volume viewers, inspectors, and layout helpers.
- Resource management powered by ZIPFoundation for handling compressed studies and large imaging archives.
- Layered architecture that separates rendering, scene orchestration, and UI concerns for easier customization.

## Targets

- `VolumeRenderingCore`: Core algorithms, Metal resources, and runtime configuration.
- `VolumeRenderingSceneKit`: SceneKit wrappers and renderer helpers backed by the core module.
- `VolumeRenderingUI`: SwiftUI components, view models, and previews ready for multiplatform apps.

## Requirements

- Swift 5.10 or newer
- Xcode 16 or newer
- iOS 17 / macOS 14 minimum deployment
- Metal-capable device or simulator

## Installation

Add MTK to your project via Swift Package Manager:

```swift
let package = Package(
    name: "YourApp",
    dependencies: [
        .package(url: "https://github.com/<your-account>/MTK.git", from: "0.1.0")
    ],
    targets: [
        .target(
            name: "YourApp",
            dependencies: [
                .product(name: "VolumeRenderingCore", package: "MTK"),
                .product(name: "VolumeRenderingSceneKit", package: "MTK"),
                .product(name: "VolumeRenderingUI", package: "MTK")
            ]
        )
    ]
)
```

Resolve dependencies in Xcode or by running `swift package resolve`.

## Quick Start

```swift
import VolumeRenderingUI

@main
struct ViewerApp: App {
    @StateObject private var renderer = VolumeRenderingViewModel()

    var body: some Scene {
        WindowGroup {
            VolumeRenderingViewport(viewModel: renderer)
                .task {
                    try? await renderer.loadStudy(from: sampleURL)
                }
        }
    }
}
```

### Gesture & Overlay Scaffolding (Etapa 2)

- `volumeGestures(controller:state:configuration:)` attaches drag/pinch/rotate gestures to any SwiftUI surface and forwards them to `VolumetricSceneController`. Customize behaviour via `VolumeGestureConfiguration` or inspect state through `VolumeGestureState`.
- Overlay components live under `VolumeRenderingUI/Overlays` (`CrosshairOverlayView`, `OrientationOverlayView`, `WindowLevelControlView`, `SlabThicknessControlView`) and honour the lightweight `VolumetricUIStyle` protocol so hosts can supply their own palette.
- `MPRGridComposer` provides a minimal 2×2 layout (axial, coronal, sagittal, 3D) that synchronizes slab/window changes via the controller—ideal for quick prototyping until richer panes are wired.

### ShaderLibraryLoader (Etapa 3 prototype)

`ShaderLibraryLoader` resolves Metal libraries packaged with SwiftPM without touching `Package.swift`:

```swift
import Metal
import VolumeRenderingCore

guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal unavailable") }
let library = ShaderLibraryLoader.makeDefaultLibrary(on: device) { message in
    debugPrint(message)
}
```

The loader prefers `Bundle.module` output, then falls back to `device.makeDefaultLibrary()` and finally probes `VolumeRendering.metallib` inside `Sources/VolumeRenderingCore/Resources`. Diagnostics surfaced through the closure clarify which path succeeded, keeping builds deterministic.

## Documentation

- API reference (DocC) — planned
- Example projects — planned (SwiftUI viewer, UIKit inspector)
- Shaders and resources live inside each target’s `Resources` folder and are available via `Bundle.module`.

## Roadmap

- Multi-volume compositing and MPR utilities
- Thick slab rendering and clinical measurement overlays
- SOP Class-specific loaders and DICOM query/retrieve helpers

## Contributing

Contributions are welcome. Please open an issue before submitting large features to align on architecture and roadmap. Run `swift test` before opening pull requests. By contributing, you agree that your work will be licensed under the Apache License, Version 2.0.

## License

Copyright © 2025 Thales Matheus Mendonça Santos.

Licensed under the Apache License, Version 2.0. See [`LICENSE`](LICENSE) for the full text.

## Acknowledgements

MTK draws significant inspiration from the open-source community, especially:
- [VTK](https://github.com/Kitware/VTK) for its pioneering work in visualization and volume rendering pipelines.
- [Acto3D](https://github.com/Acto3D/Acto3D) for its modern volumetric rendering concepts and scene orchestration patterns.
- [Volume Rendering in iOS](https://github.com/eunwonki/Volume-Rendering-In-iOS) for demonstrating practical Metal-based rendering techniques on Apple platforms.
