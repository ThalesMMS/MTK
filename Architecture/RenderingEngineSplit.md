# Rendering engine/service split notes

This document describes the **internal** service boundaries introduced while splitting the prior `MTKRenderingEngine` and `VolumeResourceManager` “god classes” into smaller collaborators.

## Goals / invariants

- **No behavior changes**: render routing, validation semantics, pass dispatch ordering, texture formats/sizes, and presentation behavior should remain identical.
- **Maintain public API compatibility**: `MTKRenderingEngine` and `VolumeResourceManager` remain the primary public-facing entry points.
- **Avoid hot-path regressions**: the per-frame render path should not introduce extra allocations or actor hops.

## High-level architecture

`MTKRenderingEngine` remains a facade that owns long-lived GPU collaborators (device/queue, adapters, resource manager, caches), but delegates single responsibilities to focused internal services.

### Render path (per frame)

1. **Resolve + validate route**
   - `RenderRouteResolver` resolves a `ViewportRenderNode` for the current `ViewportRenderRequest` and delegates to `ViewportRenderGraph` for canonical validation.

2. **Profiling**
   - `RenderProfiler` owns per-frame timing scope creation and optional sample recording.
   - It also centralizes the memory snapshot hook: `ClinicalProfiler.recordMemorySnapshot(from:)`.

3. **Dispatch GPU work**
   - `RenderPassDispatcher` executes the selected route’s pass plan by driving existing adapters:
     - `MetalVolumeRenderingAdapter` for DVR/MIP/AIP/MinIP volume raycasting
     - `MetalMPRAdapter` for MPR reslice passes
   - The dispatcher uses `VolumeResourceManager` (and its extracted services) for resource acquisition.

4. **Build outputs**
   - `FrameMetadataBuilder` constructs `FrameMetadata` and `RenderFrame` from the render results, route info, and captured timings.

### Viewport lifecycle

- `ViewportLifecycleController` centralizes viewport state transitions that were previously spread across `MTKRenderingEngine` (e.g., resize/configure) and ensures MPR cache invalidation occurs consistently.

## Resource manager split

`VolumeResourceManager` remains the public coordinator for resource lifecycle, but delegates to:

- `VolumeTextureUploader`
  - Owns dataset-to-`MTLTexture` upload and streaming slice upload.
  - Wraps `VolumeTextureFactory` + `ChunkedVolumeUploader` and preserves command-buffer behavior.

- `TextureLeasePool`
  - Owns output texture allocation/reuse and leasing semantics.
  - Facade over the existing `OutputTexturePool` implementation.

- `TransferFunctionCache`
  - Owns transfer-function texture creation/caching and invalidation rules.

- `ResourceMemoryMetrics`
  - Aggregates best-effort GPU memory metrics by inspecting the above services/caches.

- `ResourceDebugAccess` (DEBUG-only)
  - Hosts debug inspection helpers behind `#if DEBUG`.

## Adding new render passes

- Register/extend routing and validation in `ViewportRenderGraph`.
- Add GPU dispatch logic to `RenderPassDispatcher` (keep it a thin orchestrator over existing adapters).
- Update `FrameMetadataBuilder` if the new pass returns additional outputs that must be surfaced upstream.

## Notes

- The new services are intentionally small and mostly **stateless**; long-lived GPU objects remain owned by `MTKRenderingEngine` / `VolumeResourceManager`.
- Source compatibility is preferred over “perfect layering”. If an internal service needs access to an existing collaborator, pass it explicitly rather than introducing a new global singleton.
