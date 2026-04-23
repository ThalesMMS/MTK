# MTK — Metal Toolkit for volumetric rendering

![Swift 5.10](https://img.shields.io/badge/Swift-5.10-orange.svg)
![Xcode 16](https://img.shields.io/badge/Xcode-16-blue.svg)
![iOS 17+](https://img.shields.io/badge/iOS-17%2B-lightgrey.svg)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey.svg)
![License](https://img.shields.io/badge/License-Apache%202.0-green.svg)

Swift Package with Metal-native volume rendering, SwiftUI overlays, and DICOM loader bridges. Metal is the only official clinical renderer. Interactive clinical frames are `MTLTexture` outputs presented through `MTKView` or `CAMetalLayer`; `CGImage` is allowed only for explicit export, snapshot, debug, and test readback use cases behind `SnapshotExporting`/`TextureSnapshotExporter`.

![UI Screenshot](screenshots/ui.png)

## Package layout
- `MTKCore` — Domain types (`VolumeDataset`, orientation/spacing models), Metal helpers (`MetalRaycaster`, `VolumeTextureFactory`, `ShaderLibraryLoader`), transfer function models (`AdvancedToneCurveModel`, `VolumeTransferFunctionLibrary`), runtime availability guards, and the `DicomVolumeLoader` that wraps an injected `DicomSeriesLoading` bridge.
- `MTKUI` — SwiftUI-friendly controllers and overlays (`VolumeViewportController`, `VolumeViewportCoordinator`, `VolumeViewportContainer`, `MetalViewportView`, `MetalViewportContainer`, `MetalViewportSurface`, gesture modifiers, overlays like `CrosshairOverlayView`, `WindowLevelControlView`, and `MPRGridComposer` for tri-planar layouts). MTKUI is the current UI layer over MTKCore Metal volume/MPR adapters. `MetalViewportSurface` is the official clinical `MTKView` presentation surface.

## Architecture
The accepted clinical rendering architecture is documented in [Architecture/ClinicalRenderingADR.md](Architecture/ClinicalRenderingADR.md).

```text
DICOM / VolumeDataset
        |
        v
VolumeResourceManager
        |
        v
GPU volume texture / transfer texture / auxiliary textures
        |
        v
MTKRenderingEngine
        |
        v
ViewportRenderGraph
        |
        v
VolumeRaycastPass / MPRReslicePass / MIPPass / OverlayPass
        |
        v
PresentationPass
        |
        v
MTKView / CAMetalLayer drawable
```

Metal-native rendering is the only official clinical backend. The target interactive presentation surface is `MTKView`/`CAMetalLayer`, with `MTLTexture` as the frame result handed to the presentation pass. Viewports are expected to share GPU resources through handles owned by a resource manager, so synchronized volume, MPR, projection, and overlay views consume the same volume textures, transfer textures, and auxiliary textures instead of duplicating them per surface.

Bounding geometry can be a valid internal implementation detail for ray entry and ray exit inside a specialized pass. It does not change the public clinical rendering architecture.

`MetalViewportSurface` is the official MTKUI surface for drawable-backed clinical presentation. It presents completed 2D `MTLTexture` frames through `PresentationPass` into an `MTKView` drawable without `CGImage` conversion. The primary flow is `compute/render pass -> persistent outputTexture -> PresentationPass -> drawable -> present`; compute directly into the drawable is not the main path because drawables are ephemeral presentation targets, acquisition can be display-paced, and presented drawables cannot be reused for scheduling, inspection, export, or overlay composition.

## Requirements
- Swift 5.10, Xcode 16
- iOS 17+ / macOS 14+
- Metal-capable device required for rendering and GPU test coverage. Metal is the runtime contract for rendering; no alternate rendering runtime is provided. GPU-dependent tests require Metal and skip when unavailable.
- Metal Performance Shaders behavior is feature-specific and should be treated as an explicit capability/result contract:
  - Volume rendering (`MetalVolumeRenderingAdapter`, `MetalRaycaster`): Pure Metal ray marching is the required rendering path on Metal-capable devices and has no MPS dependency.
  - Empty-space acceleration (`MPSEmptySpaceAccelerator`): Optional MPS accelerator for supported devices. Shared helpers return `.success`, `.unavailable(reason:)`, or `.failed(error)` instead of `nil`.
  - Histogram calculation (`VolumeHistogramCalculator`): Pure Metal compute. No MPS dependency.
  - Statistics calculation (`VolumeStatisticsCalculator`): Metal compute with explicit GPU setup and execution errors. CPU reference implementations exist only in tests.

## Intended use and safety
MTK is a rendering and UI toolkit for research, education, and prototype applications involving volumetric medical-image data on Apple platforms. It is **not** a medical device, has **not** been validated for clinical decision-making, and should not be the sole basis for diagnosis, treatment, or patient triage.

If you load real DICOM studies, keep PHI handling, local security, and institutional review requirements in mind. The repository demonstrates rendering infrastructure and loading patterns; it does not claim regulatory clearance, dataset-wide clinical validation, or diagnostic performance.

## Add via Swift Package Manager
Point Xcode/SwiftPM at the `MTK` directory (local checkout or Git URL) and depend on the library products you need:

```swift
.package(path: "../MTK"), // or the Git URL that points to this directory
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "MTKCore", package: "MTK"),
        .product(name: "MTKUI", package: "MTK")
    ]
)
```

SceneKit examples may be extracted to a separate experimental package in the future, but they are not part of the main package contract.

### Migration map for former MTKSceneKit consumers
- Replace `MTKSceneKit` volume presentation (`VolumeCubeMaterial`) with `MTKCore` rendering through `MetalVolumeRenderingAdapter` and present the resulting frames with `MTKUI` containers such as `VolumeViewportContainer` and `MetalViewportSurface`.
- Replace `MTKSceneKit` MPR presentation (`MPRPlaneMaterial`) with `MetalMPRAdapter` plus `MTKUI` layouts such as `MPRGridComposer` or `TriplanarMPRComposer`.
- Replace `VolumeCameraController` and `CameraPose`-driven interaction with `VolumeViewportController`, `VolumeViewportCoordinator`, and `volumeGestures(controller:state:configuration:)`.
- Replace node/plane helper usage (`SCNNode+Volumetric`) with geometry and display helpers that stay in the Metal-native path, such as `MPRPlaneGeometryFactory` and `MPRDisplayTransformFactory`.
- If you still need a standalone 3D wrapper for non-clinical experiments, keep that code outside the main package. There is no maintained `SceneKitExamples` package in this repository today.

Recommended vs Legacy:
- Recommended: `MetalVolumeRenderingAdapter` + `VolumeViewportContainer` / Legacy: deprecated `VolumeCubeMaterial`
- Recommended: `MetalMPRAdapter` + `MPRGridComposer` or `TriplanarMPRComposer` / Legacy: deprecated `MPRPlaneMaterial`
- Recommended: `VolumeViewportController` or `VolumeViewportCoordinator` / Legacy: deprecated `VolumeCameraController`, `CameraPose`, `SCNNode+Volumetric`

Compatibility note:
- The current MTK package requires iOS 17+ and macOS 14+. Downstream apps that still need older platform support or a custom 3D wrapper should keep that compatibility layer outside this package.
- Example code for the supported migration path lives in [`Examples/BasicVolumeRendering.swift`](Examples/BasicVolumeRendering.swift), [`Examples/MPRViewer.swift`](Examples/MPRViewer.swift), [`Examples/TriplanarMPRViewer.swift`](Examples/TriplanarMPRViewer.swift), and [`Examples/DicomLoader.swift`](Examples/DicomLoader.swift).

## Reproducible local setup
`Package.swift` currently declares `DICOM-Decoder` as a local path dependency (`./DICOM-Decoder`). For a clean checkout, place the repositories side by side before resolving dependencies:

```bash
mkdir mtk-workspace
cd mtk-workspace
git clone https://github.com/ThalesMMS/DICOM-Decoder.git
git clone https://github.com/ThalesMMS/MTK.git
cd MTK/MTK
swift package resolve
swift build
```

Minimal smoke test that does not require private fixtures:

```bash
swift test --filter DicomVolumeLoaderSecurityTests
```

For broader testing on a Metal-capable Mac:

```bash
swift test
```

Some DICOM-oriented tests rely on optional local fixtures from `MTK-Demo/DICOM_Example` that are **not** committed to this repository. To use them, clone the demo repository as a sibling checkout with `git clone https://github.com/ThalesMMS/MTK-Demo.git ../MTK-Demo`. Those suites skip when fixtures are unavailable, so a passing run may still be partial on a fresh machine.

## Shaders and resources
- `ShaderLibraryLoader` requires `MTK.metallib` to be bundled in `Bundle.module`. Missing or invalid artifacts are reported as structured `ShaderLibraryLoader.LoaderError` cases, such as `metallibNotBundled` or `metallibLoadFailed(underlying:)`.
- Build-tool plugin `MTKShaderPlugin` compiles `Sources/MTKCore/Resources/Shaders/*.metal` into the required `MTK.metallib` artifact during the build. The plugin must complete successfully for the package's Metal rendering paths to function.
- Manual shader build is only needed when compiling shaders outside the normal SwiftPM/Xcode plugin path, such as custom command-line packaging or CI steps that assemble resources separately: `bash Tooling/Shaders/build_metallib.sh Sources/MTKCore/Resources/Shaders .build/MTK.metallib`
- Troubleshooting: if shader loading fails, verify that `MTKShaderPlugin` ran successfully and that `MTK.metallib` is present in the `MTKCore` resource bundle.
- Sample RAW datasets referenced by `VolumeTextureFactory(preset:)` are not shipped by default. Missing or invalid preset resources throw `VolumeTextureFactory.PresetLoadingError`; preset loading does not silently return a stub volume.
- Preset resource failures are inspectable through `resourceNotBundled`, `archiveUnreadable`, `extractionFailed`, `emptyPayload`, and `noDataAvailable`.
- Use `VolumeTextureFactory.debugPlaceholderDataset()` only for tests or explicit debug tooling that needs a minimal 1x1x1 volume.

## Quick start (SwiftUI)
Minimal SwiftUI viewer that applies a volume and overlays UI controls:

```swift
import MTKCore
import MTKUI
import SwiftUI

struct VolumePreview: View {
    @StateObject private var coordinator = VolumeViewportCoordinator.shared

    var body: some View {
        if let controller = coordinator.controller {
            VolumeViewportContainer(controller: controller) {
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
                await controller.setPreset(.softTissue)
            }
        } else {
            Text("Metal unavailable")
        }
    }
}
```

Add gesture handling with `volumeGestures(controller:state:configuration:)` and multi-plane layouts with `MPRGridComposer` when you need synchronized axial/coronal/sagittal slices.

## Loading DICOM volumes
`DicomVolumeLoader` orchestrates ZIP extraction and dataset construction through the pure-Swift `DicomDecoderSeriesLoader`, the canonical `DicomSeriesLoading` implementation for this package and demo. The protocol remains in place so tests and package integrators can inject mock or specialized loaders, but the demo does not use it for runtime backend switching. Progress updates can be mapped to UI with `DicomVolumeLoader.uiUpdate(from:)`.

## Expected inputs and outputs
**Typical inputs**
- A synthetic or programmatically generated voxel buffer wrapped in `VolumeDataset`
- A DICOM directory, ZIP archive, or individual file routed through `DicomVolumeLoader`
- 16-bit scalar volume data with spatial metadata available for reconstruction

**Typical outputs**
- An in-memory `VolumeDataset` ready for rendering
- `DicomImportResult` metadata such as `sourceURL` and `seriesDescription`
- Interactive `MTLTexture` frame outputs for drawable-backed presentation
- SwiftUI rendering surfaces, MPR views, overlays, and transfer-function-driven visualization backed by MTKCore Metal adapters

MTK does **not** produce segmentation masks, classification labels, radiology reports, or treatment recommendations by itself. In other words, the package is a visualization/loading substrate, not a diagnostic model.

## Runtime checks and diagnostics
- `BackendResolver` and `MetalRuntimeAvailability` enforce the Metal rendering requirement before controllers are created. `ensureAvailability()` throws explicit availability errors, and `status()` exposes structured diagnostics plus optional MPS capability flags.
- `MetalRuntimeGuard` exposes structured requirement status, missing required capabilities, and optional MPS feature availability for diagnostics.
- `CommandBufferProfiler` and `VolumeRenderingDebugOptions` help surface GPU runtime behavior during development.

```swift
func makeVolumeController() throws -> VolumeViewportController {
    try MetalRuntimeAvailability.ensureAvailability()
    let status = MetalRuntimeAvailability.status()
    print("MPS available: \(status.supportsMetalPerformanceShaders)")
    return VolumeViewportController()
}

do {
    let controller = try makeVolumeController()
    print(controller)
} catch {
    let status = MetalRuntimeAvailability.status()
    print("Metal requirement failed: \(status.missingFeatures)")
    print("MPS available: \(status.supportsMetalPerformanceShaders)")
}
```

## Testing notes
- `swift test` requires a Metal-capable host for GPU-dependent suites; those tests require Metal and skip when unavailable.
- DICOM-related tests can use optional fixtures under `MTK-Demo/DICOM_Example` from `https://github.com/ThalesMMS/MTK-Demo`; clone it as a sibling checkout with `git clone https://github.com/ThalesMMS/MTK-Demo.git ../MTK-Demo`. Tests will skip when fixtures are missing.
- Security coverage includes ZIP path-traversal regression tests for `DicomVolumeLoader`; visual-quality checks compare MPS-accelerated empty-space skipping (feature availability requires MPS) against core Metal ray marching on synthetic datasets.

## Limitations and evaluation caveats
- The package targets Apple-platform rendering workflows; it is not a cross-platform PACS, archive, or viewer.
- Clean reproducibility currently depends on a sibling checkout of `DICOM-Decoder` because the dependency is path-based.
- Public examples and tests mostly exercise synthetic datasets, renderer behaviors, and optional local fixtures rather than a versioned benchmark corpus committed in this repository.
- Rendering correctness checks and visual-regression tests are useful engineering signals, but they are **not** the same thing as clinical validation or reader-study evidence.
- DICOM import support depends on the Swift decoder's metadata coverage and input quality. Import failures are explicit:
  - unsupported transfer syntaxes, compressed pixel encodings, malformed datasets, or missing required tags surface parser-specific errors from `DicomDecoderSeriesLoader`, wrapped as `DicomVolumeLoaderError.bridgeError(_:)` when reported through the bridge;
  - empty directories or parser runs that produce no voxel data report `DicomVolumeLoaderError.missingResult`;
  - non-16-bit scalar data, 8-bit or 12-bit inputs, and RGB or multi-component volumes report `DicomVolumeLoaderError.unsupportedBitDepth`;
  - ZIP entries with path traversal report `DicomVolumeLoaderError.pathTraversal`.

## Documentation

DocC documentation covers the two modules (`MTKCore`, `MTKUI`) with API reference, conceptual guides, and a Getting Started tutorial. The clinical rendering decision lives in `Architecture/ClinicalRenderingADR.md`. Runnable examples are in the `Examples/` directory.

Generate documentation locally:

```bash
bash Tooling/build_docs.sh
```

This creates `.doccarchive` files in the `docs/` directory that can be opened in Xcode or hosted as static HTML.

## License
Apache 2.0. See `LICENSE`.
