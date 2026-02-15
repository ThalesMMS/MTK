# Multi-Planar Reconstruction (MPR)

A comprehensive guide to multi-planar reconstruction techniques for visualizing volumetric medical imaging data along orthogonal and oblique planes.

## Overview

Multi-Planar Reconstruction (MPR) is a fundamental medical imaging technique that extracts 2D cross-sectional views from 3D volumetric datasets. Unlike volume rendering (which projects the entire 3D dataset onto 2D), MPR generates precise 2D slices along arbitrary planes through the volume, enabling clinicians to examine anatomy from any viewing angle.

MTKCore's MPR implementation provides:

- **Orthogonal slicing**: Standard axial, coronal, and sagittal anatomical planes
- **Oblique reconstruction**: Arbitrary plane orientations for specialized views
- **Thick-slab MPR**: Average/blend multiple parallel slices for noise reduction
- **GPU acceleration**: Metal compute shaders for real-time performance (2-5ms per slice)
- **CPU fallback**: Robust reference implementation for compatibility and testing

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

``MetalMPRAdapter/makeSlab(dataset:plane:thickness:steps:blend:)`` accepts:

- `thickness` — Slab depth in voxels (0 or 1 for single slice, >1 for thick slab)
- `steps` — Number of parallel samples within the thickness (higher = smoother but slower)
- `blend` — Blending mode for combining samples

**Example**: `thickness = 10, steps = 20` generates 20 parallel slices spanning 10 voxels, blending them according to the specified mode.

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

## GPU Acceleration and CPU Fallback

### Performance Comparison

``MetalMPRAdapter`` automatically selects between GPU-accelerated Metal compute shaders and a CPU reference implementation:

| Configuration | Typical Performance (512×512 slice, 5mm thickness, 10 steps) |
|---------------|--------------------------------------------------------------|
| **GPU (Metal)** | 2-5ms |
| **CPU (Reference)** | 50-150ms (depends on CPU cores and dataset size) |

**GPU benefits:**
- 10-30× faster than CPU
- Parallel processing of all pixels simultaneously
- Hardware-accelerated trilinear interpolation
- Scales with GPU compute units (not CPU cores)

### GPU Initialization

```swift
// GPU-accelerated adapter (recommended)
guard let device = MTLCreateSystemDefaultDevice() else {
    fatalError("Metal not available")
}
let adapter = MetalMPRAdapter(device: device)
```

The GPU adapter initializes:
- Metal command queue for GPU command submission
- Shader library with `mprKernel` and `mprSlabKernel` compute functions
- Argument buffers for efficient parameter passing

### CPU Fallback

```swift
// CPU-only adapter (compatibility/testing)
let adapter = MetalMPRAdapter()
```

The CPU fallback is automatically engaged when:
- No Metal device is available (e.g., CI/CD servers, virtualized environments)
- GPU initialization fails (shader library missing, command queue unavailable)
- Explicitly forced via ``MetalMPRAdapter/setForceCPU(_:)``

**CPU implementation:**
- Processes pixels sequentially with multi-core parallelism via `Task.detached`
- Uses manual trilinear interpolation in voxel space
- Produces bit-identical results to GPU path (validated by unit tests)

### Forcing CPU Path

```swift
// Temporarily disable GPU for testing
adapter.setForceCPU(true)
let slice = try await adapter.makeSlab(...)
adapter.setForceCPU(false)  // Re-enable GPU
```

**Use cases:**
- **Regression testing**: Validate GPU and CPU produce identical output
- **Profiling**: Measure CPU vs GPU performance
- **Debugging**: Isolate GPU-specific driver bugs
- **Compatibility**: Work around unsupported Metal features on specific devices

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
import MTKUI
import SwiftUI

struct MPRView: View {
    @StateObject private var volumeController = VolumetricSceneController()
    @StateObject private var axialController = VolumetricSceneController()
    @StateObject private var coronalController = VolumetricSceneController()
    @StateObject private var sagittalController = VolumetricSceneController()

    var body: some View {
        MPRGridComposer(
            volumeController: volumeController,
            axialController: axialController,
            coronalController: coronalController,
            sagittalController: sagittalController
        )
        .task {
            // Load DICOM volume
            let loader = DicomVolumeLoader()
            let dataset = try await loader.load(
                from: dicomDirectory,
                decoder: DicomDecoderSeriesLoader()
            )

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

Slab thickness follows a similar pattern via ``VolumetricSceneController/setMprSlab(thickness:steps:)``.

## Code Examples

### Generate Axial Slice

```swift
import MTKCore

// Initialize adapter with GPU acceleration
let device = MTLCreateSystemDefaultDevice()!
let adapter = MetalMPRAdapter(device: device)

// Define axial plane at Z = 128
let plane = MPRPlaneGeometry.axial(at: 128, dataset: dataset)

// Generate single slice
let slice = try await adapter.makeSlab(
    dataset: dataset,
    plane: plane,
    thickness: 1,
    steps: 1,
    blend: .single
)

// Access slice data
print("Slice dimensions: \(slice.width) × \(slice.height)")
print("Intensity range: \(slice.intensityRange)")
print("Pixel spacing: \(slice.pixelSpacing ?? SIMD2<Float>(0, 0))")
```

### Generate MIP Slab

```swift
// 10mm thick slab with maximum intensity projection
let slabPlane = MPRPlaneGeometry.axial(at: 128, dataset: dataset)
let mipSlab = try await adapter.makeSlab(
    dataset: dataset,
    plane: slabPlane,
    thickness: 10,   // 10 voxels thick
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

let obliqueSlice = try await adapter.makeSlab(
    dataset: dataset,
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

// Next makeSlab call uses overridden parameters
let thickSlab = try await adapter.makeSlab(
    dataset: dataset,
    plane: plane,
    thickness: 5,   // Overridden to 15
    steps: 10,      // Overridden to 30
    blend: .maximum
)
// Overrides are cleared after makeSlab returns
```

### Blend Mode Switching

```swift
// Change blend mode for next slab
try await adapter.send(.setBlend(.minimum))

// Generate MinIP slab (highlights airways)
let minipSlab = try await adapter.makeSlab(
    dataset: dataset,
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
let fastMIP = try await adapter.makeSlab(..., thickness: 20, steps: 10, blend: .maximum)
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
2. **Output buffer** — 2D slice in GPU/CPU memory (`width × height × bytesPerPixel`)

**Example**: 512×512×300 volume (int16) + 512×512 slice:
- Volume texture: 512 × 512 × 300 × 2 bytes = ~157 MB
- Output slice: 512 × 512 × 2 bytes = ~524 KB

The volume texture is loaded once and reused for all subsequent slices, making repeated MPR operations very memory-efficient.

## See Also

- ``MetalMPRAdapter`` — Main MPR rendering interface
- ``MPRReslicePort`` — MPR protocol definition
- ``MPRPlaneGeometry`` — Plane geometry structure
- ``MPRSlice`` — 2D slice result structure
- ``MPRBlendMode`` — Slab blending modes
- ``MPRPlaneAxis`` — Anatomical plane axes
- ``MPRGridComposer`` — SwiftUI synchronized grid layout
- <doc:VolumeRenderingGuide> — Volume rendering techniques (DVR, MIP, MinIP, AIP)
- <doc:TransferFunctionsGuide> — Intensity-to-color mapping for visualization
