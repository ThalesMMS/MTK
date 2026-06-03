# MTK Public API Contract

This document defines the product-level public API that downstream applications
should depend on. It separates stable app-facing APIs from experimental surfaces
and implementation details that are kept behind `package`, `internal`, or
test-only access while the package is being hardened.

## Stability Levels

- Stable public API: supported entry points for application code. These names
  are intended to remain source-compatible except for normal semantic-versioned
  changes.
- Experimental public API: visible for advanced adopters, demos, tests, or
  migration work, but not yet a stable product contract. These APIs should be
  documented as experimental at the call site.
- Internal implementation details: render graph, resource lifecycle, pooling,
  diagnostics, or controller internals. External applications should not build
  new viewer code directly on these types even if a symbol is currently public.

## Stable Public API

### Volume Data

- `VolumeDataset`
- `ImageData3D`
- `VolumeDimensions`
- `VolumeSpacing`
- `VolumeOrientation`
- `VolumePixelFormat`
- `ClinicalImageMetadata`
- `VolumeDatasetFactory`
- `VolumetricDimensions`
- `VolumetricSpacing`
- `VolumetricOrientation`
- `VolumetricPixelFormat`
- `VolumetricSeriesData`
- `VolumetricSeriesDataProvider`

Use these types to create or receive 3D image data before rendering. A
downstream app should be able to construct a `VolumeDataset` manually without
touching the renderer, resource manager, render graph, or DICOM loader.
`Volumetric*` DTOs are the stable MTKCore handoff contract for app-side loaders
that already decoded a scalar volume through GDCM, DICOM-Decoder, or another
ingestion path.

### Clinical Geometry And Picking

- `VolumePickResult`
- `VolumePickError`
- `VolumePicking`
- `VolumeClippingState`
- `VolumeCropBox`
- `VolumeClipPlane`
- `MPRDisplayTransform`
- `MPRDisplayTransformFactory`
- `MPRPlaneGeometry`
- `MPRPlaneGeometryFactory`
- `DICOMGeometry`
- `AnatomicalAxisLabel`

These APIs expose patient/world/index transforms, MPR display orientation, and
predictable screen-to-volume picking results.

### Transfer Functions

- `TransferFunction`
- `TransferFunctionPoint`
- `TransferFunctionRenderingIntent`
- `ClinicalTransferFunctionPreset`
- `VolumeTransferFunctionLibrary`
- `VolumeTransferFunction`
- `VolumeRenderingBuiltinPreset`
- `AdvancedToneCurveModel`
- `WindowLevelPresets`

Use these APIs for clinical presets, custom transfer functions, window/level
defaults, and user-editable tone curves. `TransferFunction` is the stable
serialized preset format.

### Public Viewports

- `StackViewport`
- `VolumeViewport`
- `VolumeViewport3D`
- `ClinicalViewportSession`
- `ClinicalViewportGrid(session:)`
- `MedicalViewport`
- `MedicalViewportState`
- `MedicalViewportType`
- `MedicalViewportRenderMode`
- `MedicalViewportDatasetSummary`
- `MedicalViewportSliceState`
- `MedicalViewportPresentationState`
- `MetalViewportSurface`
- `MetalViewportView`
- `ViewportPresenting`

These are the recommended UI entry points. They let external apps create:

- a volume-backed stack viewport;
- an MPR viewport;
- a 3D volume viewport;
- the reference 2x2 clinical layout;
- drawable-backed `MTKView`/`CAMetalLayer` presentation.

Applications should route normal viewer workflows through these wrappers instead
of instantiating `MTKRenderingEngine`, `ViewportRenderGraph`,
`VolumeResourceManager`, `RenderPassNode`, or `OutputTexturePool` directly.

### Layers And Segmentation Surfaces

- `VolumeLayer`
- `ScalarVolumeLayer`
- `VolumeLayerBlendMode`
- `LabelmapVolume`
- `LabelmapSegment`
- `SurfaceMesh`
- `SurfaceMeshCoordinateSpace`
- `SurfaceMeshBounds`
- `SurfaceMeshMetadataKey`
- `SurfaceMeshMetadataSource`
- `SurfaceMeshLayer`
- `SurfaceMeshMaterial`
- `SurfaceMeshShading`
- `SurfaceMeshProcessingOptions`

The stable contract covers configured layers, label metadata, surface mesh
geometry and bounds, material color/shading, opacity, visibility, deterministic
CPU mesh repair/smoothing/decimation, and predictable surface composition. GPU
extraction and true raycast-volume depth occlusion remain implementation or
experimental topics.

### DICOM Dataset Bridge

- `DicomVolumeDatasetImporter`
- `DicomVolumeDatasetImportResult`
- `DicomVolumeDatasetImportProgress`
- `VolumeDatasetImporting`

The stable app contract in `MTKCore` is still `VolumeDataset`. DICOM parsing,
source loading, ordering, geometry validation, window metadata, and DICOM errors
belong to `DICOM-Decoder`. The optional `MTKDicomBridge` product only converts
`DicomCore.DicomDecodedSeries` into `VolumeDataset` for apps that want the
default DICOM-Decoder-backed import path.

### Runtime, Output, And Snapshot Boundaries

- `MetalRuntimeAvailability`
- `BackendResolver`
- `VolumeRenderFrame`
- `MPRTextureFrame`
- `SnapshotExporting`
- `TextureSnapshotExporter`

Interactive output is `MTLTexture` presented through `MTKView` or
`CAMetalLayer`. `CGImage` belongs only at explicit snapshot/export/readback
boundaries.

## Experimental Public API

These APIs are visible and useful, but should not be treated as the minimum
stable viewer contract yet:

- `VolumePipeline`
- `VolumeSource`
- `VolumeDatasetFilter`
- `VolumeAnalysisFilter`
- `VolumeMapper`
- `DefaultVolumeMapper`
- `VolumeCropFilter`
- `VolumeThresholdFilter`
- `VolumeResampleFilter`
- `VolumeBinaryMorphologyFilter`
- `VolumeBinaryMorphologyOperation`
- `VolumeIntensityNormalizationFilter`
- `VolumeHistogramFilter`
- `VolumeGradientHistogramFilter`
- `MarchingCubesExtractor`
- `MetalVolumeRenderingAdapter`
- `MetalMPRAdapter`
- `MetalRaycaster`
- `VolumeRenderingConfig`
- `VolumeRenderRequest`
- `VolumeRenderingDebugOptions`
- `VolumeHistogramCalculator`
- `VolumeStatisticsCalculator`
- `MPSEmptySpaceAccelerator`
- `ClinicalProfiler`
- `GPUResourceMetrics`
- `ResourceMemoryMetrics`
- `VolumeViewportContainer`
- `MPRGridComposer`
- `TriplanarMPRComposer`
- `VolumeGesturesModifier`
- `RenderingTelemetry`

Use these APIs for measurement, lower-level rendering experiments, migration,
and focused tests. Public examples may mention them only when the example is
explicitly marked as advanced or experimental.

## Internal Implementation Details

These names are not the recommended external product contract:

- `MTKRenderingEngine`
- `ViewportRenderGraph`
- `ViewportRenderNode`
- `RenderPassNode`
- `RenderRoute`
- `RenderPassDispatcher`
- `RenderRouteResolver`
- `VolumeResourceManager`
- `OutputTexturePool`
- `TextureLeasePool`
- `ArgumentEncoderManager`
- `RenderProfiler`
- `FrameMetadataBuilder`
- `ViewportLifecycleController`
- `VolumeTextureUploader`
- `TransferFunctionCache`
- `VolumeViewportController`
- `ClinicalViewportGridController`
- `VolumeViewportCoordinator`
- debug snapshots and cache inspection helpers

The public wrappers may call these internally. External apps should not require
direct access to them to build the common viewer workflows. Engine and render
graph symbols should stay `package` or narrower unless a separate public
proposal promotes a smaller protocol-oriented facade.

## Example Boundary

The main examples are expected to stay on stable APIs:

- `Examples/BasicVolumeRendering.swift`: `VolumeViewport3D`
- `Examples/MPRViewer.swift`: `ClinicalViewportSession` and
  `ClinicalViewportGrid(session:)`
- `Examples/TriplanarMPRViewer.swift`: three `VolumeViewport` instances
- `Examples/SynchronizedMPRGrid.swift`: `ClinicalViewportSession` and
  `ClinicalViewportGrid(session:)`
- `Examples/DicomLoader.swift`: `DicomVolumeDatasetImporter` into
  `ClinicalViewportSession`

If an example needs `MTKRenderingEngine`, `ViewportRenderGraph`, or resource
pooling details, keep it separate from these main examples and mark it as
experimental.
