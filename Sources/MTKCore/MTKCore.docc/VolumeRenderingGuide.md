# Volume Rendering Techniques

A comprehensive guide to Direct Volume Rendering (DVR), Maximum Intensity Projection (MIP), Minimum Intensity Projection (MinIP), and Average Intensity Projection (AIP) techniques in MTKCore.

## Overview

Volume rendering is a set of techniques for visualizing 3D scalar fields, particularly medical imaging datasets like CT and MRI scans. Unlike surface rendering (which requires extracting geometric primitives), volume rendering directly processes volumetric data to produce 2D images, preserving subtle intensity variations critical for medical diagnosis.

MTKCore implements four primary volume rendering techniques, each optimized for different visualization tasks:

- **Direct Volume Rendering (DVR)**: Accumulates color and opacity along viewing rays for semi-transparent volume visualization
- **Maximum Intensity Projection (MIP)**: Projects the maximum intensity value encountered along each ray
- **Minimum Intensity Projection (MinIP)**: Projects the minimum intensity value encountered along each ray
- **Average Intensity Projection (AIP)**: Projects the mean intensity value along each ray

All techniques are GPU-accelerated using Metal fragment shaders with adaptive sampling and empty space skipping for real-time performance.

## Core Concepts

### Ray Marching

All volume rendering techniques in MTKCore use **ray marching** (also called ray casting) as their foundation:

1. **Ray Generation**: For each pixel, cast a ray from the camera through the pixel into the volume
2. **Ray Traversal**: March along the ray in discrete steps, sampling the volume at regular intervals
3. **Sample Processing**: At each sample point, retrieve the voxel intensity and apply rendering-specific logic
4. **Result Accumulation**: Combine samples according to the rendering technique (compositing, max, min, or average)

```swift
// Conceptual ray marching pseudocode
for each pixel in image:
    ray = generateRay(pixel, camera)
    result = initializeResult()

    for step in 0..<numSteps:
        position = ray.start + (step * stepSize * ray.direction)
        intensity = sampleVolume(position)
        result = combineWithResult(intensity, result)

    writePixel(pixel, result)
```

### Adaptive Sampling Quality

MTKCore's `renderingQuality` parameter controls the number of ray marching steps:

- **Low Quality** (~100 steps): Fast preview, visible artifacts
- **Medium Quality** (~200 steps): Balanced performance and quality
- **High Quality** (~400+ steps): Maximum detail, slower rendering

Higher step counts produce smoother gradients and more accurate intensity projections but increase GPU computation time linearly.

### Empty Space Skipping

To improve performance, MTKCore implements empty space skipping in DVR mode:

```metal
// Metal shader snippet from direct_volume_rendering
if (src.a < 0.001f) {
    zeroCount++;
    if (zeroCount >= ZRUN) {
        iStep += ZSKIP;  // Skip multiple transparent samples
        zeroCount = 0;
        continue;
    }
}
```

When consecutive samples are fully transparent (alpha < 0.001), the ray marcher advances by larger steps (typically 2x), reducing computation in air regions of CT scans or background areas.

## Direct Volume Rendering (DVR)

### Technique Overview

DVR is the most sophisticated rendering mode, producing semi-transparent visualizations by accumulating color and opacity along viewing rays. It's the primary technique for general-purpose medical volume visualization.

**Key characteristics:**
- Accumulates contributions from all samples along the ray
- Supports opacity-weighted color blending
- Requires transfer functions to map intensity → (color, opacity)
- Can render both opaque structures (bone) and semi-transparent tissues (soft tissue)
- Supports optional gradient-based lighting for depth perception

### Algorithm Details

DVR uses **front-to-back compositing** with early ray termination:

```metal
// Metal shader: direct_volume_rendering
float4 col = float4(0);  // Accumulated color+alpha
int zeroCount = 0;

for (int iStep = 0; iStep < raymarch.numSteps; iStep++) {
    float3 currPos = lerp(ray.startPosition, ray.endPosition, t);
    short hu = getDensity(volume, currPos);

    // Map intensity to color via transfer function
    float densityDataset = normalize(hu, dataMin, dataMax);
    float4 src = getTfColour(tfTable, densityDataset);

    // Optional gradient lighting
    if (isLightingOn) {
        float3 gradient = calGradient(volume, currPos, dimension);
        float3 normal = normalize(gradient);
        src.rgb = calculateLighting(src.rgb, normal, lightDir, direction, 0.3f);
    }

    // Apply window-level opacity modulation
    if (densityWindow < 0.1f)
        src.a = 0.0f;
    else
        src.a *= densityWindow;

    // Front-to-back compositing
    src.rgb *= src.a;
    col = (1.0f - col.a) * src + col;

    // Early ray termination
    if (col.a > 1.0)
        break;
}
```

The compositing equation implements the **over operator**:

```
C_out = C_src × α_src + C_dst × (1 - α_src)
α_out = α_src + α_dst × (1 - α_src)
```

This allows semi-transparent structures to blend naturally while opaque regions occlude structures behind them.

### Transfer Function Role

DVR critically depends on **transfer functions** to determine which intensities are visible:

- **Color mapping**: Intensity → RGB (e.g., bone = white, soft tissue = pink/brown)
- **Opacity mapping**: Intensity → alpha (e.g., air = transparent, bone = opaque)

See <doc:TransferFunctionsGuide> for details on configuring transfer functions via ``VolumeTransferFunctionLibrary`` and ``AdvancedToneCurveModel``.

### Use Cases

- **General CT visualization**: Bones, organs, vessels with soft tissue context
- **MR brain imaging**: Differentiate gray/white matter, CSF, tumors
- **Contrast-enhanced studies**: Highlight vascular structures while showing surrounding anatomy
- **Multi-tissue exploration**: Interactively adjust window/level and transfer functions

### Code Example

```swift
import MTKCore

// Setup DVR with lighting enabled
let adapter = MetalVolumeRenderingAdapter()
try await adapter.setRenderingMode(.directVolumeRendering)
try await adapter.setLightingEnabled(true)

// Apply soft tissue transfer function
try await adapter.setPreset(.softTissue)

// Set window/level for abdomen CT
try await adapter.setHuWindow(min: -150, max: 250)
```

## Maximum Intensity Projection (MIP)

### Technique Overview

MIP displays the **maximum intensity value** encountered along each ray, effectively projecting the brightest voxels onto the viewing plane. This creates a "through" view where high-intensity structures (vessels, bones) are highlighted regardless of depth.

**Key characteristics:**
- Single-pass maximum finding (no accumulation)
- Depth-independent: all bright structures visible simultaneously
- No occlusion: distant bright voxels visible through dimmer foreground
- Ideal for angiography and bone visualization

### Algorithm Details

```metal
// Metal shader: maximum_intensity_projection
float maxDensityWindow = 0.0f;
float maxDensityDataset = 0.0f;
bool hit = false;

for (int iStep = 0; iStep < raymarch.numSteps; iStep++) {
    float3 currPos = lerp(ray.startPosition, ray.endPosition, t);
    short hu = getDensity(volume, currPos);

    float densityWindow = normalize(hu, windowMin, windowMax);
    float densityDataset = normalize(hu, dataMin, dataMax);

    // Optional HU range gating
    bool pass = (hu >= gateHuMin) && (hu <= gateHuMax);
    if (!pass) continue;

    // Track maximum
    if (densityWindow > maxDensityWindow) {
        maxDensityWindow = densityWindow;
        maxDensityDataset = densityDataset;
    }
    hit = true;
}

float valWindow = hit ? maxDensityWindow : 0.0f;
out.color = useTFProj ? getTfColour(tfTable, valDataset) : float4(valWindow);
```

Unlike DVR, MIP performs a simple **maximum reduction** across all samples with no opacity blending.

### Intensity Gating

MTKCore supports **HU range gating** to filter which voxels participate in the maximum finding:

- `gateHuMin`/`gateHuMax`: Only consider intensities within [min, max] range
- Use case: Isolate contrast-enhanced vessels (e.g., 150-400 HU) while excluding bone (>400 HU)

### Transfer Function Application

MIP can optionally apply transfer functions to the maximum intensity:

- `useTFProj = false`: Display raw normalized intensity as grayscale
- `useTFProj = true`: Apply color mapping to maximum intensity (colorize vessels, etc.)

### Use Cases

- **CT Angiography (CTA)**: Visualize contrast-enhanced blood vessels
- **MR Angiography (MRA)**: Show flowing blood (bright on TOF/PC sequences)
- **Bone surveys**: Quick overview of skeletal structures
- **Pulmonary imaging**: Highlight dense nodules or calcifications

### Code Example

```swift
// Setup MIP for CT angiography
try await adapter.setRenderingMode(.maximumIntensityProjection)

// Gate to contrast-enhanced vessel range (150-400 HU)
try await adapter.setHuGate(min: 150, max: 400, enabled: true)

// Apply angiography transfer function with red colorization
try await adapter.setPreset(.ctAngio)
try await adapter.setTransferFunctionEnabled(true)
```

### Limitations

- **No depth cues**: Cannot determine spatial relationships between bright structures
- **Overlapping structures**: High-intensity artifacts can obscure nearby anatomy
- **Thin structure dropout**: Under-sampling may miss small vessels/fractures

Combine with rotation animations or slab thickness adjustments to mitigate depth ambiguity.

## Minimum Intensity Projection (MinIP)

### Technique Overview

MinIP is the inverse of MIP, projecting the **minimum intensity value** along each ray. This highlights low-intensity structures like air-filled spaces, cysts, or specific MR sequences.

**Key characteristics:**
- Projects darkest voxels regardless of depth
- Inverted contrast compared to source data
- Useful for airway visualization (CT) and dark-fluid imaging (MR)

### Algorithm Details

```metal
// Metal shader: minimum_intensity_projection
float minDensityWindow = 1.0f;  // Initialize to maximum
float minDensityDataset = 1.0f;
bool hit = false;

for (int iStep = 0; iStep < raymarch.numSteps; iStep++) {
    // ... sample volume ...

    if (densityWindow < minDensityWindow) {
        minDensityWindow = densityWindow;
        minDensityDataset = densityDataset;
    }
    hit = true;
}

float valWindow = hit ? minDensityWindow : 0.0f;
out.color = useTFProj ? getTfColour(tfTable, valDataset) : float4(valWindow);
```

The logic mirrors MIP but tracks the **minimum** instead of maximum.

### Use Cases

- **Airway visualization**: CT scans showing bronchial tree (air = -1000 HU)
- **Lung parenchyma**: Emphysema, cysts, bullae
- **MR dark-fluid sequences**: CSF spaces on T2-weighted imaging
- **Contrast voids**: Identify non-enhancing regions

### Code Example

```swift
// Setup MinIP for airway visualization
try await adapter.setRenderingMode(.minimumIntensityProjection)

// Window to air/lung tissue range
try await adapter.setHuWindow(min: -1000, max: -400)
```

### Limitations

Similar to MIP:
- No depth information
- Overlapping low-intensity regions are indistinguishable
- Requires careful windowing to avoid background noise domination

## Average Intensity Projection (AIP)

### Technique Overview

AIP computes the **mean intensity value** across all samples along each ray, producing a smooth, noise-reduced projection. It's particularly useful for reducing quantum noise in CT or motion artifacts in dynamic studies.

**Key characteristics:**
- Averages all voxels along ray path (or within gated range)
- Noise suppression through averaging
- Smooth gradients between structures
- Less sensitive to outliers than MIP/MinIP

### Algorithm Details

```metal
// Metal shader: average_intensity_projection
float accWindow = 0.0f;
float accDataset = 0.0f;
int cnt = 0;

for (int iStep = 0; iStep < raymarch.numSteps; iStep++) {
    // ... sample volume ...

    bool pass = (hu >= gateHuMin) && (hu <= gateHuMax);
    if (!pass) continue;

    accWindow += densityWindow;
    accDataset += densityDataset;
    cnt += 1;
}

float valWindow = (cnt > 0) ? (accWindow / float(cnt)) : 0.0f;
float valDataset = (cnt > 0) ? (accDataset / float(cnt)) : 0.0f;
out.color = useTFProj ? getTfColour(tfTable, valDataset) : float4(valWindow);
```

The output is the **arithmetic mean** of all gated samples.

### Use Cases

- **Low-dose CT**: Reduce quantum noise while preserving contrast
- **Perfusion imaging**: Average intensity over time-resolved acquisitions
- **Thick-slab reformats**: Simulate thick MIP slabs with smoother transitions
- **Motion-degraded studies**: Average out registration errors

### Code Example

```swift
// Setup AIP for noise reduction
try await adapter.setRenderingMode(.averageIntensityProjection)

// No gating (average all intensities)
try await adapter.setHuGate(min: -1024, max: 3071, enabled: false)
```

### Limitations

- **Loss of detail**: Sharp edges and small structures are blurred
- **Contrast dilution**: High-intensity features are averaged with surrounding tissue
- **Less diagnostic utility**: Rarely used for primary interpretation (more for preprocessing)

## Choosing the Right Technique

| Technique | Best For | Avoid When |
|-----------|----------|------------|
| **DVR** | General visualization, multi-tissue studies, interactive exploration | Speed is critical, only need specific structures |
| **MIP** | Angiography, bone surveys, high-contrast structures | Need depth perception, overlapping bright structures |
| **MinIP** | Airways, cysts, dark-fluid spaces | Visualizing high-intensity structures |
| **AIP** | Noise reduction, thick slabs, motion mitigation | Need fine detail, sharp edges |

### Workflow Recommendations

1. **Start with DVR** for general exploration and transfer function tuning
2. **Switch to MIP** when vessels/bones are identified and depth is less critical
3. **Use MinIP** for airway/cystic pathology
4. **Apply AIP** sparingly for noise reduction or perfusion averaging

Combine techniques with dynamic rotation, slab thickness adjustment (see <doc:MPRGuide>), and window/level manipulation for comprehensive volume interrogation.

## Performance Considerations

### Rendering Cost Comparison

- **DVR**: Most expensive (compositing + lighting calculations per sample)
- **MIP/MinIP/AIP**: Cheaper (single comparison/accumulation per sample, no alpha blending)

### Optimization Strategies

1. **Reduce quality for preview**: Use `renderingQuality = .low` during camera manipulation
2. **Enable empty space skipping**: Automatically active in DVR when transfer function has transparent regions
3. **Limit slab thickness**: Thick slabs require more samples per ray
4. **Use intensity gating**: Reduces effective sample count by skipping irrelevant intensities

### GPU Memory Usage

All techniques use the same GPU resources:
- 3D volume texture (largest memory consumer)
- 2D transfer function texture (negligible)
- Framebuffer for output (resolution-dependent)

Memory scales with **volume dimensions**, not rendering technique.

## See Also

- ``VolumeRenderingMode`` — Enumeration of available rendering modes
- ``MetalVolumeRenderingAdapter`` — Main rendering interface
- ``MetalRaycaster`` — Low-level ray marching implementation
- <doc:TransferFunctionsGuide> — Configuring color and opacity mappings
- <doc:GettingStarted> — Setup and initialization
