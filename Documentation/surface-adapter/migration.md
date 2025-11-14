# Surface Adapter Migration Guide

## Overview

This document provides a comprehensive guide for migrating Surface Adapter implementations from the Isis DICOM Viewer to applications using the MTK (Metal Toolkit) volume rendering pipeline.

## Problem Statement

The Isis DICOM Viewer uses a `SurfaceAdapter` pattern to abstract app-specific rendering surfaces from the volume rendering controller. When migrating to MTK, applications need a consistent mechanism to integrate their own rendering surfaces with the MTK pipeline.

## Solution: RenderSurface Protocol

MTK defines a unified `RenderSurface` protocol in `MTK/Sources/MTKCore/Adapters/RenderSurface.swift`. This protocol is:

- **Platform-agnostic**: Works on iOS and macOS
- **Backend-agnostic**: No dependence on Isis, MTKUI, or specific Metal frameworks
- **Simple**: Only three required methods
- **Thread-safe**: Main-thread bound with @MainActor annotations

### RenderSurface Protocol

```swift
@MainActor
public protocol RenderSurface: AnyObject {
    var view: PlatformView { get }
    func display(_ image: CGImage)
    func setContentScale(_ scale: CGFloat)
}
```

## Migration Patterns

### Pattern 1: Direct MTKView Adapter (Simple)

For apps that use MTKView directly:

```swift
import MetalKit
import MTKCore

@MainActor
final class MetalKitSurfaceAdapter: RenderSurface {
    private let metalView: MTKView

    init(metalView: MTKView) {
        self.metalView = metalView
    }

    var view: PlatformView { metalView }

    func display(_ image: CGImage) {
        // Convert CGImage to Metal texture and render
        updateMetalViewWithImage(image)
    }

    func setContentScale(_ scale: CGFloat) {
        metalView.contentScaleFactor = scale
    }

    private func updateMetalViewWithImage(_ image: CGImage) {
        // Implementation depends on your MTKView setup
        // Typically involves:
        // 1. Creating/updating an MTLTexture from the CGImage
        // 2. Rendering the texture in your render pipeline
        // 3. Presenting the drawable
    }
}
```

### Pattern 2: Wrapper Adapter (From Isis)

The Isis pattern uses a wrapper adapter that forwards to another RenderSurface:

```swift
@MainActor
final class SurfaceAdapter: RenderSurface {
    private var surface: any RenderSurface

    init(surface: any RenderSurface) {
        self.surface = surface
    }

    func update(surface: any RenderSurface) {
        self.surface = surface
    }

    var view: PlatformView { surface.view }

    func display(_ image: CGImage) {
        surface.display(image)
    }

    func setContentScale(_ scale: CGFloat) {
        surface.setContentScale(scale)
    }
}
```

**Benefits:**
- Decouples the session state from specific surface implementations
- Allows swapping surface implementations at runtime
- Useful when the surface may change (e.g., view controllers being replaced)

### Pattern 3: Custom View with CALayer Rendering (Complex)

For custom views that use Core Animation:

```swift
import MTKCore

@MainActor
final class CustomSurfaceView: UIView, RenderSurface {
    private let displayLayer = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var view: PlatformView { self }

    func display(_ image: CGImage) {
        displayLayer.contents = image
    }

    func setContentScale(_ scale: CGFloat) {
        contentScaleFactor = scale
        displayLayer.contentsScale = scale
    }
}
```

## Migration Steps

### Step 1: Analyze Your Current Surface Implementation

Examine how your app currently manages rendering surfaces:

```swift
// Example from Isis:
// - Uses MTKView for Metal rendering
// - Wraps it in a SurfaceAdapter for abstraction
// - Session state holds the adapter, not the view directly
```

### Step 2: Choose a Migration Pattern

Select which pattern matches your use case:

| Pattern | Use Case | Complexity |
|---------|----------|------------|
| Direct MTKView Adapter | Simple MTKView-based apps | Low |
| Wrapper Adapter | Apps with dynamic surfaces | Medium |
| Custom View Adapter | Non-standard rendering | High |

### Step 3: Create Your RenderSurface Implementation

Create a new adapter class implementing `RenderSurface`:

```swift
@MainActor
final class MyAppSurfaceAdapter: RenderSurface {
    // ... implementation from step 2
}
```

### Step 4: Integrate with Volume Rendering Controller

Update your session/controller initialization:

```swift
// Before (Isis pattern):
let surfaceAdapter = SurfaceAdapter(surface: controller.surface)

// After (MTK pattern):
let surfaceAdapter = MyAppSurfaceAdapter(metalView: myMetalView)
let volumeController = VolumeRenderingController(surface: surfaceAdapter)
```

### Step 5: Remove Isis Dependencies

Once migration is complete:

- Remove `import MTKUI` where not needed
- Remove `MTKUI.RenderSurface` references
- Use only `MTKCore.RenderSurface`

## Key Differences from Isis

| Aspect | Isis | MTK |
|--------|------|-----|
| Protocol Definition | `MTKUI.RenderSurface` | `MTKCore.RenderSurface` |
| Dependencies | Requires MTKUI | Minimal; only CoreGraphics |
| Platform Support | iOS + macOS via typealiases | iOS + macOS via PlatformView typealias |
| Wrapper Pattern | Common (SurfaceAdapter) | Available but optional |
| Thread Safety | @MainActor | @MainActor |

## Common Implementation Details

### Displaying CGImage on Metal

When implementing `display(_ image: CGImage)`, you typically need to:

1. **Convert CGImage to MTLTexture**:
   ```swift
   func cgImageToMetalTexture(_ cgImage: CGImage) -> MTLTexture? {
       let loader = MTKTextureLoader(device: metalDevice)
       return try? loader.newTexture(cgImage: cgImage, options: nil)
   }
   ```

2. **Update your render pipeline** to use the texture

3. **Commit the render command buffer** and present the drawable

### Content Scale Handling

On high-DPI displays, MTKit will call `setContentScale(_:)` with the device's scale factor:

```swift
func setContentScale(_ scale: CGFloat) {
    // Update Metal view's scale
    metalView.contentScaleFactor = scale

    // Update any CALayers
    metalView.layer.contentsScale = scale

    // Notify rendering pipeline of resolution change
    updateRenderingResolution(scale: scale)
}
```

## Testing

Create test stubs for unit testing:

```swift
@MainActor
final class MockSurfaceAdapter: RenderSurface {
    var view: PlatformView { UIView() }
    var lastDisplayedImage: CGImage?
    var contentScale: CGFloat = 1.0

    func display(_ image: CGImage) {
        lastDisplayedImage = image
    }

    func setContentScale(_ scale: CGFloat) {
        contentScale = scale
    }
}
```

## Troubleshooting

### "Cannot convert UIView to RenderSurface"

Ensure your adapter class explicitly conforms to `RenderSurface`:

```swift
// Wrong
class MySurface: UIView {
    // ...
}

// Correct
class MySurface: RenderSurface {
    // ...
}
```

### "Main thread assertion failure"

All RenderSurface calls must happen on the main thread. Ensure your adapter is marked `@MainActor`:

```swift
@MainActor
final class MySurfaceAdapter: RenderSurface {
    // ...
}
```

### "Module 'MTKUI' not found"

If you're seeing this error after migration, check that you're using `MTKCore.RenderSurface` instead of `MTKUI.RenderSurface`.

## References

- Source: `MTK/Sources/MTKCore/Adapters/RenderSurface.swift`
- Isis Reference: `Isis DICOM Viewer/Presentation/ViewModels/Viewer/VolumetricSessionState+Backend.swift`
- Example Tests: `MTK/Tests/MTKCoreTests/SurfaceAdapterTests.swift`

## Related Documentation

- [MTK Volume Rendering Architecture](./VolumeRenderingArchitecture.md)
- [Metal Integration Guide](./MetalIntegration.md)
- [Threading and Main-Thread Safety](./ThreadingSafety.md)
