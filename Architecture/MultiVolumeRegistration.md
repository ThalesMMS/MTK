# Multi-Volume Registration And Resampling Plan

This note defines the current MTK v1 multi-volume contract and the technical
direction for v2 registration-aware fusion. It is a design plan, not a clinical
validation claim.

## Current V1 Contract

MTK currently supports scalar layer fusion for volumes that are already
registered and resampled into the base volume texture space:

```text
base VolumeDataset + [registered scalar VolumeLayer] -> per-layer raycast -> 2D composite
```

Supported today:

- `VolumeLayer` stores scalar layer data, a per-layer transfer function,
  opacity, visibility, and blend mode.
- `VolumeLayerBlendMode.sourceOver` composites contextual overlays with alpha.
- `VolumeLayerBlendMode.additive` supports heat-like PET or dose overlays.
- `VolumeViewport3D` and `ClinicalViewportSession` can apply visible scalar
  layers to the 3D volume viewport.
- Layer rendering cost scales with the number of visible scalar layers because
  v1 raycasts each scalar layer separately before the 2D composite pass.

Explicitly rejected today:

- Non-identity scalar `VolumeLayer.baseWorldToLayerWorld` transforms.
- Runtime registration, affine solving, deformable registration, and automatic
  alignment.
- Sampling a secondary scalar layer directly in its own voxel grid during a base
  volume raycast.

The rejection is intentional. V1 renders only layers that already share the base
texture space, so external preprocessing must register and resample PET, MR,
dose, or prior/current volumes before they enter the layer stack.

Labelmap MPR overlays are separate: they may use `baseWorldToLayerWorld` for MPR
texture-basis mapping, but that does not imply scalar 3D fusion supports
non-identity transforms.

## Proposed V2 Model

V2 should promote the current raw matrix into a named transform contract:

```swift
public struct LayerTransform: Sendable, Equatable, Codable {
    public var baseWorldToLayerWorld: simd_float4x4
    public var provenance: Provenance
    public var registrationQuality: RegistrationQuality?

    public enum Provenance: Sendable, Equatable, Codable {
        case identity
        case externalRigid
        case externalAffine
        case preResampled
        case derivedFromDicomGeometry
    }
}

public struct RegistrationQuality: Sendable, Equatable, Codable {
    public var rmsErrorMillimeters: Double?
    public var confidence: Float?
    public var notes: String?
}
```

The important boundary is provenance. MTK may consume an affine supplied by a
trusted external workflow, but MTK should not claim that it computed or validated
clinical registration unless a dedicated validated registration module exists.

Expected `VolumeLayer` behavior:

- Identity or `preResampled` layers use the current v1 fast path.
- Rigid or affine layers require either an explicit resampling step before
  rendering, or a renderer that can sample in layer texture space from base ray
  coordinates.
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

V2 should add an explicit resampling stage before changing interactive rendering:

```text
secondary VolumeDataset
  + LayerTransform(baseWorldToLayerWorld)
  + target base VolumeDataset geometry
  -> resampled VolumeDataset in base texture space
  -> current VolumeLayer fast path
```

CPU resampling is the minimum viable implementation because it is deterministic,
testable without new render pipeline contracts, and suitable for small planning
fixtures. GPU resampling can follow once interpolation, bounds behavior, and
metadata provenance are stable.

Minimum resampling requirements:

- nearest-neighbor for label/dose masks where category preservation matters;
- trilinear for scalar PET/MR/dose intensity maps;
- explicit out-of-bounds fill value;
- resulting `ImageData3D` matching the base dataset geometry;
- intensity range recomputed after resampling;
- provenance recorded in layer metadata or a future `LayerTransform`.

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
