# MTK Public API Contract

This document defines the product-level public API for the core-only MTK
package.

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

### Presentation And Output

- `MetalRuntimeAvailability`
- `BackendResolver`
- `VolumeRenderFrame`
- `MPRTextureFrame`
- `PresentationPass`
- `MPRPresentationPass`
- `SnapshotExporting`
- `TextureSnapshotExporter`

Interactive output is `MTLTexture`. `CGImage` belongs only at explicit
snapshot/export/readback boundaries.

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

## Experimental Public API

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
- `VolumeRenderingConfig`
- `VolumeRenderRequest`
- `VolumeRenderingDebugOptions`
- `VolumeHistogramCalculator`
- `VolumeStatisticsCalculator`
- `MPSEmptySpaceAccelerator`
- `ClinicalProfiler`
- `GPUResourceMetrics`
- `ResourceMemoryMetrics`

Use these APIs for measurement, lower-level rendering experiments, and focused
tests.

## Internal Implementation Details

Do not build application code directly on renderer internals, render graph
nodes, resource pools, or viewport controllers.
