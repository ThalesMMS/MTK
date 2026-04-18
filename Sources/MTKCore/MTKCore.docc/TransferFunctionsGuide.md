# Transfer Functions

Guide to transfer functions, window/level controls, tone curves, and medical imaging visualization in MTKCore.

## Overview

Transfer functions map raw voxel intensities to visual properties (color and opacity) that make anatomical structures visible and diagnostically useful. In MTKCore, transfer functions enable you to:

- Control which tissues are visible and their relative transparency
- Apply color schemes optimized for specific anatomical structures
- Adjust window/level settings for optimal contrast
- Create custom visualization presets for different diagnostic tasks

Unlike surface rendering which requires manual segmentation, transfer functions provide **non-destructive, interactive exploration** of volumetric data—essential for medical diagnosis where subtle intensity variations may indicate pathology.

## Core Concepts

### What is a Transfer Function?

A transfer function is a mapping from **voxel intensity** (input) to **visual properties** (output):

```
Intensity → (Color, Opacity)
```

For medical imaging, this mapping typically consists of two components:

1. **Color Transfer Function**: Maps intensity values to RGB colors
   - Example: Bone (high HU) → white, soft tissue (medium HU) → pink/brown

2. **Opacity Transfer Function**: Maps intensity values to alpha (transparency)
   - Example: Air/background → fully transparent, bone → opaque

The combination of these two mappings determines which structures are visible and how they appear in the final rendering.

### Why Transfer Functions Matter in Medical Imaging

Medical imaging modalities like CT and MRI produce datasets with:
- Wide dynamic ranges (CT: -1024 to 3071 Hounsfield Units)
- Overlapping tissue intensities (soft tissues: 0-100 HU)
- Clinically significant subtle differences (gray/white matter, tumor margins)

Transfer functions solve three critical challenges:

1. **Display limitations**: Monitors display ~256 gray levels, but CT data has 4096+ intensity levels
2. **Tissue discrimination**: Different anatomical structures require different windowing to be distinguishable
3. **Interactive exploration**: Radiologists need to dynamically adjust visualization for different diagnostic questions

## Window and Level Controls

### Window/Level Fundamentals

**Window/level** is the standard medical imaging control for adjusting transfer functions:

- **Level (Center)**: The center intensity value of the visible range
- **Window (Width)**: The range of intensities displayed

These parameters map to a minimum and maximum intensity:

```swift
// Window/level to min/max conversion
let minHU = level - (window / 2.0)
let maxHU = level + (window / 2.0)
```

### Standard Window/Level Presets

MTKCore provides clinically validated window/level presets via ``WindowLevelPreset``:

```swift
import MTKCore

// CT soft tissue window (W:400, L:40)
let softTissue = WindowLevelPresetLibrary.ct.first { $0.name == "Soft Tissues" }!
let minHU = softTissue.minValue  // -160 HU
let maxHU = softTissue.maxValue  // 240 HU

// Apply to renderer
try await renderer.setHuWindow(min: Int32(minHU), max: Int32(maxHU))
```

### Common Clinical Presets

| Preset | Window | Level | Use Case |
|--------|--------|-------|----------|
| **Soft Tissue** | 400 | 40 | Abdomen, pelvis organs |
| **Lung** | 1500 | -600 | Pulmonary parenchyma |
| **Bone** | 2000 | 300 | Skeletal structures |
| **Brain** | 80 | 40 | Intracranial soft tissue |
| **Liver** | 150 | 30 | Hepatic parenchyma |

These presets are sourced from clinical standards (OHIF, Weasis) and represent radiologist-validated settings.

### Programmatic Window/Level Adjustment

```swift
// Abdomen CT visualization
try await adapter.setHuWindow(min: -150, max: 250)

// Lung window (emphasize air-tissue interface)
try await adapter.setHuWindow(min: -1000, max: 200)

// Bone window (suppress soft tissue)
try await adapter.setHuWindow(min: -200, max: 1800)
```

## Tone Curves and Opacity Mapping

### Beyond Linear Windowing

While window/level provides coarse control, **tone curves** enable fine-grained opacity mapping via ``AdvancedToneCurveModel``. Tone curves use **cubic spline interpolation** between control points to create smooth, non-linear mappings.

### Anatomy of a Tone Curve

A tone curve consists of:
- **Control points**: (x, y) pairs where x = intensity (0-255 normalized), y = opacity (0-1)
- **Interpolation**: Cubic spline creates smooth transitions between points
- **Endpoints**: Always anchored at (0, 0) and (255, 1) for full dynamic range

### Creating and Editing Tone Curves

```swift
import MTKCore

// Create tone curve with default S-curve
let toneCurve = AdvancedToneCurveModel()

// Get default control points (6-point S-curve)
let defaultPoints = toneCurve.currentControlPoints()
// [(0, 0), (32, 0.05), (96, 0.3), (160, 0.7), (224, 0.95), (255, 1)]

// Insert custom control point
toneCurve.insertPoint(AdvancedToneCurvePoint(x: 100, y: 0.5))

// Update existing point
toneCurve.updatePoint(at: 2, to: AdvancedToneCurvePoint(x: 96, y: 0.4))

// Remove interior point (cannot remove endpoints)
toneCurve.removePoint(at: 3)

// Generate sampled values for GPU upload
let samples = toneCurve.sampledValues()  // 2551 samples (255 × 10 + 1)
```

### The Default S-Curve

MTKCore's default tone curve is a **6-point S-shaped curve** optimized for general medical imaging:

```
x:   [  0,  32,  96, 160, 224, 255 ]
y:   [  0, 0.05, 0.3, 0.7, 0.95,  1 ]
```

This curve provides:
- **Gentle ramp-up** (0-32): Suppress noise and air
- **Mid-contrast boost** (96-160): Emphasize tissue boundaries
- **Highlight preservation** (224-255): Maintain bone/contrast detail

### Interpolation Modes

```swift
// Smooth cubic spline (default)
toneCurve.interpolationMode = .cubicSpline

// Linear interpolation between points
toneCurve.interpolationMode = .linear
```

Cubic splines produce visually smoother gradients but may introduce slight overshoots near sharp transitions. Linear interpolation is faster and more predictable but produces less natural-looking results.

## Auto-Windowing and Histogram Analysis

### Histogram-Driven Auto-Window

``AdvancedToneCurveModel`` supports automatic window adjustment based on volume histogram analysis via ``ToneCurveAutoWindowPreset``:

```swift
// Load histogram from volume
let histogram = try await renderer.getHistogram()
toneCurve.setHistogram(histogram)

// Apply auto-window preset
toneCurve.applyAutoWindow(.abdomen)
```

### Available Auto-Window Presets

| Preset | Algorithm | Percentiles | Use Case |
|--------|-----------|-------------|----------|
| **Abdomen** | Percentile | 10% - 90% | Soft tissue organs |
| **Lung** | Percentile | 0.5% - 60% | Pulmonary imaging |
| **Bone** | Percentile | 40% - 99.5% | Skeletal structures |
| **Otsu** | Otsu threshold | N/A | Contrast-enhanced scans |

### Percentile-Based Windowing

Percentile-based presets use histogram cumulative distribution:

1. **Smooth histogram**: Apply box filter to reduce noise (radius: 2-4 bins)
2. **Compute percentiles**: Find intensity values at specified percentiles
3. **Generate curve**: Create S-shaped tone curve with emphasis on percentile range

```swift
// Abdomen preset (10th-90th percentile)
// - Smoothing radius: 3 bins
// - Lower percentile: 0.10 (10%)
// - Upper percentile: 0.90 (90%)
toneCurve.applyAutoWindow(.abdomen)
```

### Otsu Threshold Windowing

Otsu's method finds the optimal threshold separating foreground from background by maximizing **between-class variance**:

```swift
// Apply Otsu auto-window
toneCurve.applyAutoWindow(.otsu)
```

**When to use Otsu:**
- Contrast-enhanced imaging (vessels vs. soft tissue)
- Bimodal histograms (bone vs. soft tissue)
- Automatic segmentation-like visualization

**When to avoid:**
- Multi-tissue visualization (trimodal+ histograms)
- Uniform intensity distributions

### Custom Auto-Window Presets

```swift
// Create custom preset
let customPreset = ToneCurveAutoWindowPreset(
    id: "custom.chest",
    title: "Chest CT",
    lowerPercentile: 0.05,
    upperPercentile: 0.95,
    smoothingRadius: 4
)

toneCurve.applyAutoWindow(customPreset)
```

## Transfer Function Presets

### Built-in Medical Presets

MTKCore provides ``VolumeRenderingBuiltinPreset`` with presets optimized for specific anatomical regions and imaging protocols:

```swift
import MTKCore

// Load CT bone preset
if let boneTF = VolumeTransferFunctionLibrary.transferFunction(for: .ctBone) {
    print("Loaded \(boneTF.name)")
    print("Value range: \(boneTF.minimumValue)...\(boneTF.maximumValue)")

    // Apply to renderer
    try await renderer.setPreset(.ctBone)
}
```

### CT Presets

| Preset | Color Scheme | Opacity Profile | Use Case |
|--------|--------------|-----------------|----------|
| **ctEntire** | Grayscale | Full range | Initial inspection |
| **ctSoftTissue** | Pink/brown | Suppress air/bone | Organ visualization |
| **ctBone** | White | Suppress soft tissue | Skeletal imaging |
| **ctLung** | Blue/white | Emphasize vessels | Pulmonary nodules, airways |
| **ctArteries** | Red | Suppress background | CT angiography |
| **ctCardiac** | Red/pink | Cardiac chambers | Coronary imaging |
| **ctLiverVasculature** | Red/orange | Portal/hepatic vessels | Liver perfusion |
| **ctPulmonaryArteries** | Red | Pulmonary vasculature | PE detection |
| **ctChestContrast** | Blue/white | Mediastinum | Chest CT with IV contrast |
| **ctFat** | Yellow | Adipose tissue | Body composition |

### MR Presets

| Preset | Color Scheme | Signal Profile | Use Case |
|--------|--------------|----------------|----------|
| **mrT2Brain** | Grayscale/blue | CSF bright | T2-weighted brain |
| **mrAngio** | Red | Flowing blood | TOF/CE-MRA |

### Applying Presets

```swift
// Apply CT bone preset with lighting
try await adapter.setPreset(.ctBone)
try await adapter.setLightingEnabled(true)

// Switch to MR angiography
try await adapter.setPreset(.mrAngio)

// Combine with custom window
try await adapter.setPreset(.ctSoftTissue)
try await adapter.setHuWindow(min: -100, max: 200)
```

## Practical Workflows

### Workflow 1: CT Abdomen Exploration

```swift
// 1. Load volume and initialize renderer
let adapter = try MetalVolumeRenderingAdapter()

// 2. Apply soft tissue preset
try await adapter.setPreset(.ctSoftTissue)
try await adapter.setRenderingMode(.directVolumeRendering)

// 3. Enable lighting for depth perception
try await adapter.setLightingEnabled(true)

// 4. Load histogram for auto-window
let histogram = try await adapter.getHistogram()
let toneCurve = AdvancedToneCurveModel()
toneCurve.setHistogram(histogram)

// 5. Apply abdomen auto-window
toneCurve.applyAutoWindow(.abdomen)

// 6. Fine-tune with manual window adjustment
try await adapter.setHuWindow(min: -150, max: 250)
```

### Workflow 2: CT Angiography Vessel Visualization

```swift
// 1. Apply arteries preset
try await adapter.setPreset(.ctArteries)

// 2. Switch to MIP for depth-independent view
try await adapter.setRenderingMode(.maximumIntensityProjection)

// 3. Gate to contrast-enhanced range (150-400 HU)
try await adapter.setHuGate(min: 150, max: 400, enabled: true)

// 4. Enable transfer function colorization
try await adapter.setTransferFunctionEnabled(true)
```

### Workflow 3: Bone Survey

```swift
// 1. Apply bone preset
try await adapter.setPreset(.ctBone)

// 2. Use MIP for skeletal overview
try await adapter.setRenderingMode(.maximumIntensityProjection)

// 3. Set bone window (W:2000, L:300)
try await adapter.setHuWindow(min: -700, max: 1300)

// 4. Disable transfer function for grayscale intensity
try await adapter.setTransferFunctionEnabled(false)
```

### Workflow 4: Lung Parenchyma Analysis

```swift
// 1. Apply lung preset
try await adapter.setPreset(.ctLung)

// 2. Set lung window (W:1500, L:-600)
try await adapter.setHuWindow(min: -1350, max: 150)

// 3. Use DVR with auto-window
let toneCurve = AdvancedToneCurveModel()
toneCurve.setHistogram(histogram)
toneCurve.applyAutoWindow(.lung)

// 4. Adjust for emphysema detection (emphasize low HU)
try await adapter.setHuWindow(min: -1000, max: -400)
```

## Advanced Use Cases

### Multi-Channel Transfer Functions

MTKCore's ``TransferFunction`` supports independent color and alpha channels:

```swift
// Create custom transfer function
var colorPoints: [TransferFunction.ColorPoint] = []
colorPoints.append(TransferFunction.ColorPoint(
    value: -1000,  // Air
    red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0
))
colorPoints.append(TransferFunction.ColorPoint(
    value: 0,      // Water/soft tissue
    red: 0.8, green: 0.6, blue: 0.5, alpha: 0.3
))
colorPoints.append(TransferFunction.ColorPoint(
    value: 400,    // Bone
    red: 1.0, green: 1.0, blue: 1.0, alpha: 0.9
))

var alphaPoints: [TransferFunction.AlphaPoint] = []
alphaPoints.append(TransferFunction.AlphaPoint(value: -1000, alpha: 0.0))
alphaPoints.append(TransferFunction.AlphaPoint(value: 0, alpha: 0.3))
alphaPoints.append(TransferFunction.AlphaPoint(value: 400, alpha: 0.9))

// Create transfer function
let customTF = TransferFunction(
    name: "Custom CT",
    colorPoints: colorPoints,
    alphaPoints: alphaPoints
)
```

### Dynamic Transfer Function Adjustment

```swift
// Real-time window/level adjustment (e.g., from user gestures)
@MainActor
func handleWindowLevelGesture(deltaWindow: Float, deltaLevel: Float) async {
    let currentMin = huWindowMin
    let currentMax = huWindowMax

    let currentLevel = Float(currentMin + currentMax) / 2.0
    let currentWindow = Float(currentMax - currentMin)

    let newLevel = currentLevel + deltaLevel
    let newWindow = max(1.0, currentWindow + deltaWindow)

    let newMin = Int32(newLevel - newWindow / 2.0)
    let newMax = Int32(newLevel + newWindow / 2.0)

    try? await renderer?.setHuWindow(min: newMin, max: newMax)
}
```

### Combining Window/Level with Tone Curves

```swift
// 1. Set coarse window range
try await adapter.setHuWindow(min: -500, max: 1200)

// 2. Apply fine-grained tone curve within that range
let toneCurve = AdvancedToneCurveModel()
toneCurve.setHistogram(histogram)
toneCurve.applyAutoWindow(.abdomen)

// 3. Further customize control points
toneCurve.insertPoint(AdvancedToneCurvePoint(x: 120, y: 0.6))

// 4. Upload to GPU
let samples = toneCurve.sampledValues()
// Apply samples to shader (implementation-specific)
```

## Performance Considerations

### Transfer Function Update Costs

- **Window/level changes**: Cheap (updates shader uniform, ~1ms)
- **Preset changes**: Moderate (uploads 256×256 RGBA texture, ~5ms)
- **Tone curve resampling**: Cheap (CPU spline evaluation, ~2ms for 2551 samples)

### Optimization Strategies

1. **Batch updates**: Group window/level and preset changes into single render pass
2. **Cache sampled curves**: Reuse `toneCurve.sampledValues()` when control points unchanged
3. **Throttle user input**: Debounce window/level gestures to 60 FPS update rate
4. **Defer histogram computation**: Only compute when auto-window requested

### GPU Memory Usage

Transfer function textures are small:
- **1D texture**: 256 × 4 bytes (RGBA) = 1 KB
- **2D texture**: 256 × 256 × 4 bytes = 256 KB

Total GPU memory impact is negligible compared to volume texture (typically 32-512 MB).

## Troubleshooting

### Problem: Everything appears black or white

**Cause**: Window/level mismatch with volume intensity range

**Solution**:
```swift
// Check volume metadata
let metadata = try await renderer.getVolumeMetadata()
print("Intensity range: \(metadata?.intensityRange)")

// Reset to full range
try await adapter.setHuWindow(
    min: Int32(metadata.intensityRange.lowerBound),
    max: Int32(metadata.intensityRange.upperBound)
)
```

### Problem: Auto-window produces unexpected results

**Cause**: Histogram dominated by background/air

**Solution**:
- Use percentile-based presets (e.g., `.abdomen`) instead of `.otsu`
- Try different percentile ranges
- Manually inspect histogram distribution before applying auto-window

### Problem: Tone curve editing causes artifacts

**Cause**: Control points too close together (< 0.5 normalized units)

**Solution**:
```swift
// Points are automatically sanitized to maintain minimum spacing
// Check sanitized points after insertion
toneCurve.insertPoint(AdvancedToneCurvePoint(x: 100, y: 0.5))
let sanitized = toneCurve.currentControlPoints()
print("Sanitized points: \(sanitized)")
```

### Problem: Preset colors don't match DICOM viewer

**Cause**: Different color/opacity mappings between viewers

**Solution**:
- MTK presets are optimized for volume rendering (not slice viewing)
- Use window/level presets from ``WindowLevelPresetLibrary`` for slice-equivalent views
- Disable lighting (`setLightingEnabled(false)`) for direct intensity comparison

## See Also

- ``AdvancedToneCurveModel`` — Cubic spline tone curve editor
- ``VolumeTransferFunctionLibrary`` — Built-in preset library
- ``VolumeRenderingBuiltinPreset`` — Available transfer function presets
- ``WindowLevelPreset`` — Standard window/level configurations
- ``TransferFunction`` — Low-level transfer function representation
- <doc:VolumeRenderingGuide> — Volume rendering techniques (DVR, MIP, MinIP, AIP)
- <doc:GettingStarted> — Basic setup and initialization
