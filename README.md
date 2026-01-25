# MTK — Metal Toolkit for volumetric rendering

Swift Package with Metal/SceneKit/SwiftUI helpers used by the Metal-MPR-VR stack. The code currently ships the rendering pipelines, materials, SwiftUI overlays, and DICOM loader bridge used by the demo app—no legacy migration notes or placeholder APIs.

## Package layout
- `MTKCore` — Domain types (`VolumeDataset`, orientation/spacing models), Metal helpers (`MetalRaycaster`, `VolumeTextureFactory`, `ShaderLibraryLoader`), transfer function models (`AdvancedToneCurveModel`, `VolumeTransferFunctionLibrary`), runtime availability guards, and the `DicomVolumeLoader` that wraps an injected `DicomSeriesLoading` bridge.
- `MTKSceneKit` — SceneKit materials and camera helpers (`VolumeCubeMaterial`, `MPRPlaneMaterial`, `VolumeCameraController`, SceneKit node extensions).
- `MTKUI` — SwiftUI-friendly controllers and overlays (`VolumetricSceneController`, `VolumetricSceneCoordinator`, `VolumetricDisplayContainer`, gesture modifiers, overlays like `CrosshairOverlayView`, `WindowLevelControlView`, and `MPRGridComposer` for tri-planar layouts).

## Requirements
- Swift 5.10, Xcode 16
- iOS 17+ / macOS 14+
- Metal-capable device (tests skip when Metal is unavailable)
- Metal Performance Shaders unlock histogram/gaussian paths but the stack falls back when MPS is absent

## Add via Swift Package Manager
Point Xcode/SwiftPM at the `MTK` directory (local checkout or Git URL) and depend on the library products you need:

```swift
.package(path: "../MTK"), // or the Git URL that points to this directory
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "MTKCore", package: "MTK"),
        .product(name: "MTKSceneKit", package: "MTK"),
        .product(name: "MTKUI", package: "MTK")
    ]
)
```

## Shaders and resources
- Build-tool plugin `MTKShaderPlugin` compiles `Sources/MTKCore/Resources/Shaders/*.metal` into `MTK.metallib` during the build. At runtime `ShaderLibraryLoader` first looks for a bundled `VolumeRendering.metallib`, then falls back to the module’s default library or runtime compilation of the shader sources.
- CI/manual fallback: `bash Tooling/Shaders/build_metallib.sh Sources/MTKCore/Resources/Shaders .build/MTK.metallib`
- Sample RAW datasets referenced by `VolumeTextureFactory(preset:)` are not shipped; presets will fall back to a 1³ placeholder unless you add zipped RAW assets to `Sources/MTKCore/Resources`.

## Quick start (SwiftUI)
Minimal SwiftUI viewer that applies a volume and overlays UI controls:

```swift
import MTKCore
import MTKUI
import SwiftUI

struct VolumePreview: View {
    @StateObject private var coordinator = VolumetricSceneCoordinator.shared

    var body: some View {
        VolumetricDisplayContainer(controller: coordinator.controller) {
            OrientationOverlayView()
            CrosshairOverlayView()
        }
        .task {
            // Build a dataset from your own voxel buffer
            let voxelCount = 256 * 256 * 128
            let voxels = Data(repeating: 0, count: voxelCount * VolumePixelFormat.int16Signed.bytesPerVoxel)
            let dataset = VolumeDataset(
                data: voxels,
                dimensions: VolumeDimensions(width: 256, height: 256, depth: 128),
                spacing: VolumeSpacing(x: 0.001, y: 0.001, z: 0.0015),
                pixelFormat: .int16Signed,
                intensityRange: (-1024)...3071
            )

            coordinator.apply(dataset: dataset)
            coordinator.applyHuWindow(min: -500, max: 1200)
            await coordinator.controller.setPreset(.softTissue)
        }
    }
}
```

Add gesture handling with `volumeGestures(controller:state:configuration:)` and multi-plane layouts with `MPRGridComposer` when you need synchronized axial/coronal/sagittal slices.

## Loading DICOM volumes
`DicomVolumeLoader` orchestrates ZIP extraction and dataset construction but expects a `DicomSeriesLoading` implementation to feed slice data (see `LegacyDicomSeriesLoader` in MTK-Demo for a GDCM-backed bridge). Progress updates can be mapped to UI with `DicomVolumeLoader.uiUpdate(from:)`.

## Runtime checks and diagnostics
- `BackendResolver` and `MetalRuntimeAvailability` gate Metal usage before creating controllers.
- `CommandBufferProfiler`, `MetalRuntimeGuard`, and `VolumeRenderingDebugOptions` help surface GPU/runtime capabilities during development.

## Testing notes
- `swift test` requires a Metal-capable host; GPU-dependent suites skip automatically when no device is available.
- DICOM-related tests expect fixtures under `MTK-Demo/DICOM_Example` (not committed). Tests will skip when fixtures or the native bridge are missing.

## License
Apache 2.0. See `LICENSE`.
