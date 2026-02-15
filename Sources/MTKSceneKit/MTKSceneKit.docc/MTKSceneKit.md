# ``MTKSceneKit``

SceneKit integration layer for medical volumetric visualization with Metal-based rendering.

## Overview

MTKSceneKit bridges the MTKCore rendering engine with Apple's SceneKit framework, providing materials, camera controllers, and scene graph integration for 3D medical visualization.

The framework provides specialized SceneKit materials that wrap Metal shaders for Direct Volume Rendering (DVR), Maximum Intensity Projection (MIP), and Multi-Planar Reconstruction (MPR), along with camera management for interactive volumetric exploration.

### Key Features

- **SceneKit Materials**: Drop-in materials for volume cubes and MPR planes with Metal shader integration
- **Camera Management**: Camera controller with orbit, pan, zoom, and preset configurations
- **Camera Pose System**: Serializable camera state for saving/restoring viewpoints
- **Rendering Modes**: DVR, MIP, MinIP, and Average Intensity Projection (AIP) support
- **MPR Support**: Thick slab rendering with MIP/MinIP/Mean blending modes
- **Transfer Function Integration**: Direct integration with MTKCore transfer function presets

## Topics

### Essentials

- ``VolumeCubeMaterial``
- ``MPRPlaneMaterial``
- ``VolumeCameraController``
- ``CameraPose``

### SceneKit Materials

Materials that integrate Metal-based volume rendering into SceneKit's scene graph.

- ``VolumeCubeMaterial``
- ``MPRPlaneMaterial``

### Camera Management

Camera controllers and pose management for volumetric interaction.

- ``VolumeCameraController``
- ``CameraPose``
- ``CameraInteraction``
- ``ProjectionType``

### SceneKit Extensions

Extensions to SceneKit types for volumetric rendering integration.

- ``SCNNode``

## Quick Start

Create a basic SceneKit volume rendering scene:

```swift
import MTKSceneKit
import MTKCore
import SceneKit
import Metal

// Create Metal device
guard let device = MTLCreateSystemDefaultDevice() else {
    fatalError("Metal not available")
}

// Create volume dataset (see MTKCore for details)
let dataset = VolumeDataset(
    data: volumeData,
    dimensions: VolumeDimensions(width: 256, height: 256, depth: 128),
    spacing: VolumeSpacing(x: 0.001, y: 0.001, z: 0.0015),
    pixelFormat: .int16Signed,
    intensityRange: (-1024)...3071
)

// Create volume cube material
let volumeMaterial = try VolumeCubeMaterial(device: device)
try volumeMaterial.setVolume(dataset)
try volumeMaterial.setMethod(.dvr)
try volumeMaterial.setPreset(.softTissue)

// Create SceneKit geometry with volume material
let cube = SCNBox(
    width: 0.256,
    height: 0.256,
    length: 0.128,
    chamferRadius: 0
)
cube.materials = [volumeMaterial]

// Create volume node
let volumeNode = SCNNode(geometry: cube)

// Setup camera controller
let cameraController = VolumeCameraController()
cameraController.reset()

// Apply camera to SceneKit camera node
let cameraNode = SCNNode()
cameraNode.camera = SCNCamera()
let pose = cameraController.cameraPose
cameraNode.position = SCNVector3(pose.position)
cameraNode.look(at: SCNVector3(pose.target))
```

## SceneKit Integration

MTKSceneKit materials integrate seamlessly with SceneKit's rendering pipeline:

1. **Volume Material**: `VolumeCubeMaterial` wraps a Metal fragment shader that performs ray marching through the volume texture
2. **MPR Material**: `MPRPlaneMaterial` renders thick slab projections for axial, coronal, and sagittal views
3. **Camera Control**: `VolumeCameraController` manages camera transformations with medical imaging conventions
4. **Scene Graph**: Materials work with standard SceneKit nodes, lights, and cameras

## Camera Interaction Patterns

The camera controller supports common 3D interaction patterns:

```swift
// Orbit around the volume
cameraController.orbit(by: SIMD2<Float>(0.1, 0.1))

// Pan the camera
cameraController.pan(by: SIMD2<Float>(0.5, 0.0))

// Zoom in/out
cameraController.zoom(by: 1.2)

// Reset to default view
cameraController.reset()

// Save/restore camera pose
let savedPose = cameraController.cameraPose
// ... later ...
cameraController.apply(pose: savedPose)
```

## Platform Requirements

- iOS 17.0+ / macOS 14.0+
- Swift 5.10+
- Xcode 16+
- Metal-capable device
- SceneKit framework

## See Also

- ``MTKCore`` — Core rendering engine and domain models
- ``MTKUI`` — SwiftUI components and controllers for volumetric visualization
