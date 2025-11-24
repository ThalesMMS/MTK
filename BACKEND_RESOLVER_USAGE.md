# BackendResolver — usage guide

Lightweight helper that checks whether the Metal runtime is available before creating rendering controllers. It can optionally persist the result in `UserDefaults` for later sessions.

- **Location:** `Sources/MTKCore/Support/BackendResolver.swift`
- **Module:** `MTKCore`
- **Public API:** `BackendResolver`, `BackendResolutionError`

## What it checks
`BackendResolver` defers to `MetalRuntimeAvailability.isAvailable()` (backed by `MetalRuntimeGuard`) to confirm the current device supports the Metal features required by MTK’s volume rendering stack. It does not attempt to pick alternative backends; it only reports whether Metal is usable.

## Public API
```swift
public enum BackendResolutionError: LocalizedError, Equatable {
    case metalUnavailable
    case noBackendAvailable
}

public struct BackendResolver {
    public init(defaults: UserDefaults? = nil)
    public func checkMetalAvailability() throws -> Bool   // throws .metalUnavailable
    public func isMetalAvailable() -> Bool                // non-throwing check

    public static func checkConfiguredMetalAvailability(
        defaults: UserDefaults = .standard
    ) throws -> Bool
    public static func isMetalAvailable() -> Bool

    public static let metalAvailabilityKey = "volumetric.metalAvailable"
    public static let preferredBackendKey = "volumetric.preferredBackend"
}
```

## Typical usage
```swift
import MTKCore

let resolver = BackendResolver(defaults: .standard)

do {
    try resolver.checkMetalAvailability()   // persists the result when defaults != nil
    // Safe to create VolumetricSceneController or other Metal-backed components
} catch BackendResolutionError.metalUnavailable {
    // Present fallback UI or disable VR/MPR features
}

// Non-throwing check without persistence
if BackendResolver.isMetalAvailable() {
    // Proceed with Metal-based rendering
}
```

## Integration notes
- Call early in app launch to decide whether to present Metal-driven UI such as `VolumetricSceneController` or the MTK-Demo overlays.
- `preferredBackendKey` is reserved for clients that want to store a user preference (MTK currently only ships a Metal backend).
- When Metal is not available, higher-level code should avoid instantiating SceneKit/Metal views to prevent runtime errors.
