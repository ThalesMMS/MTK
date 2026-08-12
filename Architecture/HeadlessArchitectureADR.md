# Headless Package Architecture ADR

## Status

Accepted.

This decision supersedes [ClinicalRenderingADR.md](ClinicalRenderingADR.md).

## Context

The repository previously shipped application-facing viewports, controllers,
gestures, overlays, example applications, and a shared DICOM-to-renderer
adapter. Those modules widened the public interface of both packages and made
their lifecycle depend on platform presentation frameworks.

The durable capabilities are lower-level: DICOM decoding and processing in
`DICOM-Swift`, plus GPU-resident rendering and export in `MTK`.

## Decision

The public libraries remain independent, core-only Swift packages:

- `DICOM-Swift`, with `DicomCore` and `dicomtool`.
- `MTK`, with `MTKCore` and `MTKFixtures`.

`DicomDecodedSeries` is the decoded-series output interface of `DicomCore`.
`VolumeDataset` is the volume input interface of `MTKCore`. The optional
`MTKDicomBridge` repository owns the default mapping between them without
coupling either core package to the other.

MTK rendering remains GPU-resident. `VolumeRenderFrame`, `MPRTextureFrame`, and
other interactive results expose `MTLTexture` output. `PresentationPass` and
`MPRPresentationPass` may encode into a caller-supplied `CAMetalDrawable`, but
MTK does not create or host a platform view. `CGImage` remains restricted to
explicit snapshot, export, debug, and test readback paths.

Application presentation, input handling, window lifecycle, platform views,
and product workflow orchestration belong to downstream applications. The
reference implementation lives in the separate `MTK-Demo` repository.

## Consequences

- The removed products and their public interfaces have no compatibility shim
  or deprecation window; this is a semantic-major change.
- DICOM parsing never depends on MTK, and MTK never depends on DICOM-Swift.
- GPU presentation passes remain reusable without making the package own a
  product interface.
- Source-policy tests reject platform presentation framework imports in product
  sources and reject reintroduction of removed products in package manifests.
- Package documentation ends at decoded values, GPU textures, drawables, or
  explicit exported images.
- Runnable application UI and integration examples are maintained in
  `MTK-Demo`, not in either library repository.
