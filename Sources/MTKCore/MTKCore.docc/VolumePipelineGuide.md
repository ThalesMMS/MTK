# Volume Pipeline Guide

Build deterministic volume data pipelines before handing datasets to MTK's Metal-native renderer.

## Overview

MTKCore's volume pipeline provides a small VTK-like source, filter, and mapper contract for scalar medical volumes. It is intentionally narrower than VTK: the v1 pipeline transforms `VolumeDataset` values and metadata, then maps the result back into the existing `VolumeLayer`, `VolumeTransferFunction`, and MTKUI viewport path.

The clinical rendering contract does not change. Interactive rendering still flows through `VolumeDataset -> VolumeResourceManager -> GPU textures -> MTKRenderingEngine -> ViewportRenderGraph -> PresentationPass -> MTKView/CAMetalLayer`.

## Pipeline Stages

- ``VolumeSource`` emits a `VolumeDataset`.
- ``VolumeDatasetFilter`` transforms one dataset into another dataset.
- ``VolumeAnalysisFilter`` computes derived data such as histograms.
- ``VolumeMapper`` prepares a filtered dataset for existing MTK rendering.

The v1 filters below use ``VolumeFilterExecutionPolicy/cpu`` so they can be tested without UI and without interactive rendering:

- ``VolumeCropFilter``
- ``VolumeThresholdFilter``
- ``VolumeResampleFilter``
- ``VolumeHistogramFilter``
- ``VolumeGradientHistogramFilter``

The existing `VolumeHistogramCalculator` and `GradientHistogramCalculator` remain Metal compute utilities. They are not required by the CPU pipeline filters.

## Example

The same filtered dataset can feed analysis and the public viewport API:

```swift
import MTKCore
import MTKUI
import simd

let pipeline = VolumePipeline(
    source: VolumeDatasetSource(dataset),
    filters: [
        try VolumeCropFilter(inclusiveVoxelMin: SIMD3(1, 1, 0),
                             inclusiveVoxelMax: SIMD3(4, 4, 2)),
        VolumeThresholdFilter(range: -200...1200, replacementValue: -1024)
    ],
    mapper: DefaultVolumeMapper()
)

let histogram = try await pipeline.analyze(
    VolumeHistogramFilter(descriptor: .init(binCount: 256,
                                            intensityRange: -1024...3071,
                                            normalize: false))
)

let mapped = try await pipeline.mappedVolume()
await viewport.applyDataset(mapped.dataset)
try await viewport.setTransferFunction(mapped.transferFunction)
```

`DefaultVolumeMapper` returns a ``MappedVolume`` containing the filtered dataset, a default grayscale transfer function when no custom one is supplied, the dataset's recommended window, and a primary ``VolumeLayer`` using MTK's standard primary layer id.

## Filter Behavior

``VolumeCropFilter`` performs a real data crop. It copies the selected inclusive voxel region, updates dimensions, shifts `ImageData3D.origin` by the crop offset, preserves spacing/direction/clinical metadata, and recomputes the intensity range.

``VolumeThresholdFilter`` preserves geometry and metadata while replacing samples inside or outside a scalar range, depending on ``VolumeThresholdMode``. Replacement values must fit the dataset's `VolumePixelFormat`.

``VolumeResampleFilter`` supports nearest-neighbor and trilinear CPU resampling. It preserves physical extent by adjusting spacing according to the source and target dimensions, keeps origin and orientation unchanged, and recomputes the intensity range.

``VolumeHistogramFilter`` returns the existing ``VolumeHistogram`` type. ``VolumeGradientHistogramFilter`` returns ``VolumeGradientHistogram`` with intensity and spacing-aware gradient-magnitude bins.

## Out of Scope

The v1 pipeline does not add a renderer, backend switch, SceneKit path, Gaussian/median filters, connected components, or surface extraction. Those can be layered onto the same contracts later.
