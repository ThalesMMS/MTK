# ``MTKUI``

SwiftUI components and controllers for medical volumetric visualization interfaces.

## Overview

MTKUI provides SwiftUI components, scene controllers, and gesture handling for building medical volumetric visualization applications on iOS and macOS. Built on top of MTKCore and MTKSceneKit, it includes MPR grids, interactive overlays, camera controls, and windowing tools for medical imaging workflows.

The framework handles scene coordination, gesture interpretation, UI overlays, and telemetry.

### Key Features

- **Scene Management**: VolumetricSceneController orchestrates rendering, camera, volume state, and MPS compute pipelines
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

Abstraction layer for SceneKit and Metal rendering surfaces.

- ``RenderSurface``
- ``SceneKitSurface``
- ``ImageSurface``

### UI Styling

Customizable styling protocols for volumetric UI components.

- ``VolumetricUIStyle``

## Quick Start

Create a basic volumetric scene with SwiftUI:

```swift
import SwiftUI
import MTKUI
import MTKCore

struct VolumetricView: View {
    @StateObject private var controller = VolumetricSceneController()

    var body: some View {
        VolumetricDisplayContainer(controller: controller) {
            // Optional overlays
            VStack {
                Spacer()
                WindowLevelControlView(
                    level: $controller.windowLevel,
                    window: $controller.windowWidth
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
        // Then apply it to the controller
        await controller.setDataset(myDataset)
    }
}
```

Create an MPR grid layout:

```swift
import SwiftUI
import MTKUI

struct MPRView: View {
    let coordinator = VolumetricSceneCoordinator.shared

    var body: some View {
        MPRGridComposer(
            volumeController: coordinator.volumeController(),
            axialController: coordinator.mprController(for: .z),
            coronalController: coordinator.mprController(for: .y),
            sagittalController: coordinator.mprController(for: .x)
        )
        .task {
            await coordinator.setDataset(myDataset)
        }
    }
}
```

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
