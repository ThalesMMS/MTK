# Clinical Rendering Architecture ADR

## Status

Accepted.

## Context

MTK contains rendering-related code that does not belong to the clinical
architecture contract:

- Metal compute adapters, engine code, and render passes in `MTKCore`.
- MTKUI presentation code responsible for clinical viewport display.
- SceneKit materials and integration code in `MTKSceneKit`.
- Explicit snapshot/export utilities that convert GPU frames to `CGImage`.

The clinical architecture is Metal-native and requires explicit GPU resource
ownership, predictable frame lifetimes, synchronized viewports, composable
render passes, and native drawable presentation. Any path that treats
`SCNView`, SceneKit materials, `CGImage`, image surfaces, or CPU-readback
display glue as part of interactive clinical display
conflicts with that architecture.

Bounding geometry remains a local rendering concern. A box, plane, or proxy
mesh may still be used internally to compute ray entry, ray exit, clipping, or
sampling bounds. That does not make SceneKit part of the public clinical
architecture.

## Decision

The official MTK clinical rendering architecture is Metal-native. Metal is the
only official clinical rendering backend.

The official flow is:

```text
DICOM / VolumeDataset
        |
        v
VolumeResourceManager
        |
        v
GPU volume texture / transfer texture / auxiliary textures
        |
        v
MTKRenderingEngine
        |
        v
ViewportRenderGraph
        |
        v
VolumeRaycastPass
MPRReslicePass
MIPPass
OverlayPass
        |
        v
PresentationPass
        |
        v
MTKView / CAMetalLayer drawable
```

Implementation tracking for required pipeline components:

| Pipeline component | Tracking issue |
| --- | --- |
| VolumeResourceManager | [#50](https://github.com/ThalesMMS/MTK/issues/50) |
| GPU volume texture / transfer texture / auxiliary textures | [#59](https://github.com/ThalesMMS/MTK/issues/59) |
| MTKRenderingEngine | [#49](https://github.com/ThalesMMS/MTK/issues/49) |
| ViewportRenderGraph | [#47](https://github.com/ThalesMMS/MTK/issues/47) umbrella; split implementation issue pending |
| VolumeRaycastPass | [#54](https://github.com/ThalesMMS/MTK/issues/54) |
| MPRReslicePass | [#55](https://github.com/ThalesMMS/MTK/issues/55) |
| MIPPass | [#54](https://github.com/ThalesMMS/MTK/issues/54) projection-mode scope; split implementation issue pending |
| OverlayPass | [#57](https://github.com/ThalesMMS/MTK/issues/57) viewport-layout scope; split implementation issue pending |
| PresentationPass | [#56](https://github.com/ThalesMMS/MTK/issues/56) |

The clinical display contract is:

- `MTKView` and `CAMetalLayer` are the official clinical presentation
  surfaces.
- `PresentationPass` is the final display step. Render and compute passes write
  to persistent output textures first; `PresentationPass` copies the completed
  texture fullscreen into the current drawable and presents it.
- `RenderFrame` is the engine-level GPU output contract produced by
  `MTKRenderingEngine`.
- `VolumeRenderFrame` is the public clinical frame contract for interactive
  volume rendering.
- `MPRTextureFrame` is the public clinical frame contract for interactive MPR
  rendering.
- Interactive rendering remains GPU-resident as `MTLTexture` output until
  presentation.
- `MTKSceneKit` is not part of the clinical architecture and will be removed
  from the main package unless a separate experimental package is explicitly
  created later. No clinical demo or MTKUI path may depend on SceneKit.
- `CGImage` is allowed only behind `SnapshotExporting`/`TextureSnapshotExporter`.
  It is not a render result, display surface, or compatibility path.
- `TextureSnapshotExporter` is the sole supported CPU readback boundary for
  clinical rendering frames. `CGImage`, image-backed surfaces, and equivalent
  CPU-readback display APIs are outside the clinical display contract and must
  not be used as interactive presentation paths.
- Viewports share GPU resources through resource handles owned by the resource
  manager. A volume viewport, MPR viewport, MIP viewport, and overlay pass
  refer to the same volume texture, transfer texture, acceleration texture, and
  auxiliary textures by handle instead of duplicating resources per view.
- The render graph is the explicit place where rendering work is composed.
  Clinical features are modeled as passes, dependencies, and presentation
  steps, not as SceneKit nodes, SceneKit materials, or CPU image display glue.
- Bounding volumes, proxy cubes, proxy planes, and ray-entry/ray-exit geometry
  may exist inside a specialized pass. They are implementation details of that
  pass and are not the public architecture.

## Interactive Presentation Contract

Interactive volume presentation must follow the `MTKView` draw cycle. The
surface owns a retained `MTKViewDelegate`, configures the view for one-shot
manual draws, and queues one pending presentation request before calling
`MTKView.draw()`. `currentDrawable` may be acquired only inside `draw(in:)`,
after the system has entered the view's drawable lifecycle.

The concrete surface contract is:

- `MTKView.isPaused = true`, `enableSetNeedsDisplay = true`, and
  `preferredFramesPerSecond = 0` on iOS.
- `CAMetalLayer.presentsWithTransaction = false` is configured idempotently,
  not per presented frame.
- `present(frame:)`, `present(_ texture:)`, and `present(mprFrame:)` enqueue a
  pending request and synchronously ask the view to draw.
- The draw delegate validates/acquires the drawable, submits the
  `PresentationPass`/`MPRPresentationPass`, and records submitted/completed/
  failed counts.
- Output texture leases are released only after presentation completion or
  immediately on a pre-submit failure.

The controller must keep presentation backpressure above this surface: at most
one submitted presentation may be pending per viewport. Gesture deltas may
advance the camera many times, but while a presentation is in flight they only
mark the latest render generation pending. Completion or failure opens the
gate and drains a single render for the newest camera state.

This contract fixed the drag-render stall where camera updates and raycasts
were happening, but the visible drawable updated only after unrelated UIKit
events. The old path acquired drawables outside `draw(in:)`; under sustained
touch interaction that allowed stale/in-flight drawable presentation to wedge
until another UI event forced display progress.

## Shared GPU Resources

Clinical layouts commonly render the same study through multiple synchronized
viewports: 3D DVR, MIP, axial MPR, coronal MPR, sagittal MPR, localizers, and
overlays. The resource manager is responsible for creating and retaining shared
GPU resources such as:

- 3D volume textures derived from `VolumeDataset`.
- Transfer-function textures.
- Histogram, gradient, min-max, and empty-space acceleration textures.
- Intermediate pass outputs.
- Presentation textures targeting drawable-compatible formats.

The public model exposes stable resource handles rather than forcing each
viewport to own a separate `MTLTexture` copy. Handles allow invalidation,
rebuild, synchronization, memory accounting, and lifetime management to happen
once while render passes consume the resources they need.

## Resource Handle Design

Resource handles are lightweight, stable identifiers owned by the
`VolumeResourceManager`. The manager keeps strong ownership of the underlying
GPU resources, including `MTLTexture` values for `VolumeDataset` uploads,
transfer-function textures, auxiliary textures, and intermediate render-pass
outputs. Render passes acquire per-frame resource leases from the manager before
encoding commands. A resource may be freed only after it has been invalidated or
replaced and all in-flight leases or command buffers that reference it have
completed.

Invalidation is generation-based. Changes to the active `VolumeDataset`,
transfer-function textures, acceleration textures, or presentation texture
requirements increment the relevant resource generation. Viewports and render
passes compare the generation they encoded against the manager's current
generation before the next frame. A mismatch forces the pass to rebuild its
bindings, descriptors, and dependent intermediate outputs before encoding new
work.

The resource manager should provide serialized mutation, either through an actor
or a dedicated synchronization queue. `MTLTexture` values are not locked for
general mutable CPU access; passes receive immutable per-frame snapshots and use
them only through Metal command encoding. Replacing a volume, transfer function,
or auxiliary texture creates a new generation instead of mutating a texture that
may still be referenced by an in-flight command buffer.

## Bounding Geometry vs Clinical Architecture

Bounding geometry answers a local ray-marching question: where does a ray enter
and leave the volume, slab, or clipped region? That question can be solved by
math, a compute kernel, a proxy box, a proxy plane, or another internal
mechanism.

The clinical architecture does not expose SceneKit as part of that answer.
Callers interact with Metal resources, `RenderFrame`, `VolumeRenderFrame`,
`MPRTextureFrame`, render-graph passes, and `MTKView`/`CAMetalLayer`
presentation. SceneKit scheduling, `SCNView`, `SCNNode`, `SCNBox`, and
`SCNMaterial` are not part of the clinical viewer contract.

## Consequences

Positive consequences:

- The clinical renderer has one backend contract: Metal-native rendering.
- Removing SceneKit and `CGImage` display paths eliminates architectural
  ambiguity in MTKUI, the demo app, and clinical documentation.
- Viewports can share GPU resources by handle across volume, MPR, projection,
  and overlay passes.
- Interactive frames remain GPU-resident as `MTLTexture` values until
  `PresentationPass` targets the drawable.
- Snapshot and export behavior stays explicit behind
  `SnapshotExporting`/`TextureSnapshotExporter`.
- Future features have a clear home in the render graph instead of splitting
  responsibility across incompatible display models.

Required consequences:

- `MTKSceneKit` is outside the clinical architecture and is not preserved as a
  clinical fallback in the main package.
- No clinical MTKUI path or demo path may depend on SceneKit.
- `CGImage`, image-backed surfaces, and similar CPU-readback display APIs are
  outside the interactive clinical path.
- Documentation and implementation must remove compatibility guidance that keeps
  SceneKit or `CGImage` display glue alive as alternate clinical paths.

## Enforcement Plan

This ADR is executed by direct removal and enforcement work with no temporary
compatibility retention window.

1. Remove `CGImage`/`RenderSurface` interactive display paths and keep `CGImage`
   only behind `SnapshotExporting`/`TextureSnapshotExporter`.
2. Enforce `PresentationPass` as the only clinical presentation step from
   persistent GPU outputs into `MTKView`/`CAMetalLayer` drawables.
3. Remove SceneKit dependencies from MTKUI and from the clinical demo path.
4. Remove `MTKSceneKit` from the main package or extract it only if a separate
   explicitly experimental package is created later.
5. Keep tests focused on GPU-native interactive rendering and explicit snapshot
   export boundaries.

Execution of this decision is tracked in the following issues:

- [#78](https://github.com/ThalesMMS/MTK/issues/78) Fix clinical MPR geometry with `DICOMGeometry`
- [#79](https://github.com/ThalesMMS/MTK/issues/79) Introduce explicit lease handling for `RenderFrame` lifetime and output textures
- [#80](https://github.com/ThalesMMS/MTK/issues/80) Harden `PresentationPass` as the only clinical presentation path
- [#81](https://github.com/ThalesMMS/MTK/issues/81) Remove legacy `CGImage`/`RenderSurface` APIs and files from the interactive path
- [#82](https://github.com/ThalesMMS/MTK/issues/82) Rewrite `MTK-Demo` as a Metal-native clinical viewer without SceneKit
- [#83](https://github.com/ThalesMMS/MTK/issues/83) Create regression tests for no-readback interactive paths
- [#84](https://github.com/ThalesMMS/MTK/issues/84) Create a shared-resource stress test for a 2x2 clinical layout
- [#85](https://github.com/ThalesMMS/MTK/issues/85) Create golden tests for the clinical CSV/JSON profiler
