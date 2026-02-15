//  VolumetricDisplayContainer.swift
//  MTK
//  Simple container that hosts the render surface and optional overlays.
//  Thales Matheus Mendonça Santos — October 2025

#if canImport(SwiftUI)
import SwiftUI
import OSLog

/// A SwiftUI container view that hosts a volumetric render surface with optional overlay views.
///
/// `VolumetricDisplayContainer` provides a flexible layout for displaying volumetric rendered content
/// by combining a Metal-backed render surface with arbitrary SwiftUI overlay views. The container
/// automatically tracks and logs size changes for diagnostics and debugging.
///
/// ## Overview
///
/// This view bridges Metal-based volumetric rendering with SwiftUI's declarative layout system,
/// making it easy to compose interactive overlays (crosshairs, orientation labels, controls) on top
/// of GPU-rendered medical imagery.
///
/// The container uses `GeometryReader` to fill available space and passes the render surface from
/// the provided ``VolumetricSceneController`` to a `RenderSurfaceView`. Custom overlays are composed
/// in a `ZStack` above the render layer.
///
/// ## Usage
///
/// ### Basic container without overlays
///
/// ```swift
/// struct BasicVolumeView: View {
///     @StateObject private var controller = VolumetricSceneController()
///
///     var body: some View {
///         VolumetricDisplayContainer(controller: controller)
///             .onAppear {
///                 // Apply dataset and configure rendering
///             }
///     }
/// }
/// ```
///
/// ### Container with overlay views
///
/// ```swift
/// struct OverlayVolumeView: View {
///     @StateObject private var controller = VolumetricSceneController()
///
///     var body: some View {
///         VolumetricDisplayContainer(controller: controller) {
///             CrosshairOverlayView()
///             OrientationOverlayView()
///             WindowLevelControlView(
///                 level: $windowLevel,
///                 window: $windowWidth,
///                 onCommit: applyWindowLevel
///             )
///         }
///     }
/// }
/// ```
///
/// ## Topics
///
/// ### Creating a Container
/// - ``init(controller:overlays:)``
/// - ``init(controller:)``
///
/// ### Instance Properties
/// - ``body``
///
/// - Note: This view requires a Metal-capable device. The render surface will remain blank if
///   Metal is unavailable.
/// - Important: The container tracks size changes and logs warnings when the view has degenerate
///   dimensions (width or height ≤ 1pt).
@MainActor
public struct VolumetricDisplayContainer<Overlays: View>: View {
    /// The controller managing the volumetric scene and render surface.
    @ObservedObject private var controller: VolumetricSceneController

    /// Tracks the last logged size to avoid redundant log entries.
    @State private var lastLoggedSize: CGSize = .zero

    /// Logger for size tracking and diagnostics.
    private let logger = Logger(subsystem: "com.isis.viewer", category: "VolumetricDisplayContainer")

    /// Closure providing custom overlay views.
    private let overlays: () -> Overlays

    /// Creates a volumetric display container with custom overlay views.
    ///
    /// - Parameters:
    ///   - controller: The ``VolumetricSceneController`` managing the volumetric scene state
    ///     and render surface.
    ///   - overlays: A `ViewBuilder` closure returning SwiftUI views to layer on top of the
    ///     render surface. Overlays are composed in a `ZStack` above the Metal render layer.
    ///
    /// ## Example
    ///
    /// ```swift
    /// VolumetricDisplayContainer(controller: sceneController) {
    ///     CrosshairOverlayView()
    ///     OrientationOverlayView(
    ///         labels: ("R", "L", "A", "P"),
    ///         style: customStyle
    ///     )
    /// }
    /// ```
    public init(controller: VolumetricSceneController,
                @ViewBuilder overlays: @escaping () -> Overlays) {
        self.controller = controller
        self.overlays = overlays
    }

    /// The SwiftUI view hierarchy combining the render surface and overlays.
    ///
    /// Uses `GeometryReader` to fill the available space, hosting the Metal render surface
    /// via `RenderSurfaceView` and layering custom overlays in a `ZStack`. Size changes are
    /// logged for diagnostics.
    ///
    /// - Important: The render surface is assigned the accessibility identifier
    ///   `"VolumetricRenderSurface"` for UI testing purposes.
    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                RenderSurfaceView(surface: controller.surface)
                    .accessibilityIdentifier("VolumetricRenderSurface")
                overlays()
            }
            .onAppear { logSize(proxy.size) }
            .onChange(of: proxy.size) { logSize($0) }
        }
    }
}

/// Convenience initializer for containers without overlays.
public extension VolumetricDisplayContainer where Overlays == EmptyView {
    /// Creates a volumetric display container without overlay views.
    ///
    /// This convenience initializer creates a container that displays only the volumetric
    /// render surface, without any additional overlays.
    ///
    /// - Parameter controller: The ``VolumetricSceneController`` managing the volumetric scene
    ///   state and render surface.
    ///
    /// ## Example
    ///
    /// ```swift
    /// struct MinimalVolumeView: View {
    ///     @StateObject private var controller = VolumetricSceneController()
    ///
    ///     var body: some View {
    ///         VolumetricDisplayContainer(controller: controller)
    ///     }
    /// }
    /// ```
    ///
    /// - Note: For containers with overlays, use ``init(controller:overlays:)`` instead.
    init(controller: VolumetricSceneController) {
        self.init(controller: controller) { EmptyView() }
    }
}

/// Private helpers for size tracking and logging.
private extension VolumetricDisplayContainer {
    /// Logs container size changes for diagnostics.
    ///
    /// This method tracks size changes and emits log entries when the container dimensions
    /// change. Degenerate sizes (width or height ≤ 1pt) trigger warnings, while normal
    /// size changes are logged at debug level.
    ///
    /// - Parameter size: The new container size in points.
    ///
    /// ## Behavior
    ///
    /// - Size changes are deduplicated; identical consecutive sizes don't generate new log entries.
    /// - Sizes with width or height ≤ 1pt emit a warning about degenerate dimensions.
    /// - Normal size changes emit debug-level log entries.
    ///
    /// - Important: This method updates the `lastLoggedSize` state to track the most recent
    ///   logged size.
    func logSize(_ size: CGSize) {
        guard size != lastLoggedSize else { return }
        lastLoggedSize = size
        if size.width <= 1 || size.height <= 1 {
            logger.warning("Volumetric container has degenerate size width=\(size.width) height=\(size.height)")
        } else {
            logger.debug("Volumetric container size width=\(size.width) height=\(size.height)")
        }
    }
}
#endif
