# Multi-Planar Reconstruction (MPR)

A comprehensive guide to multi-planar reconstruction techniques for visualizing volumetric medical imaging data along orthogonal and oblique planes.

## Overview

Multi-Planar Reconstruction (MPR) is a fundamental medical imaging technique that extracts 2D cross-sectional views from 3D volumetric datasets. Unlike volume rendering (which projects the entire 3D dataset onto 2D), MPR generates precise 2D slices along arbitrary planes through the volume, enabling clinicians to examine anatomy from any viewing angle.

MTKCore's MPR implementation provides:

- **Orthogonal slicing**: Standard axial, coronal, and sagittal anatomical planes
- **Oblique reconstruction**: Arbitrary plane orientations for specialized views
- **Thick-slab MPR**: Average/blend multiple parallel slices for noise reduction
- **Metal acceleration**: Metal compute shaders for real-time performance (2–5 ms per slice)
- **Explicit Metal failures**: Missing Metal resources surface as errors for callers to handle

All MPR operations preserve spatial accuracy, respecting the volume's pixel spacing and orientation metadata for anatomically correct reconstructions.

## Core Concepts

### Anatomical Planes

Medical imaging uses three standard orthogonal planes aligned with patient anatomy:

- **Axial (Transverse/Horizontal)** — Divides body into superior (top) and inferior (bottom) sections
  - Primary axis: Z (slice through depth)
  - Orientation labels: R (right), L (left), A (anterior/front), P (posterior/back)
  - Use cases: CT chest, abdomen, brain; standard radiological view

- **Coronal (Frontal)** — Divides body into anterior (front) and posterior (back) sections
  - Primary axis: Y (slice front-to-back)
  - Orientation labels: R (right), L (left), S (superior/top), I (inferior/bottom)
  - Use cases: Sinus imaging, spine alignment, cardiac structures

- **Sagittal (Lateral)** — Divides body into left and right sections
  - Primary axis: X (slice side-to-side)
  - Orientation labels: A (anterior/front), P (posterior/back), S (superior/top), I (inferior/bottom)
  - Use cases: Spine curvature, midline structures, brain symmetry

```swift
// Represented by MPRPlaneAxis enumeration
public enum MPRPlaneAxis: Int {
    case x = 0  // Sagittal
    case y = 1  // Coronal
    case z = 2  // Axial
}
```

### Coordinate Systems

MPR plane geometry uses three coordinate spaces for precise spatial calculations:

1. **Voxel Space** — Integer grid coordinates (0, 0, 0) to (width-1, height-1, depth-1)
   - Native storage format
   - No spacing or orientation applied
   - Fastest for direct memory access

2. **World Space** — Physical coordinates in millimeters accounting for spacing and orientation
   - Respects DICOM Image Orientation Patient (IOP) and Image Position Patient (IPP)
   - Enables anatomically accurate measurements
   - Used for cross-dataset registration

3. **Texture Space** — Normalized coordinates [0, 1]³ for GPU sampling
   - Required by Metal texture samplers
   - Facilitates oblique plane interpolation
   - Hardware-accelerated trilinear filtering

The ``MPRPlaneGeometry`` structure maintains all three representations simultaneously:

```swift
public struct MPRPlaneGeometry {
    // Voxel space (integer grid coordinates)
    public var originVoxel: SIMD3<Float>
    public var axisUVoxel: SIMD3<Float>
    public var axisVVoxel: SIMD3<Float>

    // World space (millimeters, respects orientation)
    public var originWorld: SIMD3<Float>
    public var axisUWorld: SIMD3<Float>
    public var axisVWorld: SIMD3<Float>

    // Texture space ([0,1] normalized for GPU)
    public var originTexture: SIMD3<Float>
    public var axisUTexture: SIMD3<Float>
    public var axisVTexture: SIMD3<Float>

    // World space normal vector
    public var normalWorld: SIMD3<Float>
}
```

### Plane Definition

An MPR plane is defined by:
- **Origin point**: Starting corner of the 2D slice in 3D space
- **U-axis vector**: Defines the slice's horizontal direction and width
- **V-axis vector**: Defines the slice's vertical direction and height
- **Normal vector**: Perpendicular to the plane (cross product of U and V axes)

The U and V axes form a right-handed coordinate system spanning the 2D slice rectangle, while the normal vector indicates the "through-plane" direction for slab sampling.

### Clinical Numeric Contract

MPR correctness is defined numerically, not by visual plausibility alone. MTKCore treats ``ImageData3D`` as the source of truth for geometry and intensity:

- Voxel index coordinates are continuous and map to world coordinates through the full affine: direction matrix, spacing, and origin.
- Axial, coronal, and sagittal planes are derived from the dataset geometry; they must not be reduced to raw buffer axes when orientation or origin is non-identity.
- Texture coordinates use the `(index + 0.5) / dimensions` voxel-center convention before GPU sampling.
- Oblique planes must be expressed through world-space geometry and converted with `worldToTexture`, preserving anisotropic spacing and non-zero origins.
- Signed `Int16` values and negative HU ranges remain raw MPR intensity values until presentation applies window/level.
- DICOM rescale slope/intercept is applied during import, so MPR consumes modality values rather than unsigned stored pixel values.

The regression suite uses deterministic synthetic phantoms and CPU oracles for identity MPR, oblique affine planes, anisotropic slabs, MIP, MinIP, mean slabs, signed negative HU, and DICOM-imported slope/intercept data. These tests are intended to fail when a change samples the wrong voxel, drops orientation metadata, uses the wrong slab extent, or collapses signed modality values into unsigned storage.

## Slab Generation

### Single Slice vs Thick Slab

MPR supports two slicing modes:

1. **Single slice** — Extract one 2D plane at the specified position
   - Fastest (single sample per pixel)
   - Highest resolution (no averaging)
   - Sensitive to noise and partial volume effects

2. **Thick slab** — Blend multiple parallel slices within a thickness range
   - Noise reduction through averaging
   - Highlights structures via MIP/MinIP
   - Simulates thicker detector rows (MDCT)

### Slab Parameters

``MPRReslicePort/makeSlabTexture(dataset:volumeTexture:plane:thickness:steps:blend:)`` is the preferred interactive API. It accepts a shared 3D `volumeTexture` so synchronized axial, coronal, and sagittal viewports can reuse the same uploaded dataset texture instead of regenerating it per request.

- `thickness` — Slab depth resolved along the plane normal using the dataset spacing (0 or 1 for single slice, >1 for thick slab)
- `steps` — Number of parallel samples within the thickness (higher = smoother but slower)
- `blend` — Blending mode for combining samples

**Example**: `thickness = 10, steps = 20` generates 20 parallel slices spanning a slab that is resolved against the dataset spacing along the plane normal, blending them according to the specified mode.

``MetalMPRAdapter/makeTextureFrame(dataset:plane:thickness:steps:blend:)`` remains a convenience that uploads or reuses the volume texture internally when the caller is not managing a shared `MTLTexture`.

Slab samples are distributed evenly along the plane normal. `maximum` selects the largest valid sample, `minimum` selects the smallest valid sample, and `average` computes the mean of valid samples in modality-intensity space. Samples outside the volume bounds are skipped rather than contributing synthetic values to MIP, MinIP, or average projections.

### Blend Modes

```swift
public enum MPRBlendMode {
    case single    // Middle slice only (no blending)
    case maximum   // Maximum Intensity Projection (MIP)
    case minimum   // Minimum Intensity Projection (MinIP)
    case average   // Mean intensity (noise reduction)
}
```

#### Single Slice (`MPRBlendMode.single`)
Samples only the middle slice within the slab thickness. Equivalent to setting `steps = 1`.

**Use cases:**
- Maximum spatial resolution
- Reviewing individual slices for fine detail
- Minimizing reconstruction artifacts

#### Maximum Intensity Projection (`MPRBlendMode.maximum`)
Projects the **brightest voxel** encountered across all samples.

**Use cases:**
- Vascular imaging (contrast-enhanced vessels)
- Bone visualization
- Calcifications and high-density structures

**Algorithm:**
```
for each pixel (u, v):
    max_intensity = minimum_value
    for each step along normal:
        intensity = sample_volume(u, v, step)
        max_intensity = max(max_intensity, intensity)
    output[u, v] = max_intensity
```

#### Minimum Intensity Projection (`MPRBlendMode.minimum`)
Projects the **darkest voxel** encountered across all samples.

**Use cases:**
- Airway visualization (air = low HU)
- Cystic structures
- Dark-fluid MR sequences

#### Average Intensity Projection (`MPRBlendMode.average`)
Computes the **mean intensity** across all samples.

**Use cases:**
- Noise reduction in low-dose CT
- Smooth thick-slab reformats
- Simulating thicker slice acquisitions

**Algorithm:**
```
for each pixel (u, v):
    sum = 0
    count = 0
    for each step along normal:
        sum += sample_volume(u, v, step)
        count += 1
    output[u, v] = sum / count
```

## Metal Acceleration and Explicit Failures

``MetalMPRAdapter`` is a Metal-only adapter. It requires a Metal device, command queue, shader library, and compute pipelines before it can generate MPR texture frames. Applications should treat those requirements as the runtime contract for MPR, present an explicit unsupported state when the contract is not satisfied, and propagate compute-path failures to callers.

Interactive MPR frames are GPU-resident ``MPRTextureFrame`` values. CPU readback is not part of presentation or interaction; use explicit snapshot/export code, or test-only readback helpers, only when a numeric oracle or exported artifact requires CPU bytes.

### Performance

| Configuration | Typical Performance (512×512 slice, 5mm thickness, 10 steps) |
|---------------|--------------------------------------------------------------|
| **Metal compute** | 2–5 ms |

**Metal benefits:**
- Parallel processing of all pixels simultaneously
- Hardware-accelerated trilinear interpolation
- Scales with GPU compute units

### Metal Initialization

The examples below use ``MetalMPRAdapter/makeSlabTexture(dataset:volumeTexture:plane:thickness:steps:blend:)`` because it is the preferred path for synchronized multi-viewport MPR that reuses a shared 3D texture. For a single viewport that does not manage `volumeTexture` explicitly, ``MetalMPRAdapter/makeTextureFrame(dataset:plane:thickness:steps:blend:)`` is the simpler convenience wrapper.

```swift
guard let device = MTLCreateSystemDefaultDevice() else {
    // Present an explicit unsupported-runtime state.
    return
}

do {
    let adapter = try MetalMPRAdapter(device: device)
    let factory = VolumeTextureFactory(dataset: dataset)
    guard let volumeTexture = factory.generate(device: device) else {
        throw VolumeTextureFactory.TextureUploadError.textureCreationFailed
    }
    let frame = try await adapter.makeSlabTexture(
        dataset: dataset,
        volumeTexture: volumeTexture,
        plane: plane,
        thickness: 5,
        steps: 10,
        blend: .average
    )
    print(frame.texture)
} catch {
    // Present the Metal setup or rendering failure to the caller.
    throw error
}
```

The Metal adapter initializes:
- Metal command queue for GPU command submission
- Shader library with `mprKernel` and `mprSlabKernel` compute functions
- Argument buffers for efficient parameter passing

Callers should handle:
- No Metal device being available
- Command queue creation failure
- Missing or unloadable shader libraries
- Compute pipeline, command buffer, texture creation, or kernel execution errors

## Synchronized Multi-Planar Views

### MPRGridComposer

The ``MPRGridComposer`` SwiftUI component provides a synchronized 2×2 grid layout with three orthogonal MPR views (axial, coronal, sagittal) plus a 3D volumetric view:

```
┌─────────┬─────────┐
│  Axial  │ Coronal │
├─────────┼─────────┤
│Sagittal │   3D    │
└─────────┴─────────┘
```

**Key features:**
- **Window/level synchronization**: Adjustments propagate to all MPR panes (not 3D)
- **Slab thickness synchronization**: Unified thick-slab settings across views
- **Crosshair overlays**: Visual indicators at slice intersections
- **Orientation labels**: Anatomical direction markers (R/L/A/P/S/I)
- **Gesture coordination**: Independent slice scrolling per pane

### Basic Usage

```swift
import MTKCore
import MTKDicomBridge
import MTKUI
import SwiftUI

struct MPRView: View {
    @StateObject private var volumeController = VolumeViewportController()
    @StateObject private var axialController = VolumeViewportController()
    @StateObject private var coronalController = VolumeViewportController()
    @StateObject private var sagittalController = VolumeViewportController()

    var body: some View {
        MPRGridComposer(
            volumeController: volumeController,
            axialController: axialController,
            coronalController: coronalController,
            sagittalController: sagittalController
        )
        .task {
            // Load a renderer-ready dataset. Import MTKDicomBridge when using DICOM-Swift.
            let importer = DicomVolumeDatasetImporter()
            let dataset = try await importDataset(from: dicomDirectory, using: importer)

            // Apply dataset to all controllers
            await volumeController.loadDataset(dataset)
            await axialController.loadDataset(dataset)
            await coronalController.loadDataset(dataset)
            await sagittalController.loadDataset(dataset)
        }
    }
}
```

### Synchronization Workflow

Window/level adjustments flow through the grid:

1. User adjusts window/level slider or uses gestures on any MPR pane
2. ``MPRGridComposer`` detects change via `axialController.statePublisher`
3. Converts window/level to HU min/max:
   ```swift
   let min = level - (window / 2)
   let max = level + (window / 2)
   ```
4. Propagates to all MPR controllers:
   ```swift
   await axialController.setMprHuWindow(min: min, max: max)
   await coronalController.setMprHuWindow(min: min, max: max)
   await sagittalController.setMprHuWindow(min: min, max: max)
   ```
5. Each controller regenerates its slice with the new intensity window

Slab thickness follows a similar pattern via ``VolumeViewportController/setMprSlab(thickness:steps:)``.

## Code Examples

### Generate Axial Slice

```swift
import MTKCore

// Initialize adapter with Metal acceleration
guard let device = MTLCreateSystemDefaultDevice() else {
    // Surface an app-level error or choose a non-Metal workflow.
    return
}
let adapter = try MetalMPRAdapter(device: device)
let factory = VolumeTextureFactory(dataset: dataset)
guard let volumeTexture = factory.generate(device: device) else {
    return
}

// Define an axial plane at the middle of the volume using the dataset geometry
let plane = MPRPlaneGeometryFactory.makePlane(for: dataset, axis: .z, slicePosition: 0.5)

// Generate single slice
let frame = try await adapter.makeSlabTexture(
    dataset: dataset,
    volumeTexture: volumeTexture,
    plane: plane,
    thickness: 1,
    steps: 1,
    blend: .single
)

// Access frame metadata
print("Slice dimensions: \(frame.texture.width) × \(frame.texture.height)")
print("Intensity range: \(frame.intensityRange)")
```

### Generate MIP Slab

```swift
// Thick slab with maximum intensity projection
let slabPlane = MPRPlaneGeometryFactory.makePlane(for: dataset, axis: .z, slicePosition: 0.5)
let mipSlab = try await adapter.makeSlabTexture(
    dataset: dataset,
    volumeTexture: volumeTexture,
    plane: slabPlane,
    thickness: 10,   // resolved against the dataset spacing along the plane normal
    steps: 20,       // 20 samples for smooth MIP
    blend: .maximum  // Maximum intensity projection
)

// Result highlights brightest structures within 10-voxel range
```

### Oblique Plane Reconstruction

```swift
// Define custom oblique plane (e.g., double-oblique cardiac view)
let obliquePlane = MPRPlaneGeometry(
    originVoxel: SIMD3<Float>(128, 128, 64),
    axisUVoxel: SIMD3<Float>(200, 50, 0),   // U-axis: mostly X
    axisVVoxel: SIMD3<Float>(0, 150, 100),  // V-axis: Y+Z diagonal
    originWorld: ...,   // Populate from voxel-to-world transform
    axisUWorld: ...,
    axisVWorld: ...,
    originTexture: ...,
    axisUTexture: ...,
    axisVTexture: ...,
    normalWorld: ...    // Cross product of U and V in world space
)

let obliqueFrame = try await adapter.makeSlabTexture(
    dataset: dataset,
    volumeTexture: volumeTexture,
    plane: obliquePlane,
    thickness: 5,
    steps: 10,
    blend: .average
)
```

### Dynamic Slab Control

```swift
// Override slab parameters via command
try await adapter.send(.setSlab(thickness: 15, steps: 30))

// Next makeSlabTexture call uses overridden parameters
let thickSlab = try await adapter.makeSlabTexture(
    dataset: dataset,
    volumeTexture: volumeTexture,
    plane: plane,
    thickness: 5,   // Overridden to 15
    steps: 10,      // Overridden to 30
    blend: .maximum
)
// Overrides are cleared after makeSlabTexture returns
```

### Blend Mode Switching

```swift
// Change blend mode for next slab
try await adapter.send(.setBlend(.minimum))

// Generate MinIP slab (highlights airways)
let minipSlab = try await adapter.makeSlabTexture(
    dataset: dataset,
    volumeTexture: volumeTexture,
    plane: plane,
    thickness: 10,
    steps: 20,
    blend: .maximum  // Overridden to .minimum
)
```

## Performance Considerations

### Slice Dimensions

Computational cost scales **quadratically** with output resolution:

- 256×256 slice: ~65k pixels
- 512×512 slice: ~262k pixels (4× slower than 256×256)
- 1024×1024 slice: ~1M pixels (16× slower than 256×256)

**Recommendation**: Use 512×512 for standard MPR views, 256×256 for preview/thumbnails.

### Slab Thickness and Steps

Thick-slab generation cost scales **linearly** with `steps`:

- `steps = 1`: Baseline performance (single slice)
- `steps = 10`: ~10× more computation
- `steps = 50`: ~50× more computation

**Recommendation**: Use `steps = 1` for thin slices, `steps = 10-20` for standard thick slabs, `steps = 50+` only for high-quality MIP/MinIP.

**Optimization**: `steps` can be lower than `thickness` for faster (but slightly noisier) results:
```swift
// Fast MIP: 20-voxel slab with only 10 samples
let fastMIP = try await adapter.makeSlabTexture(
    dataset: dataset,
    volumeTexture: volumeTexture,
    plane: plane,
    thickness: 20,
    steps: 10,
    blend: .maximum
)
```

### Blend Mode Cost

Blend mode affects computational complexity:

- **Single**: Cheapest (one sample per pixel)
- **Maximum/Minimum**: Moderate (comparison per step, no arithmetic)
- **Average**: Slightly more expensive (accumulation + division)

All modes have similar GPU performance (difference < 5%) due to parallel processing.

### Memory Usage

MPR operations require:

1. **Volume texture** — Full 3D dataset in GPU memory (shared across all slices)
2. **Output buffer** — 2D slice result storage (`width × height × bytesPerPixel`)

**Example**: 512×512×300 volume (int16) + 512×512 slice:
- Volume texture: 512 × 512 × 300 × 2 bytes = ~157 MB
- Output slice: 512 × 512 × 2 bytes = ~524 KB

The volume texture is loaded once and reused for all subsequent slices, making repeated MPR operations very memory-efficient.

## See Also

- ``MetalMPRAdapter`` — Main MPR rendering interface
- ``MPRReslicePort`` — MPR protocol definition
- ``MPRPlaneGeometry`` — Plane geometry structure
- ``MPRTextureFrame`` — 2D texture-native MPR frame
- ``MPRBlendMode`` — Slab blending modes
- ``MPRPlaneAxis`` — Anatomical plane axes
- ``MPRGridComposer`` — SwiftUI synchronized grid layout
- <doc:VolumeRenderingGuide> — Volume rendering techniques (DVR, MIP, MinIP, AIP)
- <doc:TransferFunctionsGuide> — Intensity-to-color mapping for visualization
