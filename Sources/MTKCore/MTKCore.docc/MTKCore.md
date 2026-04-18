# ``MTKCore``

Core rendering engine and domain models for medical volumetric visualization with Metal.

## Overview

MTKCore provides the foundational building blocks for GPU-accelerated medical volume rendering on iOS and macOS. Built on Metal with optional Metal Performance Shaders acceleration, it supports Direct Volume Rendering (DVR), Maximum Intensity Projection (MIP), and Multi-Planar Reconstruction (MPR).

The framework handles the pipeline from DICOM data loading through GPU texture creation, ray marching computation, and transfer function application.

### Key Features

- **Metal Rendering**: Metal ray marching with adaptive sampling; MPS-accelerated empty space skipping is an inspectable capability
- **Medical Imaging**: Hounsfield unit windowing, transfer function presets, and DICOM integration
- **Data Loading**: Protocol-based DICOM loading with ZIP archive support and progress tracking
- **Transfer Functions**: Multi-channel tone curves, opacity mapping, and preset libraries for CT/MR visualization
- **Runtime Capability Contracts**: Runtime capability detection with explicit error reporting before Metal-only features are initialized

## Topics

### Essentials

- <doc:GettingStarted>
- ``VolumeDataset``
- ``MetalVolumeRenderingAdapter``
- ``DicomVolumeLoader``

### Volume Data Management

Volume datasets encapsulate 3D medical imaging data with spatial metadata and pixel format information.

- ``VolumeDataset``
- ``VolumeDimensions``
- ``VolumeSpacing``
- ``VolumeOrientation``
- ``VolumePixelFormat``

### Rendering Adapters

Rendering adapters provide the interface between your application and the Metal-based rendering pipeline.

- ``MetalVolumeRenderingAdapter``
- ``MetalMPRAdapter``
- ``MetalRaycaster``
- ``VolumeRenderingMode``
- ``VolumeRenderingConfig``

### Transfer Functions

Transfer functions map volume intensities to visual properties (color and opacity) for medical visualization.

- ``AdvancedToneCurveModel``
- ``VolumeTransferFunctionLibrary``
- ``TransferFunction``
- ``VolumeRenderingPreset``
- ``ToneCurveConfiguration``

### DICOM Loading

Protocol-based DICOM series loading with support for sorting, spacing calculation, and ZIP extraction.

- ``DicomVolumeLoader``
- ``DicomSeriesLoading``
- ``DicomDecoderSeriesLoader``
- ``DicomLoadingProgress``

### Metal Utilities

Low-level Metal helpers for texture creation, required shader artifact loading, GPU resource management, and enforcing Metal-only runtime requirements so apps can surface explicit unsupported states before initialization.

- ``VolumeTextureFactory``
- ``ShaderLibraryLoader``
- ``MetalRuntimeAvailability``
- ``BackendResolver``

### Compute Utilities

Pure Metal compute pipelines for histogram calculation and optional MPS empty space acceleration.

- ``VolumeHistogramCalculator``
- ``VolumeStatisticsCalculator``
- ``MPSEmptySpaceAccelerator``

### Guides

- <doc:VolumeRenderingGuide>
- <doc:MPRGuide>
- <doc:TransferFunctionsGuide>
- <doc:DicomLoadingGuide>

## Quick Start

Create a basic volume rendering setup. Volume rendering is Metal-only, so enforce the runtime requirement before constructing the adapter and surface an explicit unsupported state when the requirement is not met.

```swift
import MTKCore
import Metal

do {
    try MetalRuntimeAvailability.ensureAvailability()
} catch {
    let status = MetalRuntimeAvailability.status()
    print("Metal runtime unsupported: \(status.missingFeatures)")
    throw error
}

// Create Metal device.
guard let device = MTLCreateSystemDefaultDevice() else {
    throw MetalVolumeRenderingAdapter.InitializationError.metalDeviceUnavailable
}

// Create volume dataset from your voxel data
let voxelCount = 256 * 256 * 128
let voxels = Data(repeating: 0, count: voxelCount * VolumePixelFormat.int16Signed.bytesPerVoxel)

let dataset = VolumeDataset(
    data: voxels,
    dimensions: VolumeDimensions(width: 256, height: 256, depth: 128),
    spacing: VolumeSpacing(x: 0.001, y: 0.001, z: 0.0015),
    pixelFormat: .int16Signed,
    intensityRange: (-1024)...3071
)

// Create rendering adapter
let renderer = try MetalVolumeRenderingAdapter(device: device)

// Configure for medical CT visualization
try await renderer.setHuWindow(min: -500, max: 1200)
try await renderer.setPreset(.softTissue)
```

## Platform Requirements

- iOS 17.0+ / macOS 14.0+
- Swift 5.10+
- Xcode 16+
- Metal-capable device required for rendering and GPU test coverage. Metal is the runtime contract for rendering; GPU-dependent tests require Metal and skip when unavailable.
- Metal Performance Shaders optional; enables specific acceleration paths such as ``MPSEmptySpaceAccelerator`` when reported available. Core volume rendering, histogram calculation, and statistics calculation do not require MPS.

## Platform Behavior

### Metal required for rendering

All rendering surfaces and adapters require a Metal-capable device. ``MetalVolumeRenderingAdapter``, ``MetalRaycaster``, and ``MetalMPRAdapter`` report initialization or rendering errors instead of constructing a non-GPU renderer. Applications should enforce this requirement with ``MetalRuntimeAvailability`` or ``BackendResolver`` and present an explicit unsupported state when the requirement is not met.

``VolumeHistogramCalculator`` is pure Metal compute with no MPS dependency. ``VolumeStatisticsCalculator`` provides GPU compute plus a CPU implementation for environments without GPU compute; that CPU path is a statistics implementation, not a volume-rendering mode.

### MPS optional acceleration

Metal Performance Shaders provide optional acceleration for specific features. ``MPSEmptySpaceAccelerator`` is available only when `MPSSupportsMTLDevice(_:)` is true and reports feature unavailability when MPS is not supported. Core volume rendering remains the Metal ray marching path.

MPR texture conversion can use MPS image conversion for compatible 2D normalized or float formats when MPS support is reported available. The Metal blit encoder path handles 3D textures, signed integer formats, incompatible formats, and devices without MPS.

## See Also

- ``MTKSceneKit`` — SceneKit integration layer for volume materials and camera control
- ``MTKUI`` — SwiftUI components and controllers for volumetric visualization
