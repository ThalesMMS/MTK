# Multi-Volume Registration And Resampling Plan

This note defines the current MTK v1 multi-volume contract and the technical
direction for v2 registration-aware fusion. It is a design plan, not a clinical
validation claim.

## Current Contract

MTK currently supports scalar layer fusion for volumes that are already
registered and either resampled into the base volume texture space or supplied
with a supported externally computed transform:

```text
base VolumeDataset + [registered scalar VolumeLayer] -> optional CPU resample -> per-layer raycast -> 2D composite
```

Supported today:

- `VolumeLayer` stores scalar layer data, a per-layer transfer function,
  opacity, visibility, and blend mode.
- `VolumeLayerBlendMode.sourceOver` composites contextual overlays with alpha.
- `VolumeLayerBlendMode.additive` supports heat-like PET or dose overlays.
- `VolumeViewport3D` and `ClinicalViewportSession` can apply visible scalar
  layers to the 3D volume viewport.
- `LayerTransform` classifies scalar `baseWorldToLayerWorld` matrices.
- Supported non-identity scalar transforms are axis-aligned scale, translation,
  or both. These are CPU-resampled into the base volume geometry before 3D
  fusion dispatch.
- Layer rendering cost scales with the number of visible scalar layers because
  v1 raycasts each scalar layer separately before the 2D composite pass.

Explicitly rejected today:

- Rotation, shear, perspective, non-affine, non-finite, and non-positive-scale
  scalar `VolumeLayer.baseWorldToLayerWorld` transforms.
- Runtime registration, affine solving, deformable registration, and automatic
  alignment.
- Sampling a secondary scalar layer directly in its own voxel grid during a base
  volume raycast.

The rejection is intentional. MTK consumes externally supplied registration and
can resample the supported scale/translation subset, but it does not compute or
clinically validate registration.

Labelmap MPR overlays are separate: they may use `baseWorldToLayerWorld` for MPR
texture-basis mapping.

## Implemented Transform Model

The current public classifier is:

```swift
public struct LayerTransform: Sendable, Equatable {
    public var baseWorldToLayerWorld: simd_float4x4

    public enum Classification: String, Sendable, Equatable {
        case identity
        case translation
        case axisAlignedScale
        case translatedAxisAlignedScale
        case unsupportedAffine
        case nonAffine
    }

    public var classification: Classification { get }
    public var supportsCPUResampling: Bool { get }
}
```

Future provenance and registration-quality metadata can extend this value type.
For now, provenance remains a caller responsibility: MTK may consume a transform
supplied by a trusted external workflow, but MTK does not claim that it computed
or validated clinical registration.

Expected `VolumeLayer` behavior:

- Identity or `preResampled` layers use the current v1 fast path.
- Supported scale/translation layers are resampled by
  `RegisteredVolumeLayerResampler` before 3D rendering.
- Unsupported transforms fail before GPU resource allocation with a recovery
  message that asks the caller to register or resample into base space.
- Transfer function, opacity, visibility, and blend mode remain per layer.
- Clipping starts as base-volume clipping. Per-layer clipping can be added only
  after layer-space sampling is explicit.
- Picking returns the base-volume hit plus optional sampled scalar values from
  visible layers whose transforms are supported by the active pipeline.

Expected `VolumeLayerBlendMode` behavior:

- `sourceOver`: deterministic alpha-over for anatomical context overlays.
- `additive`: clamped additive accumulation for PET/dose-like heat overlays.
- Future modes should be added only with explicit clinical semantics and tests.

## Resampling Strategy

The implemented baseline adds an explicit resampling stage before interactive
3D rendering:

```text
secondary VolumeDataset
  + LayerTransform(baseWorldToLayerWorld)
  + target base VolumeDataset geometry
  -> resampled VolumeDataset in base texture space
  -> current VolumeLayer fast path
```

CPU resampling is used because it is deterministic, testable without new render
pipeline contracts, and suitable for small planning fixtures. GPU resampling can
follow once interpolation, bounds behavior, and metadata provenance are stable.

Minimum resampling requirements:

- nearest-neighbor for label/dose masks where category preservation matters;
- trilinear for scalar PET/MR/dose intensity maps;
- explicit out-of-bounds fill value;
- resulting `ImageData3D` matching the base dataset geometry;
- intensity range recomputed after resampling;
- unsupported transforms reported before GPU resource allocation.

## Scenario Plan

### PET/CT Already Registered

V1 support: use PET as a scalar `VolumeLayer` after external registration and
resampling to CT space. Use PET transfer function and `.additive` or
`.sourceOver` depending on desired display.

V2 minimum: accept an externally supplied rigid/affine transform, resample PET to
CT geometry, then render through the v1 layer stack.

### CT + Dose Map

V1 support: dose must be exported in CT geometry or pre-resampled externally.
Use a dose transfer function and additive or alpha-over composition.

V2 minimum: trilinear dose resampling into CT geometry with explicit unit and
normalization metadata.

### MR T1/T2

V1 support: sequences must already share voxel geometry or be pre-resampled.
Use per-layer transfer functions to emphasize T1/T2 contrast.

V2 minimum: accept external affine registration, resample the secondary MR
volume to the primary MR geometry, and keep per-layer transfer functions.

### Prior/Current

V1 support: only if the prior and current datasets have already been aligned and
resampled to the selected base geometry.

V2 minimum: support externally registered affine transforms and deterministic
resampling. Deformable registration remains a non-goal until separately scoped.

## Incremental Implementation Plan

1. Add `LayerTransform` as a public value type while keeping
   `baseWorldToLayerWorld` source-compatible.
2. Add CPU resampling from secondary dataset into base `ImageData3D` geometry.
3. Add tests for identity, translation, rotation, out-of-bounds fill, and
   intensity-range recomputation.
4. Add a helper that turns `(VolumeLayer, LayerTransform, baseDataset)` into a
   pre-resampled scalar `VolumeLayer`.
5. Wire pre-resampled layers through the current `VolumeViewport3D` and
   `ClinicalViewportSession` APIs.
6. Add layer-aware picking that samples supported visible scalar layers at the
   base hit point.
7. Consider GPU resampling or direct layer-space sampling only after CPU
   behavior and provenance are covered by fixtures.

## Remaining Non-Goals

- Automatic registration.
- Deformable registration.
- Clinical alignment validation.
- Radiotherapy planning-system replacement.
- DICOM SEG, RTSTRUCT, or RTDOSE import semantics beyond explicit dataset and
  metadata contracts.
