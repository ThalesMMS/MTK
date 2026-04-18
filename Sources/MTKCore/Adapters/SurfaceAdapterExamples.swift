//
//  SurfaceAdapterExamples.swift
//  MTK (Metal Toolkit)
//
//  Real-world examples of RenderSurface adapter implementations for different
//  application scenarios. These examples demonstrate fail-fast, Metal-only
//  integration patterns and can be used as templates for app-specific
//  implementations.
//
//  NOTE: This file contains example code and documentation. The actual implementations
//  should be copied into your app's codebase, not imported from MTK.
//
//  Thales Matheus Mendonça Santos — November 2025

import Foundation
import CoreGraphics

#if os(iOS)
import UIKit
import MetalKit
#elseif os(macOS)
import AppKit
import MetalKit
#endif

// MARK: - Example 1: Simple MTKView Adapter

/// A straightforward adapter for apps using MTKView as their rendering surface.
///
/// This is the recommended starting point for most applications. It assumes:
/// - You have an MTKView set up in your UI
/// - You want to display volumetric rendered images
/// - You don't need dynamic surface switching
///
/// Usage:
/// ```swift
/// let metalView = MTKView()
/// let adapter = SimpleMTKViewAdapter(metalView: metalView)
/// let volumeController = VolumeRenderingController(surface: adapter)
/// ```
#if canImport(MetalKit)
@MainActor
public final class SimpleMTKViewAdapter: RenderSurface {
    private let metalView: MTKView

    public init(metalView: MTKView) {
        self.metalView = metalView
    }

    public var view: PlatformView { metalView }

    public func display(_ image: CGImage) {
        // In a real implementation, convert CGImage to MTLTexture
        // and update the MTKView's drawable
        //
        // Pseudocode:
        // 1. Create or update MTLTexture from CGImage
        // 2. Update render pass descriptor with texture
        // 3. Encode render commands
        // 4. Present drawable

        // For now, we'll store the image reference
        // Your actual implementation would render this
        _ = image  // Use the image in your render pipeline
    }

    public func setContentScale(_ scale: CGFloat) {
        #if os(iOS) || os(tvOS)
        metalView.contentScaleFactor = scale
        #elseif os(macOS)
        metalView.layer?.contentsScale = scale
        #endif
        // Notify any observers that the rendering scale changed
        // This typically triggers a re-render at the new resolution
    }
}
#endif

// MARK: - Example 2: Wrapper Adapter (from Isis)

/// A wrapper adapter that allows dynamic surface switching.
///
/// This pattern is useful when:
/// - Your surface may change at runtime
/// - You want to decouple surface instances from the volume controller
/// - You're migrating from Isis and want minimal changes
///
/// Usage:
/// ```swift
/// let initialAdapter = SimpleMTKViewAdapter(metalView: view1)
/// let wrapper = DynamicSurfaceAdapter(initialAdapter)
///
/// // Later, switch to a different surface
/// let newAdapter = SimpleMTKViewAdapter(metalView: view2)
/// wrapper.updateSurface(newAdapter)
/// ```
@MainActor
public final class DynamicSurfaceAdapter: RenderSurface {
    private var wrapped: any RenderSurface

    public init(_ wrapped: any RenderSurface) {
        self.wrapped = wrapped
    }

    /// Update the wrapped surface at runtime.
    ///
    /// This method allows swapping the underlying surface without recreating
    /// the adapter. Useful for view controller transitions or multi-window scenarios.
    public func updateSurface(_ newSurface: any RenderSurface) {
        self.wrapped = newSurface
    }

    public var view: PlatformView {
        wrapped.view
    }

    public func display(_ image: CGImage) {
        wrapped.display(image)
    }

    public func setContentScale(_ scale: CGFloat) {
        wrapped.setContentScale(scale)
    }
}

// MARK: - Example 3: Logging/Debugging Adapter

/// An adapter that logs all surface operations for debugging.
///
/// Useful for:
/// - Understanding when display updates occur
/// - Debugging scale factor issues
/// - Performance profiling
/// - Integration testing
///
/// Usage:
/// ```swift
/// let baseAdapter = SimpleMTKViewAdapter(metalView: view)
/// let loggingAdapter = LoggingSurfaceAdapter(wrapped: baseAdapter)
/// let volumeController = VolumeRenderingController(surface: loggingAdapter)
/// // All adapter calls will be logged to the console
/// ```
@MainActor
public final class LoggingSurfaceAdapter: RenderSurface {
    private let wrapped: any RenderSurface
    private let identifier: String

    public init(wrapped: any RenderSurface, identifier: String = "Surface") {
        self.wrapped = wrapped
        self.identifier = identifier
    }

    public var view: PlatformView {
        print("[LoggingSurfaceAdapter.\(identifier)] Accessed view")
        return wrapped.view
    }

    public func display(_ image: CGImage) {
        print("[LoggingSurfaceAdapter.\(identifier)] Displaying image: \(image.width)x\(image.height)")
        wrapped.display(image)
    }

    public func setContentScale(_ scale: CGFloat) {
        print("[LoggingSurfaceAdapter.\(identifier)] Setting content scale to \(scale)")
        wrapped.setContentScale(scale)
    }
}

// MARK: - Example 4: View Controller Integration Adapter

/// An adapter for integrating with UIViewController/NSViewController.
///
/// This example shows how to manage the adapter's lifecycle within a view controller.
///
/// Usage:
/// ```swift
/// class VolumetricViewController: UIViewController {
///     let adapter: ViewControllerSurfaceAdapter = ...
///
///     override func viewDidLoad() {
///         super.viewDidLoad()
///         view.addSubview(adapter.view)
///     }
/// }
/// ```
#if os(iOS)
@MainActor
public final class ViewControllerSurfaceAdapter: RenderSurface {
    private let displayView: UIView

    public init() {
        self.displayView = UIView()
        self.displayView.backgroundColor = .black
    }

    public var view: PlatformView { displayView }

    public func display(_ image: CGImage) {
        // Create an image view if needed
        let imageLayer = CALayer()
        imageLayer.contents = image
        imageLayer.frame = displayView.bounds
        displayView.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        displayView.layer.addSublayer(imageLayer)
    }

    public func setContentScale(_ scale: CGFloat) {
        displayView.contentScaleFactor = scale
    }
}
#elseif os(macOS)
@MainActor
public final class ViewControllerSurfaceAdapter: RenderSurface {
    private let displayView: NSView

    public init() {
        self.displayView = NSView()
        self.displayView.wantsLayer = true
        self.displayView.layer?.backgroundColor = NSColor.black.cgColor
    }

    public var view: PlatformView { displayView }

    public func display(_ image: CGImage) {
        let imageLayer = CALayer()
        imageLayer.contents = image
        imageLayer.frame = displayView.bounds
        displayView.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        displayView.layer?.addSublayer(imageLayer)
    }

    public func setContentScale(_ scale: CGFloat) {
        displayView.layer?.contentsScale = scale
    }
}
#endif

// MARK: - Example 5: Recording Adapter

/// An adapter that captures displayed images for recording or analysis.
///
/// Useful for:
/// - Saving volumetric renderings to disk
/// - Creating video recordings
/// - Image comparison testing
/// - Performance analysis
///
/// Usage:
/// ```swift
/// let baseAdapter = SimpleMTKViewAdapter(metalView: view)
/// let recordingAdapter = RecordingSurfaceAdapter(wrapped: baseAdapter)
/// recordingAdapter.startRecording(toURL: outputURL)
/// // ... rendering happens ...
/// let images = recordingAdapter.stopRecording()
/// ```
@MainActor
public final class RecordingSurfaceAdapter: RenderSurface {
    private let wrapped: any RenderSurface
    private var isRecording = false
    private var recordedImages: [CGImage] = []

    public init(wrapped: any RenderSurface) {
        self.wrapped = wrapped
    }

    public var view: PlatformView { wrapped.view }

    public func display(_ image: CGImage) {
        if isRecording {
            recordedImages.append(image)
        }
        wrapped.display(image)
    }

    public func setContentScale(_ scale: CGFloat) {
        wrapped.setContentScale(scale)
    }

    // Recording control
    public func startRecording() {
        isRecording = true
        recordedImages.removeAll()
    }

    public func stopRecording() -> [CGImage] {
        isRecording = false
        return recordedImages
    }

    public var recordedFrameCount: Int {
        recordedImages.count
    }
}

// MARK: - Example 6: Multi-Surface Adapter

/// An adapter that can display the same image on multiple surfaces.
///
/// Useful for:
/// - Picture-in-picture displays
/// - Multi-window scenarios
/// - Synchronized rendering
/// - Testing with multiple outputs
///
/// Usage:
/// ```swift
/// let surface1 = SimpleMTKViewAdapter(metalView: view1)
/// let surface2 = SimpleMTKViewAdapter(metalView: view2)
/// let multiAdapter = MultiSurfaceAdapter(surfaces: [surface1, surface2])
/// let volumeController = VolumeRenderingController(surface: multiAdapter)
/// // Both surfaces display the same rendered image
/// ```
@MainActor
public final class MultiSurfaceAdapter: RenderSurface {
    private let surfaces: [any RenderSurface]
    private let primaryIndex: Int

    public init(surfaces: [any RenderSurface], primaryIndex: Int = 0) {
        self.surfaces = surfaces
        self.primaryIndex = min(primaryIndex, max(0, surfaces.count - 1))
    }

    public var view: PlatformView {
        guard primaryIndex < surfaces.count else {
            #if os(iOS) || os(tvOS)
            return UIView()
            #else
            return NSView()
            #endif
        }
        return surfaces[primaryIndex].view
    }

    public func display(_ image: CGImage) {
        for surface in surfaces {
            surface.display(image)
        }
    }

    public func setContentScale(_ scale: CGFloat) {
        for surface in surfaces {
            surface.setContentScale(scale)
        }
    }

    public var surfaceCount: Int {
        surfaces.count
    }
}

// MARK: - Example 7: Runtime-Gated Adapter

/// A Metal-only adapter that enforces the runtime requirement before surface construction.
///
/// Useful for:
/// - Failing fast when Metal is unavailable
/// - Surfacing unsupported-runtime states explicitly
/// - Preventing adapter stacks from being created on unsupported hosts
/// - Aligning app integrations with MTK's Metal-only runtime contract
///
/// Prefer checking `MetalRuntimeAvailability.isAvailable()` before creating this
/// adapter in your UI layer so unsupported states can present a
/// `ContentUnavailableView` (or another explicit error state) before any Metal
/// surface is instantiated.
///
/// Usage:
/// ```swift
/// if MetalRuntimeAvailability.isAvailable() {
///     let adapter = try RuntimeGatedSurfaceAdapter(metalView: metalView)
///     let volumeController = VolumeRenderingController(surface: adapter)
/// } else {
///     let status = MetalRuntimeAvailability.status()
///     // Present ContentUnavailableView with a message derived from status.
/// }
/// ```
#if canImport(MetalKit)
@MainActor
public final class RuntimeGatedSurfaceAdapter: RenderSurface {
    private let wrapped: SimpleMTKViewAdapter

    public init(metalView: MTKView) throws {
        try MetalRuntimeAvailability.ensureAvailability()
        self.wrapped = SimpleMTKViewAdapter(metalView: metalView)
    }

    public var view: PlatformView { wrapped.view }

    public func display(_ image: CGImage) {
        wrapped.display(image)
    }

    public func setContentScale(_ scale: CGFloat) {
        wrapped.setContentScale(scale)
    }
}
#endif

// MARK: - Composition Example

/// Example showing how to compose multiple adapters for a production setup.
///
/// This demonstrates:
/// - Checking the Metal runtime requirement before constructing the surface chain
/// - Layering adapters for different concerns (runtime gating, recording, logging)
/// - Building a rendering pipeline with explicit unsupported-state handling
/// - Maintaining clean separation of concerns
///
/// Usage:
/// ```swift
/// let primaryView = MTKView()
///
/// if MetalRuntimeAvailability.isAvailable() {
///     do {
///         let baseAdapter = try RuntimeGatedSurfaceAdapter(metalView: primaryView)
///         let recorded = RecordingSurfaceAdapter(wrapped: baseAdapter)
///         let logged = LoggingSurfaceAdapter(
///             wrapped: recorded,
///             identifier: "VolumetricRenderer"
///         )
///
///         let volumeController = VolumeRenderingController(surface: logged)
///         recorded.startRecording()
///     } catch {
///         // Present an explicit error state if the runtime check fails during init.
///     }
/// } else {
///     let status = MetalRuntimeAvailability.status()
///     // Map status.missingFeatures into a ContentUnavailableView or other
///     // unsupported-runtime UI. Keep the error path explicit.
/// }
/// ```

// MARK: - Best Practices

/// # Adapter Implementation Best Practices
///
/// 1. **Check Metal runtime availability before constructing surface chains**
///    - Use `MetalRuntimeAvailability.isAvailable()` for UI gating
///    - Use `MetalRuntimeAvailability.ensureAvailability()` in init paths
///    - Present explicit unsupported-runtime UI instead of silent recovery paths
///
/// 2. **Always mark as @MainActor**
///    - Ensures thread safety
///    - Compiler prevents accidental background thread calls
///
/// 3. **Implement view property efficiently**
///    - Cache the view if expensive to compute
///    - Don't create new views on each access
///
/// 4. **Keep display() non-blocking**
///    - Offload heavy work to background queues
///    - Return quickly to unblock rendering
///
/// 5. **Handle content scale properly**
///    - Update all affected layers and views
///    - Propagate scale to Metal rendering
///    - Test on multiple screen densities
///
/// 6. **Use composition over inheritance**
///    - Wrap adapters rather than subclassing
///    - Easier to combine multiple concerns
///    - More flexible at runtime
///
/// 7. **Test adapter implementations**
///    - Use provided test suite as template
///    - Test with real MTKView
///    - Verify scale changes work correctly
///
/// 8. **Document your adapter**
///    - Explain what surfaces it manages
///    - Document any special behavior
///    - Provide usage examples
///
/// 9. **Minimize adapter overhead**
///    - Each display() call happens frequently
///    - Keep wrapper adapters lightweight
///    - Cache expensive computations

// MARK: - Testing Helpers

/// Create a test image for adapter testing.
///
/// Returns a simple grayscale image suitable for testing display behavior.
public func createTestGrayscaleImage(width: Int = 256, height: Int = 256) -> CGImage {
    let pixelCount = width * height
    var pixels = [UInt8](repeating: 128, count: pixelCount)

    // Create a simple pattern
    for y in 0..<height {
        for x in 0..<width {
            pixels[y * width + x] = UInt8(clamping: (x + y) % 256)
        }
    }

    let dataProvider = CGDataProvider(data: Data(pixels) as CFData)!
    let colorSpace = CGColorSpaceCreateDeviceGray()

    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 8,
        bytesPerRow: width,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: dataProvider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}
