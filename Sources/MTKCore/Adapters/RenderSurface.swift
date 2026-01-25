//
//  RenderSurface.swift
//  MTK (Metal Toolkit)
//
//  Unified abstraction for rendering surfaces in Metal-based volumetric rendering.
//  This protocol defines the contract that any app-specific rendering surface must
//  implement to integrate with the MTK volume rendering pipeline.
//
//  Key Design Principles:
//  - Platform-agnostic protocol allowing iOS, macOS, and custom implementations
//  - No Isis-specific dependencies or MTKUI imports
//  - Pure Metal-compatible abstraction layer
//  - Enables app-specific surface adapters while maintaining clean boundaries
//
//  Migration Pattern:
//  Apps migrating from Isis should:
//  1. Create an adapter implementing RenderSurface
//  2. Forward view, display, and setContentScale calls to their platform-specific surface
//  3. Update session state to use the new adapter
//  See: Documentation/surface-adapter/migration.md
//
//  Thales Matheus Mendonça Santos — November 2025

import Foundation
import CoreGraphics

#if os(iOS)
import UIKit
public typealias PlatformView = UIView
#elseif os(macOS)
import AppKit
public typealias PlatformView = NSView
#else
#error("RenderSurface is currently unsupported on this platform")
#endif

/// Abstraction protocol for any surface capable of displaying rendered Metal output.
///
/// Implementers of this protocol are responsible for:
/// - Providing access to a platform-specific view (UIView on iOS, NSView on macOS)
/// - Displaying CGImage results from the volume renderer
/// - Managing content scaling for high-DPI displays
///
/// Example implementation for a simple MTKView-backed surface:
/// ```swift
/// @MainActor
/// final class MetalKitSurfaceAdapter: RenderSurface {
///     private let metalView: MTKView
///
///     var view: PlatformView { metalView }
///
///     func display(_ image: CGImage) {
///         // Convert CGImage to MTLTexture and update metalView
///     }
///
///     func setContentScale(_ scale: CGFloat) {
///         metalView.contentScaleFactor = scale
///     }
/// }
/// ```
@MainActor
public protocol RenderSurface: AnyObject {
    /// The platform-specific view representing this rendering surface.
    ///
    /// On iOS, this returns a UIView. On macOS, this returns an NSView.
    /// The view is typically embedded in the app's view hierarchy to display
    /// the rendered output.
    var view: PlatformView { get }

    /// Display a rendered image on the surface.
    ///
    /// - Parameter image: A CGImage containing the rendered volumetric data.
    ///
    /// This method is called on the main thread after volumetric rendering
    /// completes. Implementers should update the surface's display to show
    /// the new image.
    func display(_ image: CGImage)

    /// Update the content scale factor for high-DPI displays.
    ///
    /// - Parameter scale: The device's scale factor (typically 1.0, 2.0, or 3.0).
    ///
    /// This method is called when the surface is first attached and whenever
    /// the display's scale factor changes (e.g., moving between displays on macOS).
    /// Implementers should propagate this scale to any underlying Metal views
    /// to ensure correct rendering at the display's native resolution.
    func setContentScale(_ scale: CGFloat)
}

// MARK: - Platform-Specific Helpers

#if os(iOS)
/// Convenience function to create a PlatformView with a specific frame.
/// Useful for testing and creating custom surface adapters.
public func createPlatformView(frame: CGRect) -> UIView {
    return UIView(frame: frame)
}
#elseif os(macOS)
/// Convenience function to create a PlatformView with a specific frame.
/// Useful for testing and creating custom surface adapters.
public func createPlatformView(frame: NSRect) -> NSView {
    return NSView(frame: frame)
}
#endif

// MARK: - Documentation and Examples

/// # RenderSurface Migration Guide
///
/// ## Overview
/// When migrating volume rendering from one app to another (e.g., from Isis to a new app),
/// the primary integration point is the RenderSurface protocol. This allows the MTK
/// volume rendering pipeline to remain agnostic of app-specific view hierarchies.
///
/// ## Pattern: Creating an Adapter
///
/// ### Step 1: Define Your App's Backing Surface
/// Identify what view or Metal surface your app uses for rendering:
/// ```swift
/// // Example: Using MTKView as the backing surface
/// let metalView = MTKView()
/// ```
///
/// ### Step 2: Create a RenderSurface Adapter
/// Implement the protocol to wrap your app's surface:
/// ```swift
/// @MainActor
/// final class MyAppSurfaceAdapter: RenderSurface {
///     private let backingSurface: MTKView
///
///     init(backingSurface: MTKView) {
///         self.backingSurface = backingSurface
///     }
///
///     var view: PlatformView {
///         backingSurface  // MTKView is a UIView on iOS, NSView on macOS
///     }
///
///     func display(_ image: CGImage) {
///         // Render the CGImage to the MTKView
///         // This might involve:
///         // 1. Converting CGImage to MTLTexture
///         // 2. Updating a render pass to display the texture
///         // 3. Committing the render command buffer
///     }
///
///     func setContentScale(_ scale: CGFloat) {
///         backingSurface.contentScaleFactor = scale
///     }
/// }
/// ```
///
/// ### Step 3: Integrate with Volume Rendering Controller
/// Pass your adapter to the volume rendering pipeline:
/// ```swift
/// let adapter = MyAppSurfaceAdapter(backingSurface: myMetalView)
/// volumeController.setSurface(adapter)
/// ```
///
/// ## Common Patterns
///
/// ### Pattern: Wrapper Adapter (Used in Isis)
/// The SurfaceAdapter in Isis demonstrates a common pattern: wrapping another
/// RenderSurface implementation for additional control or transformation.
/// ```swift
/// @MainActor
/// final class WrappingAdapter: RenderSurface {
///     private var wrappedSurface: any RenderSurface
///
///     func update(surface: any RenderSurface) {
///         self.wrappedSurface = surface
///     }
///
///     var view: PlatformView { wrappedSurface.view }
///     func display(_ image: CGImage) { wrappedSurface.display(image) }
///     func setContentScale(_ scale: CGFloat) { wrappedSurface.setContentScale(scale) }
/// }
/// ```
///
/// ### Pattern: Testing Stub
/// For unit tests, a simple in-memory stub can suffice:
/// ```swift
/// @MainActor
/// final class TestSurfaceAdapter: RenderSurface {
///     var view: PlatformView { UIView() }
///     func display(_ image: CGImage) {}
///     func setContentScale(_ scale: CGFloat) {}
/// }
/// ```
///
/// ## Design Principles
///
/// - **Platform-Agnostic**: The protocol uses PlatformView to abstract iOS/macOS differences
/// - **Minimal Contract**: Only three methods are required; implement only what you need
/// - **Main-Thread Bound**: All calls are @MainActor; rendering is thread-safe by design
/// - **Stateless Display**: The `display(_:)` method is fire-and-forget; no buffering required
/// - **No Assumptions**: The adapter doesn't assume Metal, SceneKit, or any specific backend

/// For full examples and migration scenarios, see:
/// - Documentation/surface-adapter/migration.md
/// - Tests/MTKCoreTests/SurfaceAdapterTests.swift
