# Surface Adapter Analysis: Isis vs MTK

## Executive Summary

This document compares the Surface Adapter patterns used in the Isis DICOM Viewer with the new unified RenderSurface abstraction in MTK, highlighting the migration path and design improvements.

## Isis Implementation Analysis

### Location
- **Protocol**: `Isis DICOM Viewer/Presentation/Common/Rendering/RenderSurface.swift`
- **Adapter**: `Isis DICOM Viewer/Presentation/ViewModels/Viewer/VolumetricSessionState+Backend.swift`

### Protocol Definition

The Isis RenderSurface protocol:

```swift
@MainActor
public protocol RenderSurface: AnyObject {
    var view: PlatformView { get }
    func display(_ image: CGImage)
    func setContentScale(_ scale: CGFloat)
}
```

**Characteristics:**
- Platform-agnostic via `PlatformView` typealias (UIView on iOS, NSView on macOS)
- Requires @MainActor for thread safety
- Simple three-method contract
- Uses CoreGraphics CGImage for display

### SurfaceAdapter Implementation

The Isis SurfaceAdapter wraps another RenderSurface:

```swift
@MainActor
private final class SurfaceAdapter: RenderSurface {
    private var surface: any MTKUI.RenderSurface

    init(surface: any MTKUI.RenderSurface) {
        self.surface = surface
    }

    func update(surface: any MTKUI.RenderSurface) {
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

**Key Design Patterns:**
1. **Wrapper Pattern**: Encapsulates another RenderSurface
2. **Dynamic Updates**: `update()` method allows swapping wrapped surface
3. **Session State Integration**: Held by `MetalVolumetricsControllerAdapter`
4. **Import Dependency**: Requires `import MTKUI`

### Integration with Volume Rendering

The adapter is used in the session state:

```swift
@MainActor
final class MetalVolumetricsControllerAdapter: VolumetricSceneControlling {
    private let controller: MTKUI.VolumetricSceneController
    private let surfaceAdapter: SurfaceAdapter

    init() {
        self.controller = MTKUI.VolumetricSceneController()
        self.surfaceAdapter = SurfaceAdapter(surface: controller.surface)
    }

    var surface: any RenderSurface { surfaceAdapter }

    func applyDataset(_ dataset: VolumeDataset) async {
        await controller.applyDataset(dataset)
        surfaceAdapter.update(surface: controller.surface)  // Reactive update
    }
}
```

**Observations:**
- Session state owns both controller and adapter
- Adapter is updated reactively when dataset changes
- `MetalVolumetricsControllerAdapter` conforms to rendering protocols
- Provides abstraction layer for controller-specific behavior

## MTK Implementation

### Location
- **Protocol**: `MTK/Sources/MTKCore/Adapters/RenderSurface.swift`
- **No adapter required**: Apps implement directly

### Protocol Definition

The MTK RenderSurface protocol is identical:

```swift
@MainActor
public protocol RenderSurface: AnyObject {
    var view: PlatformView { get }
    func display(_ image: CGImage)
    func setContentScale(_ scale: CGFloat)
}
```

**Improvements over Isis:**
1. **No external dependencies**: Only CoreGraphics required
2. **Clear documentation**: Extensive inline docs and migration guide
3. **Public API**: Part of public framework surface, not internal
4. **Flexible patterns**: Guide for wrapper, direct, and custom adapters

### Recommended Implementation Patterns

#### Pattern 1: Direct Implementation

```swift
@MainActor
final class MyAppSurfaceAdapter: RenderSurface {
    private let metalView: MTKView

    init(metalView: MTKView) { self.metalView = metalView }

    var view: PlatformView { metalView }

    func display(_ image: CGImage) {
        // Render CGImage to MTKView
    }

    func setContentScale(_ scale: CGFloat) {
        metalView.contentScaleFactor = scale
    }
}
```

**Best for:** Simple apps with straightforward rendering needs

#### Pattern 2: Wrapper (from Isis)

```swift
@MainActor
final class SurfaceAdapter: RenderSurface {
    private var surface: any RenderSurface

    init(surface: any RenderSurface) { self.surface = surface }

    func update(surface: any RenderSurface) { self.surface = surface }

    var view: PlatformView { surface.view }
    func display(_ image: CGImage) { surface.display(image) }
    func setContentScale(_ scale: CGFloat) { surface.setContentScale(scale) }
}
```

**Best for:** Apps with dynamic surfaces, or those migrating from Isis

#### Pattern 3: Custom View

```swift
@MainActor
final class CustomSurfaceView: UIView, RenderSurface {
    private let displayLayer = CALayer()

    var view: PlatformView { self }
    func display(_ image: CGImage) { displayLayer.contents = image }
    func setContentScale(_ scale: CGFloat) { contentScaleFactor = scale }
}
```

**Best for:** Apps needing custom rendering or integration with existing views

## Comparative Analysis

| Aspect | Isis | MTK |
|--------|------|-----|
| **Protocol Location** | MTKUI | MTKCore |
| **External Dependencies** | MTKUI | None |
| **Thread Annotation** | @MainActor | @MainActor |
| **Platform Abstraction** | PlatformView typealias | PlatformView typealias |
| **Adapter Required** | SurfaceAdapter wrapper | Varies by pattern |
| **Documentation** | Minimal | Comprehensive |
| **Test Examples** | Limited | Full test suite |
| **Dynamic Updates** | Yes (update method) | Optional (use wrapper) |
| **Import Dependencies** | import MTKUI | import MTKCore |

## Migration Strategy

### Phase 1: Understanding
1. Analyze Isis SurfaceAdapter usage in your app
2. Identify the underlying surface (MTKView, custom, etc.)
3. Choose MTK migration pattern (1, 2, or 3)

### Phase 2: Implementation
1. Create new adapter implementing MTK's RenderSurface
2. Update session state to use new adapter
3. Remove MTKUI imports where possible

### Phase 3: Validation
1. Run existing tests against new adapter
2. Verify display behavior is identical
3. Test content scale changes on high-DPI displays

### Phase 4: Cleanup
1. Remove Isis-specific adapter code
2. Verify no lingering MTKUI imports
3. Update documentation to reference MTK patterns

## Key Design Improvements in MTK

### 1. No Hard Dependency on MTKUI

**Isis Problem:**
```swift
class SurfaceAdapter: RenderSurface {
    private var surface: any MTKUI.RenderSurface  // Hard dependency
}
```

**MTK Solution:**
```swift
class SurfaceAdapter: RenderSurface {
    private var surface: any RenderSurface  // Generic protocol, no framework dependency
}
```

**Benefit:** Apps can provide any RenderSurface implementation, not just those from MTKUI.

### 2. Clear Public API

**Isis:** RenderSurface is defined alongside MTKUI internals, causing confusion about scope.

**MTK:** RenderSurface is explicitly in the public Adapters submodule, with clear documentation of use cases.

### 3. Comprehensive Documentation

**Isis:** Minimal documentation; required reverse-engineering the pattern.

**MTK:** Detailed guide covering:
- Protocol contract
- Common patterns
- Migration steps
- Integration examples
- Troubleshooting

### 4. Test Accessibility

**Isis:** No public test suite for surface adapters.

**MTK:** Full test suite with examples of:
- Mock adapters
- Wrapper patterns
- Chaining adapters
- Integration tests

## Integration Points

### Before Migration (Isis Pattern)

```
Isis Session State
    ↓
MetalVolumetricsControllerAdapter
    ├─ MTKUI.VolumetricSceneController
    └─ SurfaceAdapter (wraps MTKUI.RenderSurface)
        └─ MTKUI.RenderSurface (from controller)
```

### After Migration (MTK Pattern)

```
App Session State
    ↓
VolumeRenderingController
    ├─ Rendering Backend
    └─ MyAppSurfaceAdapter (implements RenderSurface)
        └─ App's underlying surface (MTKView, etc.)
```

## Backward Compatibility

The MTK RenderSurface protocol is **not a breaking change** to Isis code. In fact:

1. Isis code can continue to use MTKUI.RenderSurface
2. New apps can use MTKCore.RenderSurface
3. Adapters implementing MTKCore.RenderSurface are interoperable with Isis if they conform to the protocol

## Recommendations

1. **For existing Isis apps:** Use Pattern 2 (wrapper) for minimal migration effort
2. **For new apps:** Use Pattern 1 (direct) for simplicity
3. **For complex rendering:** Use Pattern 3 (custom view) with custom CALayer management
4. **For dynamic surfaces:** Use Pattern 2 (wrapper) with update() method

## References

- Isis Protocol: `Presentation/Common/Rendering/RenderSurface.swift` (Isis DICOM Viewer)
- Isis Adapter: `Presentation/ViewModels/Viewer/VolumetricSessionState+Backend.swift` (Isis DICOM Viewer)
- MTK Protocol: `MTK/Sources/MTKCore/Adapters/RenderSurface.swift`
- Migration Guide: `MTK/Documentation/surface-adapter/migration.md`
- Test Suite: `MTK/Tests/MTKCoreTests/SurfaceAdapterTests.swift`
