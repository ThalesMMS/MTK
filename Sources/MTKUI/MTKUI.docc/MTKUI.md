# ``MTKUI``

SwiftUI components and controllers for medical volumetric visualization interfaces.

## Overview

MTKUI provides SwiftUI components, viewport controllers, and gesture handling for building medical volumetric visualization applications on iOS and macOS. Built on top of MTKCore, it includes MPR grids, interactive overlays, camera controls, and windowing tools for medical imaging workflows.

The framework handles viewport coordination, gesture interpretation, UI overlays, and telemetry for a single MTKUI rendering path backed by MTKCore Metal volume and MPR adapters. The app-facing API boundary is recorded in [Architecture/PublicAPI.md](../../../Architecture/PublicAPI.md), and the accepted architecture decision is recorded in [Architecture/ClinicalRenderingADR.md](../../../Architecture/ClinicalRenderingADR.md). The clinical presentation target is `MTKView`/`CAMetalLayer`, with interactive frames represented as `MTLTexture` outputs. `CGImage` is allowed only for explicit snapshot/export/readback workflows behind `SnapshotExporting`/`TextureSnapshotExporter`, not the interactive display contract.

MTKUI has no legacy 3D-wrapper dependency in its clinical UI path. This separation is intentional: MTKUI is the Metal-native SwiftUI integration layer over MTKCore adapters.

MTKUI controllers coordinate synchronized viewports over shared GPU resources owned by the underlying renderer/resource manager. Volume, MPR, projection, and overlay views should consume shared volume textures, transfer textures, and auxiliary textures by handle instead of treating each viewport as an isolated renderer.

### Key Features

- **Viewport Management**: StackViewport, VolumeViewport, VolumeViewport3D, and ClinicalViewportSession provide stable public viewer contracts over MTKCore Metal volume/MPR adapters
- **SwiftUI Integration**: Native SwiftUI views and modifiers with Combine-based state management
- **MPR Grid Layouts**: Synchronized tri-planar (axial/coronal/sagittal) views with crosshair navigation
- **Interactive Overlays**: Medical imaging overlays for window/level, slab thickness, orientation markers, and crosshairs
- **Gesture Handling**: Unified gesture system for camera rotation, pan, zoom, and MPR slice navigation
- **Viewport Coordination**: Singleton coordinator manages controller lifecycle and state synchronization across surfaces
- **Progressive Volume Updates**: Public viewports can apply streamed `ProgressiveVolumeDatasetUpdate` values so previews can refine to final datasets without blocking the main UI workflow

## Topics

### Essentials

- ``StackViewport``
- ``VolumeViewport``
- ``VolumeViewport3D``
- ``ClinicalViewportSession``
- ``MetalViewportView``
- ``MetalViewportSurface``

### Public Viewport Contracts

Stable public contracts for downstream medical viewers.

- ``MedicalViewport``
- ``MedicalViewportState``
- ``MedicalViewportType``
- ``MedicalViewportRenderMode``
- ``MedicalViewportDatasetSummary``
- ``MedicalViewportSliceState``
- ``MedicalViewportPresentationState``
- ``StackViewport``
- ``VolumeViewport``
- ``VolumeViewport3D``
- ``ClinicalViewportSession``

### Compatibility Controllers

Viewport controllers orchestrate volumetric rendering, camera interaction, and volume state management.

- ``VolumeViewportController``
- ``VolumeViewportControlling``
- ``VolumeViewportCoordinator``

### SwiftUI Components

SwiftUI views and containers for embedding volumetric rendering into your application.

- ``VolumeViewportContainer``
- ``MetalViewportView``
- ``MetalViewportContainer``
- ``MTKViewRepresentable``
- ``TriplanarMPRComposer``
- ``MPRGridComposer``
- ``MPRPanelView``
- ``ToneCurveEditor``

### Interactive Overlays

Medical imaging overlays for user controls and visual feedback.

- ``CrosshairOverlayView``
- ``OrientationOverlayView``
- ``WindowLevelControlView``
- ``SlabThicknessControlView``
- ``VolumetricHUD``
- ``VolumetricGestureOverlay``

### Gesture Interactions

Gesture handling and camera interaction for volume viewports.

- ``VolumeGesturesModifier``
- ``VolumeGestureConfiguration``

### State Management

Published state and telemetry for UI synchronization and debugging.

- ``VolumetricStatePublisher``
- ``VolumetricRendererState``
- ``RenderingTelemetry``

### Metal-Native Viewport Boundary

``MetalViewportSurface`` is the official clinical Metal-native presentation surface. It owns an `MTKView`, tracks drawable pixel size from bounds and backing scale, and presents completed `MTLTexture` frames through ``MTKCore/PresentationPass`` without `CGImage` readback.

The supported frame flow is `compute/render pass -> persistent outputTexture -> PresentationPass -> drawable -> present`. Rendering directly into the drawable is not the primary path because drawables are short-lived presentation resources, acquisition may block on display pacing, and presented drawables cannot be reused for adaptive scheduling, inspection, export, or later overlay composition.

``MetalViewportSurface`` is the only clinical presentation surface. Image-backed presentation glue is outside the clinical path and must not be used as an interactive presentation boundary. The architectural boundary remains Metal-native: MTKUI owns SwiftUI composition and viewport hosting, and MTKCore owns Metal volume and MPR adapters.

### Render Surfaces

MTKUI containers host clinical viewports through ``MetalViewportView``, ``MetalViewportContainer``, and ``MTKViewRepresentable``. ``MetalViewportSurface`` is the concrete Metal-native surface for clinical viewport work. It configures `MTKView` for demand-driven presentation, reports drawable-size changes so callers can recreate persistent output textures, and keeps presentation state per viewport instance.

Volume rendering hands `VolumeRenderFrame.texture` to the Metal-backed surface for interactive presentation. MPR presentation follows the same Metal-native rule through GPU frame contracts and `PresentationPass`, not `CGImage` display glue. `CGImage` is allowed only for explicit snapshot/export readback through `TextureSnapshotExporter`. See [Architecture/ClinicalRenderingADR.md](../../../Architecture/ClinicalRenderingADR.md) for the clinical architecture contract.

- ``MetalViewportView``
- ``MetalViewportContainer``
- ``MTKViewRepresentable``
- ``MetalViewportSurface``
- ``MTKCore/PresentationPass``

### UI Styling

Customizable styling protocols for volumetric UI components.

- ``VolumetricUIStyle``

## Quick Start

Use ``StackViewport``, ``VolumeViewport``, and ``VolumeViewport3D`` as the public
entry points for downstream applications. They expose stable state and
``MetalViewportSurface``/``ViewportPresenting`` targets while keeping render graph
details private.

### Stack Slice Scrolling

```swift
import SwiftUI
import MTKUI
import MTKCore

struct StackSliceView: View {
    @StateObject private var stack = try! StackViewport(axis: .axial)

    var body: some View {
        MetalViewportView(surface: stack.surface)
            .task {
                await stack.applyDataset(myDataset)
                await stack.setSliceIndex(32)
            }
            .onTapGesture {
                Task { await stack.scroll(by: 1) }
            }
    }
}
```

### MPR Or Projection

```swift
import SwiftUI
import MTKUI
import MTKCore

struct MPRViewportView: View {
    @StateObject private var viewport = try! VolumeViewport(axis: .coronal)

    var body: some View {
        MetalViewportView(surface: viewport.surface)
            .task {
                await viewport.applyDataset(myDataset)
                await viewport.setSlicePosition(0.5)
                await viewport.setProjectionMode(.mip) // pass nil to return to MPR
            }
    }
}
```

### 3D Volume

```swift
import SwiftUI
import MTKUI
import MTKCore

struct Volume3DView: View {
    @StateObject private var viewport = try! VolumeViewport3D()

    var body: some View {
        MetalViewportView(surface: viewport.surface)
            .task {
                await viewport.applyDataset(myDataset)
                await viewport.setRenderMethod(.dvr)
                await viewport.setPreset(.ctSoftTissue)
            }
    }
}
```

### 3D Volume Fusion

Use ``VolumeLayer`` scalar content when a 3D viewport needs an already registered secondary volume, such as CT plus PET uptake. Layers are configured through ``VolumeViewport3D/setVolumeLayers(_:)`` or ``ClinicalViewportSession/setVolumeLayers(_:)`` and can be adjusted with per-layer visibility, opacity, and blend mode controls.

```swift
let petLayer = VolumeLayer(
    id: "pet",
    dataset: petDataset,
    transferFunction: petTransferFunction,
    opacity: 0.5,
    blendMode: .additive
)

await session.applyDataset(ctDataset)
await session.setVolumeLayers([petLayer])
await session.setVolumeLayerOpacity(id: "pet", opacity: 0.35)
await session.setVolumeLayerBlendMode(id: "pet", blendMode: .sourceOver)
```

V1 fusion is limited to pre-registered, pre-resampled scalar volumes in the base texture space. It does not estimate registration transforms. Additional visible scalar layers cost an extra raycast and composite pass, while shared resource handles avoid duplicate volume uploads across synchronized viewports.

### Crop And Clip

3D crop/clip is exposed through MTKCore's ``VolumeClippingState`` contract.
Crop boxes use normalized dataset texture bounds in `[0, 1]^3`, aligned to the
dataset IJK axes. Clip planes use public world-millimeter plane equations, with
texture and index convenience constructors for viewer controls.

Apply clipping through ``ClinicalViewportSession/setVolumeClipping(_:)``,
``VolumeViewport3D/setVolumeClipping(_:)``, or projection-capable
``VolumeViewport/setVolumeClipping(_:)``. Stack and MPR slice viewports report
disabled clipping in ``MedicalViewportState``.

Crop/clip affects 3D volume/projection rendering and visible-only 3D volume
picking. It does not clip MPR reslices, crosshair movement, or MPR picking.

### Clinical 2x2 Reference Layout

Use ``ClinicalViewportSession`` with ``ClinicalViewportGrid`` for the reference
axial/coronal/sagittal plus 3D/projection layout.
Drive clinical viewport behavior through the session: apply datasets, select
MPR slices, adjust windowing, configure render quality, and read
``ClinicalViewportSession/viewportStates`` or `state(for:)` for
controller-free viewport state snapshots.

```swift
import SwiftUI
import MTKUI

struct ClinicalGridView: View {
    @State private var session: ClinicalViewportSession?

    var body: some View {
        Group {
            if let session {
                ClinicalViewportGrid(session: session)
            }
        }
        .task {
            session = try? await ClinicalViewportSession.make(dataset: myDataset)
        }
    }
}
```

``VolumeViewportController`` and ``ClinicalViewportGridController`` remain
available for compatibility and advanced integrations, but basic viewer setup
should prefer the public viewport contracts above. Render graph, resource
manager, pass node, and output texture pool details are internal implementation
boundaries for these wrappers.

## Architecture

MTKUI follows a public-contract-over-controller pattern:

1. **StackViewport / VolumeViewport / VolumeViewport3D**: Public medical viewport contracts.
2. **ClinicalViewportSession**: Public clinical 2x2 session contract for the reference grid.
3. **VolumeViewportController / ClinicalViewportGridController**: Compatibility and implementation controllers.
4. **MetalViewportSurface**: Drawable-backed Metal-native presentation target.

This architecture enables:
- State synchronization across MPR views
- Shared GPU resources across synchronized viewports
- Singleton access for SwiftUI views
- Comprehensive viewport lifecycle management
- Combine-based reactive updates

## Platform Requirements

- iOS 17.0+ / macOS 14.0+
- Swift 5.10+
- Xcode 16+
- SwiftUI framework
- Metal-capable device for rendering

## See Also

- ``MTKCore`` — Core rendering engine and domain models
