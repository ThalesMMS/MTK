# ``MTKUI``

SwiftUI components and controllers for medical volumetric visualization interfaces.

## Overview

MTKUI provides SwiftUI components, scene controllers, and gesture handling for building medical volumetric visualization applications on iOS and macOS. Built on top of MTKCore and MTKSceneKit, it includes MPR grids, interactive overlays, camera controls, and windowing tools for medical imaging workflows.

The framework handles scene coordination, gesture interpretation, UI overlays, and telemetry for a single MTKUI rendering path: SceneKit presentation backed by Metal-driven volume and MPR materials.

### Key Features

- **Scene Management**: VolumetricSceneController orchestrates SceneKit presentation, camera state, and Metal-backed volume/MPR materials
- **SwiftUI Integration**: Native SwiftUI views and modifiers with Combine-based state management
- **MPR Grid Layouts**: Synchronized tri-planar (axial/coronal/sagittal) views with crosshair navigation
- **Interactive Overlays**: Medical imaging overlays for window/level, slab thickness, orientation markers, and crosshairs
- **Gesture Handling**: Unified gesture system for camera rotation, pan, zoom, and MPR slice navigation
- **Scene Coordination**: Singleton coordinator manages controller lifecycle and state synchronization across surfaces

## Topics

### Essentials

- ``VolumetricSceneController``
- ``VolumetricDisplayContainer``
- ``VolumetricSceneCoordinator``

### Scene Controllers

Scene controllers orchestrate volumetric rendering, camera interaction, and volume state management.

- ``VolumetricSceneController``
- ``VolumetricSceneControlling``
- ``VolumetricSceneCoordinator``
- ``VolumetricCameraController``
- ``VolumetricMPRController``

### SwiftUI Components

SwiftUI views and containers for embedding volumetric rendering into your application.

- ``VolumetricDisplayContainer``
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

Gesture handling and camera interaction for volumetric scenes.

- ``VolumeGesturesModifier``
- ``VolumeGestureConfiguration``
- ``CameraInteractionBridge``

### State Management

Published state and telemetry for UI synchronization and debugging.

- ``VolumetricStatePublisher``
- ``VolumetricRendererState``
- ``RenderingTelemetry``

### Render Surfaces

Abstraction layer for the SceneKit presentation surface plus lightweight image surfaces used by tests and snapshots.

- ``RenderSurface``
- ``SceneKitSurface``
- ``ImageSurface``

### UI Styling

Customizable styling protocols for volumetric UI components.

- ``VolumetricUIStyle``

## Quick Start

Use ``VolumetricSceneCoordinator`` as the entry point for MTKUI. The shared
coordinator owns controller lifecycle, keeps shared rendering state in sync, and
hands each view the surface-specific ``VolumetricSceneController`` it should use.

Create a basic volumetric scene with SwiftUI:

```swift
import SwiftUI
import MTKUI
import MTKCore

struct VolumetricView: View {
    @StateObject private var coordinator = VolumetricSceneCoordinator.shared
    @State private var level: Double = 40
    @State private var window: Double = 400

    private var controller: VolumetricSceneController {
        coordinator.controller
    }

    var body: some View {
        VolumetricDisplayContainer(controller: controller) {
            // Optional overlays
            VStack {
                Spacer()
                WindowLevelControlView(
                    level: $level,
                    window: $window
                )
            }
        }
        .volumeGestures(controller: controller)
        .task {
            // Load your volume dataset
            await loadDataset()
        }
    }

    func loadDataset() async {
        // Create and configure your volume dataset
        // Then apply it through the coordinator-managed controller set
        coordinator.apply(dataset: myDataset)
    }
}
```

Create an MPR layout:

### Tri-Planar Only

Use ``TriplanarMPRComposer`` when the interface needs axial, coronal, and sagittal
review without a 3D pane. This path provisions only the three MPR controllers,
which reduces memory footprint and keeps setup focused on orthogonal slice review.

```swift
import SwiftUI
import MTKUI

struct TriplanarMPRView: View {
    let coordinator = VolumetricSceneCoordinator.shared

    var body: some View {
        TriplanarMPRComposer(
            axialController: coordinator.controller(for: .z),
            coronalController: coordinator.controller(for: .y),
            sagittalController: coordinator.controller(for: .x),
            layout: .grid
        )
        .task {
            await coordinator.controller(for: .z).applyDataset(myDataset)
            await coordinator.controller(for: .y).applyDataset(myDataset)
            await coordinator.controller(for: .x).applyDataset(myDataset)
        }
    }
}
```

### Tri-Planar + 3D

Use ``MPRGridComposer`` when a 3D volume pane provides useful anatomical context
beside the three orthogonal MPR planes. This layout provisions a volume controller
plus the three MPR controllers.

```swift
import SwiftUI
import MTKUI

struct MPRGridView: View {
    let coordinator = VolumetricSceneCoordinator.shared

    var body: some View {
        MPRGridComposer(
            volumeController: coordinator.controller,
            axialController: coordinator.controller(for: .z),
            coronalController: coordinator.controller(for: .y),
            sagittalController: coordinator.controller(for: .x)
        )
        .task {
            let dataset = myDataset

            await coordinator.controller.applyDataset(dataset)
            await coordinator.controller(for: .z).applyDataset(dataset)
            await coordinator.controller(for: .y).applyDataset(dataset)
            await coordinator.controller(for: .x).applyDataset(dataset)
        }
    }
}
```

Choose ``TriplanarMPRComposer`` for simpler MPR-only setup and lower memory usage.
Choose ``MPRGridComposer`` when the 3D pane is part of the clinical or review
workflow.

## Architecture

MTKUI follows a coordinator-controller pattern:

1. **VolumetricSceneCoordinator**: Singleton managing controller instances and state synchronization
2. **VolumetricSceneController**: Per-surface controller handling rendering, camera, and volume state
3. **VolumetricDisplayContainer**: SwiftUI view wrapping render surfaces with overlay support
4. **Gesture Modifiers**: SwiftUI gesture modifiers forwarding interactions to controllers

This architecture enables:
- State synchronization across MPR views
- Singleton access for SwiftUI views
- Comprehensive scene lifecycle management
- Combine-based reactive updates

## Platform Requirements

- iOS 17.0+ / macOS 14.0+
- Swift 5.10+
- Xcode 16+
- SwiftUI framework
- Metal-capable device for rendering

## See Also

- ``MTKCore`` — Core rendering engine and domain models
- ``MTKSceneKit`` — SceneKit integration layer for volume materials and camera control
