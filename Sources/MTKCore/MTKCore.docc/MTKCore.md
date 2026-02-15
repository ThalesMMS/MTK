# ``MTKCore``

Core rendering engine and domain models for medical volumetric visualization with Metal.

## Overview

MTKCore provides the foundational building blocks for GPU-accelerated medical volume rendering on iOS and macOS. Built on Metal and Metal Performance Shaders, it supports Direct Volume Rendering (DVR), Maximum Intensity Projection (MIP), and Multi-Planar Reconstruction (MPR).

The framework handles the pipeline from DICOM data loading through GPU texture creation, ray marching computation, and transfer function application.

### Key Features

- **Metal Rendering**: Ray marching with adaptive sampling and empty space skipping
- **Medical Imaging**: Hounsfield unit windowing, transfer function presets, and DICOM integration
- **Data Loading**: Protocol-based DICOM loading with ZIP archive support and progress tracking
- **Transfer Functions**: Multi-channel tone curves, opacity mapping, and preset libraries for CT/MR visualization
- **Runtime Safety**: Graceful degradation and runtime capability detection

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

Low-level Metal helpers for texture creation, shader loading, and GPU resource management.

- ``VolumeTextureFactory``
- ``ShaderLibraryLoader``
- ``MetalRuntimeAvailability``
- ``BackendResolver``

### Compute Utilities

GPU compute pipelines for histogram calculation and empty space acceleration.

- ``VolumeHistogramCalculator``
- ``MPSEmptySpaceAccelerator``

### Guides

- <doc:VolumeRenderingGuide>
- <doc:MPRGuide>
- <doc:TransferFunctionsGuide>
- <doc:DicomLoadingGuide>

## Quick Start

Create a basic volume rendering setup:

```swift
import MTKCore
import Metal

// Create Metal device
guard let device = MTLCreateSystemDefaultDevice() else {
    fatalError("Metal not available")
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
let renderer = MetalVolumeRenderingAdapter()

// Configure for medical CT visualization
try await renderer.setHuWindow(min: -500, max: 1200)
try await renderer.setPreset(.softTissue)
```

## Platform Requirements

- iOS 17.0+ / macOS 14.0+
- Swift 5.10+
- Xcode 16+
- Metal-capable device (tests skip gracefully when unavailable)
- Metal Performance Shaders (optional, enables histogram/gaussian optimizations)

## See Also

- ``MTKSceneKit`` — SceneKit integration layer for volume materials and camera control
- ``MTKUI`` — SwiftUI components and controllers for volumetric visualization
