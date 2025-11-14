# MTK — Metal Toolkit

MTK is a modern Swift/Metal toolkit for high-fidelity medical imaging, delivering fast volume rendering, interactive 3D exploration, and reusable components for building advanced diagnostic viewers.

## Features

- GPU-accelerated volume rendering with configurable transfer functions, sampling, and dataset streaming.
- SceneKit integration that turns volumetric datasets into interactive 3D scenes with camera and lighting utilities.
- SwiftUI-ready UI components for iOS and macOS, including volume viewers, inspectors, and layout helpers.
- Resource management powered by ZIPFoundation for handling compressed studies and large imaging archives.
- Layered architecture that separates rendering, scene orchestration, and UI concerns for easier customization.

## Targets

- `MTKCore`: Core algorithms, Metal resources, and runtime configuration.
- `MTKSceneKit`: SceneKit wrappers and renderer helpers backed by the core module.
- `MTKUI`: SwiftUI components, view models, and previews ready for multiplatform apps.

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
                .product(name: "MTKCore", package: "MTK"),
                .product(name: "MTKSceneKit", package: "MTK"),
                .product(name: "MTKUI", package: "MTK")
            ]
        )
    ]
)
```

Resolve dependencies in Xcode or by running `swift package resolve`.

## Quick Start

```swift
import MTKUI

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
- Overlay components live under `MTKUI/Overlays` (`CrosshairOverlayView`, `OrientationOverlayView`, `WindowLevelControlView`, `SlabThicknessControlView`) and honour the lightweight `VolumetricUIStyle` protocol so hosts can supply their own palette.
- `MPRGridComposer` provides a minimal 2×2 layout (axial, coronal, sagittal, 3D) that synchronizes slab/window changes via the controller—ideal for quick prototyping until richer panes are wired.

### ShaderLibraryLoader & Shader Packaging (Etapa 3)

`ShaderLibraryLoader` resolves Metal libraries packaged with SwiftPM without touching `Package.swift`:

```swift
import Metal
import MTKCore

guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal unavailable") }
let library = ShaderLibraryLoader.makeDefaultLibrary(on: device) { message in
    debugPrint(message)
}
```

The loader prefers `Bundle.module` output, then falls back to `device.makeDefaultLibrary()` and finally probes `MTK.metallib` inside `Sources/MTKCore/Resources`. Diagnostics surfaced through the closure clarify which path succeeded, keeping builds deterministic.

#### Build-tool plugin + fallback script
- **SwiftPM plugin**: `MTKShaderPlugin` automatically compiles every `.metal` file in `Sources/MTKCore/Resources/Shaders` into `MTK.metallib` and bundles it via `Bundle.module` during `swift build` / Xcode builds.
- **Fallback script**: `Tooling/Shaders/build_metallib.sh` mirrors the plugin logic for CI or manual use. Run `bash Tooling/Shaders/build_metallib.sh` to regenerate the metallib when plugins are disabled.

#### CI checklist
1. `bash Tooling/Shaders/build_metallib.sh` (or rely on the plugin) before packaging artifacts.
2. Assert `Sources/MTKCore/Resources/Shaders/MTK.metallib` exists (plugin output lives under `.build/plugins/.../CompiledShaders/`).
3. `swift test` — GPU-free tests will skip gracefully when Metal devices aren’t available.

## Quick Navigation

- **New to MTK?** Start with [Installation](#installation) and [Quick Start](#quick-start)
- **Building an app?** See [Integration Examples](#integration-examples)
- **Need API reference?** See [API Reference](#api-reference)
- **Having issues?** See [Troubleshooting](#troubleshooting)
- **Want architecture details?** See [Architecture](#architecture)

## API Reference

### MTKCore

High-level facade for Metal rendering pipelines, managing both fragment and compute rendering.

**Key Classes:**
- **`MetalRaycaster`** — Facade for GPU volume rendering
  - Manages pipeline caching (fragment and compute)
  - Handles dataset texture preparation
  - Submits rendering commands
  - Thread-safe within render thread context

- **`Geometry`** — Coordinate space transformations
  - Voxel ↔ World ↔ Texture space conversions
  - Essential for positioning MPR slices
  - Handles patient (LPS) and texture coordinates

- **`TransferFunction`** — Maps voxel intensity to color and opacity
  - Preset system for common imaging modes
  - Custom function support
  - Real-time updates during rendering

- **`VolumeDataset`** — Volume data container
  - Voxel dimensions and spacing
  - Pixel format and data layout
  - Validation and safety checks

**Usage Example:**
```swift
import Metal
import MTKCore

let device = MTLCreateSystemDefaultDevice()!
let raycaster = try MetalRaycaster(device: device)

// Load dataset
let dataset = VolumeDataset(dimensions: (512, 512, 512), voxelData: data)
let resources = try raycaster.load(dataset: dataset)

// Create render pipeline
let pipeline = try raycaster.makeFragmentPipeline(
    colorPixelFormat: .bgra8Unorm,
    depthPixelFormat: .depth32Float
)
```

[Full API documentation →](Documentation/API.md#MTKCore)

### MTKSceneKit

SceneKit integration with camera and lighting utilities.

**Key Classes:**
- **`VolumetricSceneController`** — Manages SceneKit scene orchestration
  - Camera control and positioning
  - Lighting setup and adjustment
  - Material management
  - Gesture handling integration

- **Camera & Lighting Helpers** — Scene setup utilities
  - Orthographic and perspective camera modes
  - Physical light simulation
  - Shadow configuration

**Usage Example:**
```swift
import SceneKit
import MTKSceneKit

let scene = SCNScene()
let controller = VolumetricSceneController(scene: scene)

// Setup rendering
let dataset = VolumeDataset(...)
controller.load(dataset: dataset)

// Adjust camera
controller.camera.position = SCNVector3(x: 0, y: 0, z: 500)
```

[Full API documentation →](Documentation/API.md#MTKSceneKit)

### MTKUI

SwiftUI components for app integration.

**Key Components:**
- **`VolumeRenderingViewport`** — Main SwiftUI view for volume rendering
- **`VolumeRenderingViewModel`** — State management and data loading
- **Overlay Components:** Crosshair, orientation, window/level controls
- **Gesture Support:** Drag, pinch, rotate with configuration options

**Usage Example:**
```swift
import SwiftUI
import MTKUI

struct ContentView: View {
    @StateObject private var viewModel = VolumeRenderingViewModel()

    var body: some View {
        VolumeRenderingViewport(viewModel: viewModel)
            .task {
                try? await viewModel.loadDataset(from: datasetURL)
            }
    }
}
```

[Full API documentation →](Documentation/API.md#MTKUI)

## Integration Examples

### Example 1: Basic Direct Volume Rendering (DVR)

Minimal example to render a volume in SwiftUI:

```swift
import SwiftUI
import MTKUI

@main
struct DVRViewerApp: App {
    @StateObject var viewModel = VolumeRenderingViewModel()

    var body: some Scene {
        WindowGroup {
            VStack {
                VolumeRenderingViewport(viewModel: viewModel)

                VStack {
                    Text("Window/Level")
                    HStack {
                        Slider(value: $viewModel.windowLevel.window, in: 1...4000)
                        Slider(value: $viewModel.windowLevel.level, in: -1024...3000)
                    }
                }
                .padding()
            }
            .task {
                // Load sample volume
                let url = Bundle.main.url(forResource: "sample", withExtension: "dcm")!
                try? await viewModel.loadDataset(from: url)
            }
        }
    }
}
```

[→ See complete example](Examples/BasicDVR/)

### Example 2: Combined DVR and MPR with Synchronization

Sync volume rendering with multi-planar reconstruction:

```swift
import SwiftUI
import MTKUI

struct DVRWithMPRView: View {
    @StateObject var volumeVM = VolumeRenderingViewModel()
    @StateObject var mprVM = VolumeRenderingViewModel()
    @State var sharedWindowLevel = WindowLevelSettings()

    var body: some View {
        HStack(spacing: 8) {
            // Volume Rendering
            VolumeRenderingViewport(viewModel: volumeVM)

            // MPR Reconstruction
            VStack {
                Text("Axial")
                MPRAxisView(viewModel: mprVM, axis: .axial)

                Text("Coronal")
                MPRAxisView(viewModel: mprVM, axis: .coronal)
            }
        }
        .task {
            let dataset = try? VolumeDataset.load(from: datasetURL)
            try? await volumeVM.loadDataset(dataset)
            try? await mprVM.loadDataset(dataset)
        }
        .onChange(of: sharedWindowLevel) { newValue in
            volumeVM.windowLevel = newValue
            mprVM.windowLevel = newValue
        }
    }
}
```

[→ See complete example](Examples/DVRwithMPR/)

### Example 3: Custom Transfer Function

Create and apply custom transfer function:

```swift
import MTKCore

// Create custom transfer function
let tf = TransferFunction()

// Add control points: intensity -> (color, opacity)
tf.setPoint(intensity: 50, color: .black, opacity: 0.0)      // Background transparent
tf.setPoint(intensity: 150, color: .blue, opacity: 0.3)      // Soft tissue
tf.setPoint(intensity: 400, color: .red, opacity: 0.8)       // Bone

// Apply to renderer
raycaster.applyTransferFunction(tf)

// Save custom preset
try? tf.save(to: documentsURL.appendingPathComponent("custom.tf"))
```

[→ See complete example](Examples/CustomTransferFunction/)

### Example 4: Memory-Efficient Large Dataset Handling

Streaming and tiling strategies for large volumes:

```swift
import MTKCore

// For volumes > 512MB, use streaming
let largeDataset = VolumeDataset(dimensions: (1024, 1024, 1024), ...)

// Option 1: Downsample
let downsampled = largeDataset.downsample(factor: 2)
let resources = try raycaster.load(dataset: downsampled)

// Option 2: Tile rendering (render visible region only)
let tileSize = 256
for i in 0..<(1024 / tileSize) {
    for j in 0..<(1024 / tileSize) {
        let tile = largeDataset.tile(startX: i * tileSize, startY: j * tileSize)
        try raycaster.renderTile(tile)
    }
}

// Option 3: Use streaming loader for progressive rendering
let streamingLoader = StreamingVolumeLoader(dataset: largeDataset)
while streamingLoader.hasMore {
    let chunk = streamingLoader.nextChunk()
    raycaster.addTexture(chunk)
}
```

[→ See complete example](Examples/LargeDatasetHandling/)

## Device & OS Requirements

### Minimum Supported Versions

| Platform | Minimum | Recommended |
|----------|---------|-------------|
| iOS | 14.0 | 17.0+ |
| macOS | 11.2 | 13.0+ |
| Xcode | 14.0 | 16.0+ |
| Swift | 5.9 | 5.10+ |

### Metal Family Support

| Device | GPU Family | Supported |
|--------|-----------|-----------|
| iPhone 6s/7 | A10 | Yes (limited) |
| iPhone Xs+ | A12+ | Yes (full) |
| iPad Air 2+ | A9X+ | Yes |
| iPad Pro (all) | A10X+ | Yes |
| Mac (Intel) | 2nd gen+ | Yes |
| Mac (Apple Silicon) | All | Yes |

### GPU Capability Requirements

**Required Features:**
- 3D textures (for volume rendering)
- Rasterization (for depth/color output)
- Compute kernels (for optimized rendering)

**Optional Features:**
- MSAA (multi-sample anti-aliasing)
- Programmable blending
- Parallel render encoding

## Performance Characteristics

### Typical Memory Footprint

| Dataset Size | GPU Memory | RAM Required |
|--------------|-----------|--------------|
| 256³ voxels | 64MB | 128MB |
| 512³ voxels | 512MB | 1GB |
| 1024³ voxels | 4GB | 8GB |

**Note:** Actual values depend on pixel format and precision. Use 8-bit (uint8) for minimum footprint.

### Rendering Performance Expectations

| Operation | Time | Device |
|-----------|------|--------|
| Raycaster init | 5-10ms | All |
| Dataset load (100MB) | 50-200ms | iPhone 12+ |
| Frame render (DVR) | 8-16ms @ 60FPS | iPhone 12+ |
| Window/level update | <1ms | All |
| Transfer function change | <5ms | All |

### Optimization Tips

1. **Reduce Resolution:**
   ```swift
   // Render at 75% screen resolution for 2x speedup
   raycaster.setRenderScale(0.75)
   ```

2. **Enable Adaptive Sampling:**
   ```swift
   raycaster.enableAdaptiveSampling(threshold: 0.01)
   ```

3. **Use Lower Precision:**
   ```swift
   // Use uint8 instead of float16 (8x memory savings)
   let dataset = VolumeDataset(..., pixelFormat: .uint8)
   ```

4. **Cache Transfer Functions:**
   ```swift
   // Reuse compiled transfer functions
   let cachedTF = TransferFunctionCache.retrieve(name: "CT Bone")
   ```

## Troubleshooting

### Metal Device Not Found

**Symptom:** `Error.unsupportedDevice` on app launch

**Cause:** Device doesn't support 3D textures (pre-A9 or simulator limitations)

**Solution:**
```swift
// Check device capability
if MetalRaycaster.isSupported(device: device) {
    raycaster = try MetalRaycaster(device: device)
} else {
    // Fallback to CPU renderer
    setupCPURenderer()
}
```

### Shader Compilation Issues

**Symptom:** "Metal shader compilation failed" during build

**Cause:** Metal shaders not properly included or contain syntax errors

**Solution:**
1. Verify `.metal` files in Build Phases → Compile Sources
2. Check shader syntax with Metal compiler
3. Rebuild: `xcodebuild clean && xcodebuild build`

### Out of GPU Memory During Texture Upload

**Symptom:** `Error.datasetUnavailable` when loading large volume

**Cause:** GPU doesn't have enough VRAM for full-resolution texture

**Solution:**
```swift
// Check available GPU memory
let availableMemory = MTLCreateSystemDefaultDevice()!.currentAllocatedSize
let requiredMemory = dataset.estimatedMemoryUsage

if availableMemory < requiredMemory {
    // Downsample or stream
    let downsampled = dataset.downsample(factor: 2)
    resources = try raycaster.load(dataset: downsampled)
}
```

### Slow Rendering Performance

**Symptom:** Frame rate drops below 30 FPS

**Cause:** Render resolution too high or adaptive sampling disabled

**Solution:**
```swift
// Enable adaptive sampling
raycaster.enableAdaptiveSampling(threshold: 0.01)

// Reduce render resolution
raycaster.setRenderScale(0.75)  // Render at 75% resolution

// Use MIP projection (faster than DVR)
raycaster.setRenderMode(.mip)
```

### Common Integration Pitfalls

**Pitfall 1: Mixing Thread Contexts**
```swift
// WRONG: Calling from background thread
DispatchQueue.global().async {
    raycaster.load(dataset: dataset)  // Crashes!
}

// RIGHT: Call on render thread
raycaster.load(dataset: dataset)  // Safe
```

**Pitfall 2: Not Releasing Resources**
```swift
// WRONG: GPU memory leak
volumeRenderer = nil  // Doesn't release GPU resources

// RIGHT: Explicit cleanup
raycaster.resetCaches()  // Frees GPU memory
volumeRenderer = nil
```

**Pitfall 3: Invalid Pixel Format**
```swift
// WRONG: Unsupported format
try raycaster.load(dataset: dataset, pixelFormat: .rgba16)

// RIGHT: Use supported format
try raycaster.load(dataset: dataset, pixelFormat: .rgba8Unorm)
```

## Architecture

- [Rendering Pipeline](Documentation/RenderingPipeline.md) — How data flows from dataset to screen
- [Coordinate Transformations](Documentation/CoordinateTransformations.md) — Voxel/World/Texture spaces
- [Transfer Functions](Documentation/TransferFunctions.md) — Intensity to color/opacity mapping
- [Design Decisions (ADRs)](Documentation/adr/) — Architecture decision records

## Documentation

- API reference (DocC) — Available via Xcode documentation
- Example projects — See [Examples/](Examples/) directory
- Shaders and resources live inside each target's `Resources` folder and are available via `Bundle.module`.

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
