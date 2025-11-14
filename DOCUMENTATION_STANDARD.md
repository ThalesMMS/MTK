# Documentation Standard
## MTK (Metal Toolkit for Medical Imaging)

**Last Updated:** November 7, 2025
**Owner:** Core Maintainer (Thales Matheus Mendonça Santos)

---

## Purpose

This document establishes the standards for all documentation in the MTK project, ensuring consistency, clarity, and completeness across code comments, public APIs, markdown files, and architecture documentation. MTK targets iOS and macOS developers using Swift and Metal for medical imaging applications.

---

## 1. File Headers

All Swift files must include a standardized header following this format:

```swift
//
//  [FILENAME].swift
//  [TARGET_NAME]
//
//  [ONE_LINE_DESCRIPTION_OF_PURPOSE]
//  [OPTIONAL_ADDITIONAL_CONTEXT]
//
//  Author: [DEVELOPER_NAME]
//  Date: [YYYY-MM-DD]
//
```

### Requirements

- **File name:** Exact name of the file
- **Target/Module:** Name of the Swift target (e.g., "MTKCore", "MTKUI", "MTKSceneKit")
- **One-line description:** Concise purpose statement, emphasizing role in rendering pipeline (max 120 characters)
- **Additional context:** Optional line explaining design pattern or key dependencies
- **Author:** Original developer's name
- **Date:** Creation date in YYYY-MM-DD format

### Example

```swift
//
//  MetalRaycaster.swift
//  MTKCore
//
//  Facade over Metal rendering pipelines for volume rendering and MPR,
//  managing pipeline caching, dataset textures, and command submission.
//
//  Author: Thales Matheus Mendonça Santos
//  Date: 2025-10-15
//
```

### Enforcement

- Pre-commit hooks validate header format on all `.swift` files
- Code review enforces compliance before merging
- CI pipeline blocks PRs with non-compliant headers

---

## 2. Code Comments

Comments must explain **why** code exists and document non-obvious implementation details.

### Guidelines

#### 2.1 Metal and Performance-Critical Code

For Metal-specific code, explain the GPU considerations:

```swift
// GOOD: Explains performance rationale
// Cache compiled pipeline states to avoid expensive recompilation on each frame.
// First call to makeFragmentPipeline hits 100-200µs cost; subsequent calls <1µs
var fragmentCache: [FragmentSignature: any MTLRenderPipelineState] = [:]

// Batch command encoding before submission to maximize GPU utilization
commandBuffer.addCompletedHandler { _ in self.processingComplete = true }
```

#### 2.2 Complex Algorithms

For non-trivial algorithms like coordinate transformations, provide mathematical context:

```swift
// Algorithm: Transform plane from world (patient LPS) to texture space
// Given: plane origin O and basis vectors U, V in world space
// Procedure:
// 1. Transform O using worldToTex matrix to get texture origin
// 2. Transform O+U and O+V to get endpoint positions
// 3. Compute texture space basis as differences from origin
// This approach automatically handles perspective distortion and normalization
let O = (worldToTex * simd_float4(originW, 1)).xyz
let U = (worldToTex * simd_float4(originW + axisUW, 1)).xyz - O
let V = (worldToTex * simd_float4(originW + axisVW, 1)).xyz - O
```

#### 2.3 Memory and Resource Management

Document GPU resource lifecycle:

```swift
// Critical: Release GPU textures explicitly to free VRAM
// MTLTexture retains GPU memory until deallocated or replaced
// Large datasets (>500MB) may exhaust device memory if not released
func unloadDataset() {
    // Explicitly release texture to free GPU memory immediately
    textureBuffer = nil

    // Notify GPU to clean up resources on next command submission
    commandQueue.insertDebugCapture()
}
```

---

## 3. Public API Documentation (DocC Comments)

All public types, methods, and properties must have comprehensive DocC documentation.

### 3.1 Type Documentation

```swift
/// High-level facade for Metal rendering pipelines managing both fragment and compute rendering.
///
/// `MetalRaycaster` encapsulates the complexity of creating, caching, and executing Metal
/// render and compute pipelines for volumetric rendering. It handles pipeline state object (PSO)
/// caching to avoid redundant recompilation, manages device resources (command queues, libraries),
/// and provides a streamlined interface for dataset preparation and command buffer generation.
///
/// ## Pipeline Caching Strategy
/// - Fragment pipelines are cached by color/depth formats and sample count
/// - Compute pipelines are cached by rendering technique (DVR, MIP, MinIP)
/// - Caches are automatically cleared via `resetCaches()` when memory pressure increases
///
/// ## Thread Safety
/// **Not thread-safe.** All method calls must occur on the same thread that created the instance,
/// typically the render thread. Use explicit synchronization if calling from multiple threads.
///
/// ## Device Requirements
/// The device must support 3D textures:
/// - iOS: A9 generation or later (A9, A10+)
/// - macOS: Intel GPU family 2 or AMD/M-series
/// - watchOS: Not supported
/// - tvOS: A10X or later
///
/// Initialization fails with `Error.unsupportedDevice` on incompatible devices.
///
/// ## Performance Characteristics
/// - Initialization: 5-10ms
/// - Dataset loading (100MB volume): 50-200ms
/// - Fragment pipeline creation (first call): 100-200µs
/// - Fragment pipeline cache hit: <1µs
/// - Render call overhead: 1-2µs
///
/// ## Example
/// ```swift
/// do {
///     let device = MTLCreateSystemDefaultDevice()!
///     let raycaster = try MetalRaycaster(device: device)
///
///     // Load dataset
///     let dataset = VolumeDataset(dimensions: (512, 512, 512), voxelData: data)
///     let resources = try raycaster.load(dataset: dataset)
///
///     // Create and use render pipeline
///     let pipeline = try raycaster.makeFragmentPipeline(
///         colorPixelFormat: .bgra8Unorm,
///         depthPixelFormat: .depth32Float,
///         sampleCount: 1
///     )
///
///     // Encode rendering commands
///     let commandBuffer = raycaster.commandQueue.makeCommandBuffer()!
///     raycaster.render(with: commandBuffer, using: pipeline)
///     commandBuffer.commit()
/// } catch MetalRaycaster.Error.unsupportedDevice {
///     // Fall back to CPU rendering on unsupported devices
///     setupCPURenderer()
/// } catch {
///     print("Failed to initialize raycaster: \(error)")
/// }
/// ```
///
/// - SeeAlso: ``VolumeDataset``, ``TransferFunction``, ``MetalRaycaster.DatasetResources``
public final class MetalRaycaster {
    // ... implementation ...
}
```

### 3.2 Method Documentation

```swift
/// Creates or retrieves a cached fragment render pipeline for specified formats.
///
/// This method manages an efficient cache of render pipeline state objects (PSOs) to avoid
/// expensive recompilation when the same pixel format combination is requested. The pipeline
/// includes standard vertex and fragment functions from the Metal library.
///
/// ## Pixel Format Considerations
///
/// **Color Format** determines the render target format:
/// - `.bgra8Unorm`: Standard sRGB, efficient on Apple platforms
/// - `.rgba16Float`: High-quality HDR rendering, requires 2x memory
/// - `.rgba8Unorm_srgb`: Alternative sRGB encoding
///
/// **Depth Format** controls depth testing and attachment:
/// - `.invalid`: No depth testing (use for 2D rendering)
/// - `.depth32Float`: 32-bit precision (recommended)
/// - `.depth24Unorm_stencil8`: Less precise, includes stencil
///
/// **Sample Count** enables Multi-Sample Anti-Aliasing (MSAA):
/// - `1`: No anti-aliasing (default, single-sample)
/// - `2, 4, 8`: Multi-sample, increases memory and fillrate proportionally
/// - Supported values depend on device; check `device.supportsTextureSampleCount(_:)`
///
/// ## Performance Implications
///
/// | Operation | Time | Notes |
/// |-----------|------|-------|
/// | First call (new format) | 100-200µs | Includes PSO compilation |
/// | Cache hit | <1µs | Dictionary lookup only |
/// | Memory per cached PSO | ~100KB | Varies by format complexity |
/// | Maximum cached pipelines | 256 | Automatically evicted if exceeded |
///
/// ## Device Compatibility
///
/// Not all format combinations are supported:
/// - Depth format requires `depth32Float` family support
/// - MSAA sample counts vary by device GPU family
/// - Some format combinations may require iOS 14+ or macOS 11+
///
/// Invalid combinations throw `MTLError` with descriptive message.
///
/// - Parameters:
///   - colorPixelFormat: Color render target format (e.g., `.bgra8Unorm`).
///     Determines memory layout and precision for color output.
///   - depthPixelFormat: Depth attachment format for depth testing.
///     Use `.invalid` (default) to disable depth attachment.
///   - sampleCount: Number of samples for MSAA anti-aliasing.
///     Valid values: 1, 2, 4, 8 (device-dependent). Default: 1
///   - label: Optional debug label for Metal debugging tools and Xcode GPU capture.
///     Use descriptive names like "MTK.DVR.Main".
///     Default: auto-generated name like "FragmentPipeline_bgra8UnormDepth32Float"
///
/// - Returns: A cached `MTLRenderPipelineState` configured with specified formats.
///   The returned pipeline is immediately ready for use.
///
/// - Throws:
///   - `MetalRaycaster.Error.libraryUnavailable` if Metal library not loaded
///   - `MetalRaycaster.Error.pipelineUnavailable(function:)` if shader function missing
///   - `MTLError.invalidArgument` if format combination unsupported
///   - `MTLError.commandEncoderFailed` if device resources exhausted
///
/// - Complexity: O(1) amortized. First unique format: O(n) where n = pipeline compilation time
///
/// ## Example: Basic Fragment Pipeline
/// ```swift
/// let raycaster = try MetalRaycaster(device: device)
/// let pipeline = try raycaster.makeFragmentPipeline(
///     colorPixelFormat: .bgra8Unorm,
///     depthPixelFormat: .depth32Float
/// )
/// ```
///
/// ## Example: MSAA with Custom Label
/// ```swift
/// let pipeline = try raycaster.makeFragmentPipeline(
///     colorPixelFormat: .bgra8Unorm,
///     depthPixelFormat: .depth32Float,
///     sampleCount: 4,
///     label: "MTK.Raytrace.4xMSAA"
/// )
/// ```
///
/// ## Example: Reusing Cached Pipeline
/// ```swift
/// // First call: expensive compilation
/// let pipeline1 = try raycaster.makeFragmentPipeline(
///     colorPixelFormat: .bgra8Unorm,
///     depthPixelFormat: .depth32Float
/// )
///
/// // Second call with same formats: cache hit (<1µs)
/// let pipeline2 = try raycaster.makeFragmentPipeline(
///     colorPixelFormat: .bgra8Unorm,
///     depthPixelFormat: .depth32Float
/// )
/// // pipeline1 === pipeline2 (same cached object)
/// ```
///
/// - SeeAlso: ``makeComputePipeline(for:label:)``, ``resetCaches()``, ``load(dataset:)``
public func makeFragmentPipeline(
    colorPixelFormat: MTLPixelFormat,
    depthPixelFormat: MTLPixelFormat = .invalid,
    sampleCount: Int = 1,
    label: String? = nil
) throws -> any MTLRenderPipelineState
```

### 3.3 Error Documentation

```swift
/// Errors that can occur during Metal raycaster initialization and operation.
public enum Error: Swift.Error {
    /// Metal library containing rendering shaders is unavailable.
    ///
    /// This error occurs when:
    /// - Default Metal library cannot be created from bundle
    /// - `Bundle.module.path(forResource: "default", ofType: "metallib")` returns nil
    /// - Device doesn't support Metal (very rare on iOS 8+/macOS 10.11+)
    /// - Shader compilation was skipped or incomplete
    ///
    /// **Common Causes:**
    /// - Metal shaders not included in target's Build Phases
    /// - Incorrect Metal library file name or extension
    /// - Bundle configuration issue in Package.swift
    ///
    /// **Recovery Strategy:**
    /// 1. Verify Metal shaders are compiled (check .metallib in bundle)
    /// 2. Check Bundle.module is correctly configured in Package.swift
    /// 3. Provide CPU-based fallback renderer
    /// 4. Inform user that GPU rendering is unavailable
    case libraryUnavailable

    /// Required Metal rendering function is missing from the shader library.
    ///
    /// This error occurs when:
    /// - Shader function name is misspelled in code
    /// - Shader function was removed but code still references it
    /// - Shader source file not included in compilation
    /// - Metal library corruption
    ///
    /// **Common Causes:**
    /// - Renaming shader function without updating Swift code
    /// - Deleting shader file without removing references
    /// - Function visibility not set to `extern` in Metal code
    ///
    /// **Associated Value:** Name of the missing function (e.g., `"volume_raytrace_fragment"`)
    ///
    /// **Recovery Strategy:**
    /// 1. Check shader source files exist and compile without errors
    /// 2. Verify function names match between Metal and Swift code
    /// 3. Rebuild project clean: `xcodebuild clean build`
    /// 4. Check Metal build settings
    case pipelineUnavailable(function: String)

    /// Metal command queue could not be created.
    ///
    /// This error occurs when:
    /// - Device does not support command queue creation (extremely rare)
    /// - System GPU resources are exhausted
    /// - Device is in invalid state (disconnected, overheated)
    /// - Insufficient system memory for queue allocation
    ///
    /// **Recovery Strategy:**
    /// 1. Check device connectivity (USB for Mac, power for iPad)
    /// 2. Monitor system resource usage with Activity Monitor
    /// 3. Restart application
    /// 4. Suggest device restart if persistent
    case commandQueueUnavailable

    /// Dataset texture could not be created or data uploaded to GPU.
    ///
    /// This error occurs when:
    /// - Dataset dimensions exceed device texture limits (usually 2048x2048x2048)
    /// - GPU memory insufficient for texture allocation
    /// - Invalid pixel format for 3D textures
    /// - Texture data is corrupted or has invalid dimensions
    ///
    /// **Typical Limits by Device:**
    /// - iPad Air 2+: 2048x2048x2048 (2GB texture max)
    /// - iPhone 6s+: 1024x1024x1024 (512MB texture max)
    /// - Older devices: 512x512x512 or smaller
    ///
    /// **Recovery Strategy:**
    /// 1. Downsample dataset: `dataset.downsample(factor: 2)`
    /// 2. Use lower precision pixel format (e.g., uint8 instead of float32)
    /// 3. Implement streaming for very large datasets
    /// 4. Show user informative error with device memory available
    case datasetUnavailable

    /// GPU device does not support required Metal features for volume rendering.
    ///
    /// This error occurs when:
    /// - Device does not support 3D textures (pre-A9 GPUs)
    /// - Device GPU family doesn't support required features
    /// - Platform is not iOS/macOS/tvOS (e.g., simulator limitations)
    ///
    /// **Unsupported Devices:**
    /// - iPhone 5, 5c, 5s (need A9+)
    /// - iPad 4, iPad Air 1, iPad mini 3 (need A8X+)
    /// - macOS with Intel GPU family 1 (need family 2+)
    ///
    /// **Recovery Strategy:**
    /// 1. Detect early: `canCreateMetalRaycaster()` method
    /// 2. Provide CPU-based volume rendering fallback
    /// 3. Show user: "Your device doesn't support GPU volume rendering"
    /// 4. Suggest newer device for full functionality
    case unsupportedDevice

    /// Generic Metal error (wraps MTLError for additional context).
    /// - Associated Value: Original `MTLError` and descriptive message
    case metalError(error: MTLError, message: String)
}
```

### 3.4 Protocol Documentation

Document coordinate systems and transformations clearly:

```swift
/// Protocol for coordinate space transformations required for medical volume rendering.
///
/// Implementations provide transformations between three coordinate systems:
///
/// 1. **Voxel Space** - Integer array indices (i, j, k) into the 3D volume
/// 2. **World Space** - Patient-oriented coordinates in millimeters, using
///    DICOM patient coordinate system (LPS: Left-Posterior-Superior)
/// 3. **Texture Space** - GPU texture normalized coordinates [0, 1]^3
///
/// These transformations enable:
/// - Converting mouse input to volume locations
/// - Positioning multi-planar reconstruction (MPR) slices
/// - GPU texture sampling with normalized coordinates
/// - View synchronization between 2D and 3D displays
///
/// ## Coordinate Systems
///
/// ### Voxel Space
/// - Origin: (0, 0, 0) at corner of volume array
/// - Axes: Aligned with array dimensions
/// - Values: Integers 0 to dimensions-1
/// - Memory layout: Row-major (C-style)
///
/// ### World Space (LPS)
/// - Origin: Patient origin (typically center of image)
/// - Units: Millimeters (per DICOM standard)
/// - **X-axis:** Left (positive) ← → Right (negative)
/// - **Y-axis:** Posterior (positive) ← → Anterior (negative)
/// - **Z-axis:** Superior (positive) ← → Inferior (negative)
/// - This is the standard patient coordinate system used in medical imaging
///
/// ### Texture Space
/// - Origin: (0, 0, 0) at corner
/// - Range: [0, 1]^3 for valid texture coordinates
/// - Center of voxel: 0.5 in each dimension
/// - Used for GPU texture lookups and sampling
///
/// ## Thread Safety
/// Conforming types must be thread-safe. Geometry is typically computed once at dataset
/// load time, then accessed read-only from multiple render threads.
///
/// ## Usage Example
/// ```swift
/// let geometry = DICOMGeometry(imagePosition: ipp, imageOrientation: iop)
///
/// // Convert mouse world coordinate to texture for sampling
/// let worldPoint = SIMD3<Float>(x: 0, y: 0, z: 50)  // 50mm superior
/// let texturePoint = geometry.worldToTexture(world: worldPoint)
/// // Result: normalized coordinate suitable for GPU texture lookup
///
/// // Position MPR plane in world space, transform to texture
/// let planeOrigin = SIMD3<Float>(x: -256, y: -256, z: 0)
/// let axisU = SIMD3<Float>(x: 512, y: 0, z: 0)     // Width
/// let axisV = SIMD3<Float>(x: 0, y: 512, z: 0)     // Height
/// let (originTex, uTex, vTex) = geometry.planeWorldToTex(
///     originW: planeOrigin,
///     axisUW: axisU,
///     axisVW: axisV
/// )
/// // Use origin/u/vTex to configure MPR rendering
/// ```
///
/// - SeeAlso: ``Geometry``, ``DICOMGeometry``, ``TransformationMatrix``
public protocol DICOMGeometryProvider {
    /// Transforms a point from voxel space (array indices) to world space (mm, LPS).
    func voxelToWorld(voxel: SIMD3<Int32>) -> SIMD3<Float>

    /// Transforms a point from world space (mm, LPS) to texture space (normalized).
    func worldToTexture(world: SIMD3<Float>) -> SIMD3<Float>

    /// Transforms a plane from world space to texture space.
    func planeWorldToTex(originW: SIMD3<Float>,
                        axisUW: SIMD3<Float>,
                        axisVW: SIMD3<Float>) -> (originT: SIMD3<Float>,
                                                 axisUT: SIMD3<Float>,
                                                 axisVT: SIMD3<Float>)
}
```

### 3.5 DocC Coverage Requirements

- **Minimum Coverage:** 80% of public APIs across all targets
- **Validation:** CI enforces minimum coverage
- **New APIs:** All new public symbols require complete documentation before merging
- **Quality:** Documentation must include examples and error cases

---

## 4. Markdown Documentation

All markdown files follow consistent structure and formatting.

### 4.1 File Header

Every markdown file should start with:

```markdown
# [Document Title]

**Last Updated:** [YYYY-MM-DD]
**Author(s):** [Name(s)]
**Status:** [Active | Draft | Deprecated]

---

[Brief description of document purpose]
```

### 4.2 README Structure

```markdown
# MTK — Metal Toolkit for Medical Imaging

[One-sentence tagline: "A modern Swift/Metal toolkit for GPU-accelerated volumetric rendering on iOS and macOS."]

## Quick Navigation

- Getting Started
- API Reference
- Examples
- Troubleshooting
- Architecture

## Overview

[2-3 paragraph description of what MTK does and who should use it]

## Installation

[Step-by-step installation for SPM and CocoaPods]

## Quick Start

[Minimal 5-line example to get rendering]

## API Reference

[Links to detailed API documentation for each target]

## Examples

[Links to working examples in Examples/ directory]

## Architecture

[Links to architecture guides and ADRs]

## Troubleshooting

[Common issues with diagnostic steps and solutions]

## Contributing

[Link to CONTRIBUTING.md]

---

**Version:** [Version]
**Last Updated:** [Date]
```

### 4.3 Code Example Standards

- All examples must compile without modification
- Show realistic use cases from actual apps
- Include error handling
- Link to full example source when complex

### 4.4 Performance Documentation

For performance-sensitive APIs, include:

```markdown
## Performance Characteristics

| Operation | Time | Memory | Notes |
|-----------|------|--------|-------|
| Raycaster init | 5-10ms | 2MB | Cached, reuse instance |
| Dataset load (100MB) | 50-200ms | 400MB GPU | Async supported |
| Pipeline cache hit | <1µs | — | Per-frame cost minimal |
```

---

## 5. Architecture Documentation

### 5.1 Architecture Decision Records (ADRs)

Location: `Documentation/adr/`

Template:

```markdown
# ADR-XXXX: [Decision Title]

**Status:** Accepted
**Date:** [YYYY-MM-DD]
**Author:** [Name]

## Context

[Problem statement and constraints]

## Decision

[What was decided and key aspects]

## Rationale

[Why this decision? Alternatives considered? Trade-offs?]

## Consequences

### Positive
[Benefits]

### Negative
[Costs and downsides]

## References
[Related ADRs, issues, PRs]
```

### 5.2 Architecture Guides

Key guides that must be maintained:

1. **RenderingPipeline.md** - How data flows from dataset to screen
2. **CoordinateTransformations.md** - Voxel/World/Texture space explained
3. **TransferFunctions.md** - Preset system and custom function creation
4. **MemoryManagement.md** - GPU memory allocation, streaming, cleanup

---

## 6. Documentation Review

### 6.1 PR Documentation Checklist

For all PRs affecting public APIs:

- [ ] New public types have complete DocC
- [ ] New public methods have parameter/return/error documentation
- [ ] Code examples compile and work
- [ ] Updated relevant markdown docs
- [ ] No broken links
- [ ] File headers present and accurate

### 6.2 Review Time Budget

- Documentation review: 15 minutes maximum per PR
- Automated checks catch 80% of issues
- Manual review focuses on accuracy and clarity

---

## 7. Glossary

### Medical Imaging Terms

- **DICOM** - Digital Imaging and Communications in Medicine
- **VOI (Value of Interest)** - Window/Level settings for display
- **Instance UID** - Unique identifier per DICOM object
- **Modality** - Type of imaging (CT, MRI, US, etc.)

### MTK-Specific Terms

- **Raycasting** - GPU technique for volume rendering (ray-marching)
- **Transfer Function** - Maps voxel intensity to color and opacity
- **DVR** - Direct Volume Rendering
- **MIP** - Maximum Intensity Projection
- **MPR** - Multi-Planar Reconstruction (2D slices)
- **Texture Space** - Normalized [0,1] coordinates for GPU sampling

---

## 8. Enforcement and Metrics

### 8.1 Automated Validation

- File header presence and format
- DocC coverage (minimum 80%)
- Markdown link validity
- Code example syntax

### 8.2 Quality Metrics

- Public API documentation coverage (target: 85%+)
- Example code compilation success (target: 100%)
- Link validity (target: 100%)
- File header compliance (target: 100%)

### 8.3 Maintenance Schedule

- Monthly documentation audit
- Quarterly review of major guides
- Bi-annual glossary and standards review

---

**Document Status:** Active
**Last Updated:** November 7, 2025
**Next Review:** December 7, 2025
