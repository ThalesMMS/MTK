//  MPRGridComposer.swift
//  MTK
//  Minimal SwiftUI container syncing orthogonal MPR panes.
//  Thales Matheus Mendonça Santos — October 2025

#if canImport(SwiftUI) && os(iOS)
import MTKCore
import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// A SwiftUI view that composes a synchronized multi-planar reconstruction (MPR) grid layout.
///
/// `MPRGridComposer` presents a 2×2 grid containing three orthogonal MPR slice views (axial,
/// coronal, sagittal) and one 3D volumetric view, with synchronized window/level controls
/// and slab thickness adjustments applied to all MPR panes.
///
/// ## Overview
///
/// Multi-planar reconstruction is a standard medical imaging visualization technique that displays
/// volume data along three orthogonal anatomical planes:
/// - **Axial**: Horizontal slices (top-down view)
/// - **Coronal**: Frontal slices (front-to-back view)
/// - **Sagittal**: Lateral slices (side view)
///
/// This composer orchestrates four separate ``VolumeViewportController`` instances—one for each
/// plane and one for 3D rendering—ensuring that window/level adjustments and slab thickness
/// settings remain synchronized across the MPR views.
///
/// ## Topics
///
/// ### Creating a Grid Composer
/// - ``init(volumeController:axialController:coronalController:sagittalController:style:)``
///
/// ### Instance Properties
/// - ``body``
///
/// ## Usage
///
/// ### Basic MPR grid setup
///
/// ```swift
/// struct MPRView: View {
///     @StateObject private var volumeController = VolumeViewportController()
///     @StateObject private var axialController = VolumeViewportController()
///     @StateObject private var coronalController = VolumeViewportController()
///     @StateObject private var sagittalController = VolumeViewportController()
///
///     var body: some View {
///         MPRGridComposer(
///             volumeController: volumeController,
///             axialController: axialController,
///             coronalController: coronalController,
///             sagittalController: sagittalController
///         )
///         .task {
///             // Load dataset and configure controllers
///             let dataset = try await loadDicomVolume()
///             await applyDatasetToAllControllers(dataset)
///         }
///     }
/// }
/// ```
///
/// ### Custom styling
///
/// ```swift
/// MPRGridComposer(
///     volumeController: volumeController,
///     axialController: axialController,
///     coronalController: coronalController,
///     sagittalController: sagittalController,
///     style: CustomVolumetricUIStyle()
/// )
/// ```
///
/// ## Layout
///
/// The grid is arranged as follows:
///
/// ```
/// ┌─────────┬─────────┐
/// │  Axial  │ Coronal │
/// ├─────────┼─────────┤
/// │Sagittal │   3D    │
/// └─────────┴─────────┘
/// ```
///
/// Each pane includes:
/// - **MPR views**: Crosshair overlays, orientation labels (R/L/A/P/S/I), and gesture handlers
/// - **3D view**: Free rotation with a "3D" label overlay
/// - **Shared controls**: Slab thickness and window/level sliders below the grid
///
/// - Note: This view is iOS-only due to platform-specific gesture and UI dependencies.
/// - Important: Window/level changes from the axial controller are automatically synchronized
///   to the coronal and sagittal controllers. The 3D view is not affected by window/level adjustments.
@MainActor
public struct MPRGridComposer: View {
    /// Controller for the 3D volumetric view (bottom-right pane).
    private let volumeController: VolumeViewportController

    /// Controller for the axial MPR view (top-left pane).
    private let axialController: VolumeViewportController

    /// Controller for the coronal MPR view (top-right pane).
    private let coronalController: VolumeViewportController

    /// Controller for the sagittal MPR view (bottom-left pane).
    private let sagittalController: VolumeViewportController

    /// Visual style for overlay UI elements (crosshairs, labels, controls).
    private let style: any VolumetricUIStyle

    /// Current window/level settings synchronized across MPR views.
    @State private var windowLevel = WindowLevelShift(window: 400, level: 40)

    /// Current slab thickness in millimeters applied to all MPR views.
    @State private var slabThickness: Double = 3

    /// Creates an MPR grid composer with four synchronized volumetric controllers.
    ///
    /// - Parameters:
    ///   - volumeController: The controller managing the 3D volumetric view (bottom-right pane).
    ///   - axialController: The controller managing the axial MPR view (top-left pane).
    ///   - coronalController: The controller managing the coronal MPR view (top-right pane).
    ///   - sagittalController: The controller managing the sagittal MPR view (bottom-left pane).
    ///   - style: The visual style for overlay UI elements. Defaults to ``DefaultVolumetricUIStyle``.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let grid = MPRGridComposer(
    ///     volumeController: volumeController,
    ///     axialController: axialController,
    ///     coronalController: coronalController,
    ///     sagittalController: sagittalController,
    ///     style: DefaultVolumetricUIStyle()
    /// )
    /// ```
    ///
    /// - Important: All controllers should be configured with the same dataset for proper
    ///   MPR synchronization. Window/level and slab thickness settings are applied to the
    ///   three MPR controllers but not to the volume controller.
    public init(volumeController: VolumeViewportController,
                axialController: VolumeViewportController,
                coronalController: VolumeViewportController,
                sagittalController: VolumeViewportController,
                style: any VolumetricUIStyle = DefaultVolumetricUIStyle()) {
        self.volumeController = volumeController
        self.axialController = axialController
        self.coronalController = coronalController
        self.sagittalController = sagittalController
        self.style = style
    }

    /// The SwiftUI view hierarchy composing the MPR grid layout.
    ///
    /// Presents a 2×2 grid with axial, coronal, and sagittal MPR views plus a 3D volumetric view,
    /// along with synchronized slab thickness and window/level controls at the bottom.
    ///
    /// ## Layout Structure
    ///
    /// - Top row: Axial (left) and Coronal (right) MPR panes
    /// - Bottom row: Sagittal (left) and 3D volume (right) panes
    /// - Controls: Slab thickness slider and window/level controls below the grid
    ///
    /// - Note: The view uses `onAppear` to initialize window/level state from the axial controller
    ///   and `onReceive` to synchronize updates across all MPR views.
    public var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                mprPane(axis: .axial, controller: axialController)
                mprPane(axis: .coronal, controller: coronalController)
            }
            HStack(spacing: 12) {
                mprPane(axis: .sagittal, controller: sagittalController)
                volumePane()
            }
            SlabThicknessControlView(thickness: $slabThickness, onCommit: commitSlab(thickness:))
            WindowLevelControlView(level: Binding(get: { windowLevel.level }, set: { windowLevel.level = $0 }),
                                   window: Binding(get: { windowLevel.window }, set: { windowLevel.window = $0 }),
                                   onCommit: commitWindowLevel)
        }
        .padding()
        .onAppear {
            windowLevel = WindowLevelShift(window: axialController.windowLevelState.window,
                                           level: axialController.windowLevelState.level)
        }
        .onReceive(axialController.statePublisher.$windowLevelState) { state in
            windowLevel = WindowLevelShift(window: state.window, level: state.level)
        }
    }

    /// Creates a styled MPR pane view for a specific anatomical plane.
    ///
    /// - Parameters:
    ///   - axis: The anatomical plane axis (axial, coronal, or sagittal).
    ///   - controller: The controller managing the MPR view for this plane.
    ///
    /// - Returns: A view containing the render surface with crosshair, orientation labels,
    ///   and gesture overlays, styled with rounded corners and shadow.
    ///
    /// ## Overlay Components
    ///
    /// Each MPR pane includes:
    /// - `CrosshairOverlayView`: Centered crosshair marking the current slice intersection
    /// - `OrientationOverlayView`: Anatomical direction labels (R/L/A/P/S/I)
    /// - `VolumetricGestureOverlay`: Gesture recognizers for slice scrolling and window/level adjustment
    ///
    /// - Note: The gesture configuration restricts translation to the specified anatomical axis.
    private func mprPane(axis: VolumeGestureAxis,
                         controller: VolumeViewportController) -> some View {
        let gestureConfiguration = VolumeGestureConfiguration(translationAxis: axis)
        return VolumeViewportContainer(controller: controller) {
            ZStack {
                CrosshairOverlayView(style: style)
                OrientationOverlayView(transform: displayTransform(for: axis), style: style)
                VolumetricGestureOverlay(controller: controller,
                                         configuration: gestureConfiguration)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
    }

    /// Creates the 3D volumetric view pane.
    ///
    /// - Returns: A view containing the 3D volumetric render surface with a "3D" label overlay
    ///   and free rotation gesture support, styled with rounded corners and shadow.
    ///
    /// ## Features
    ///
    /// - Displays the full 3D volume with interactive rotation/zoom
    /// - Shows a "3D" badge in the bottom-left corner
    /// - Supports pan, pinch, and rotation gestures via `VolumetricGestureOverlay`
    ///
    /// - Note: Unlike MPR panes, the 3D view is not affected by window/level adjustments
    ///   from the control panel.
    private func volumePane() -> some View {
        return VolumeViewportContainer(controller: volumeController) {
            ZStack {
                VStack {
                    Spacer()
                    HStack {
                        Text("3D")
                            .font(.caption.bold())
                            .padding(6)
                            .background(style.overlayBackground.cornerRadius(12))
                            .foregroundStyle(style.overlayForeground)
                            .padding(8)
                        Spacer()
                    }
                }
                VolumetricGestureOverlay(controller: volumeController)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
    }

    /// Commits slab thickness changes to all MPR controllers.
    ///
    /// - Parameter thickness: The new slab thickness in millimeters.
    ///
    /// ## Behavior
    ///
    /// Creates a slab configuration with the specified thickness and applies it asynchronously
    /// to the axial, coronal, and sagittal controllers. The 3D volumetric controller is not
    /// affected.
    ///
    /// - Note: Slab thickness controls how many slices are blended together in thick-slab
    ///   MPR rendering modes (MIP, MinIP, average intensity).
    private func commitSlab(thickness: Double) {
        Task {
            let thicknessInVoxels = Int(thickness)
            let steps = max(thicknessInVoxels * 2, 6)
            let snap = VolumeViewportController.SlabConfiguration(thickness: thicknessInVoxels,
                                                                  steps: steps)
            for controller in mprControllers {
                await controller.setMprSlab(thickness: snap.thickness, steps: snap.steps)
            }
        }
    }

    /// Commits window/level changes to all MPR controllers.
    ///
    /// Converts the current window and level values into minimum and maximum HU thresholds
    /// and applies them asynchronously to the axial, coronal, and sagittal controllers.
    ///
    /// ## Window/Level Calculation
    ///
    /// ```
    /// min = level - (window / 2)
    /// max = level + (window / 2)
    /// ```
    ///
    /// - Important: The 3D volumetric controller is not affected by window/level adjustments
    ///   from this control panel.
    private func commitWindowLevel() {
        Task {
            let min = Int32(windowLevel.level - windowLevel.window / 2)
            let max = Int32(windowLevel.level + windowLevel.window / 2)
            for controller in mprControllers {
                await controller.setMprHuWindow(min: min, max: max)
            }
        }
    }

    private func displayTransform(for axis: VolumeGestureAxis) -> MPRDisplayTransform {
        switch axis {
        case .axial:
            return MPRDisplayTransformFactory.makeTransform(for: .canonical(axis: .z), axis: .z)
        case .coronal:
            return MPRDisplayTransformFactory.makeTransform(for: .canonical(axis: .y), axis: .y)
        case .sagittal:
            return MPRDisplayTransformFactory.makeTransform(for: .canonical(axis: .x), axis: .x)
        case .volume:
            return .identity
        }
    }

    /// Returns the array of MPR controllers (axial, coronal, sagittal).
    ///
    /// This computed property provides a convenient collection of the three MPR controllers
    /// for synchronized operations like window/level and slab thickness updates.
    ///
    /// - Returns: An array containing the axial, coronal, and sagittal controllers in order.
    ///
    /// - Note: The 3D volumetric controller is intentionally excluded from this collection.
    private var mprControllers: [VolumeViewportController] {
        [axialController, coronalController, sagittalController]
    }
}

/// Private helpers for gesture axis mapping.
private extension VolumeGestureAxis {
    /// Converts a gesture axis to a controller axis enumeration.
    ///
    /// Maps anatomical plane axes to the corresponding controller coordinate axis:
    /// - Sagittal → X axis (left/right slices)
    /// - Coronal → Y axis (front/back slices)
    /// - Axial/Volume → Z axis (top/bottom slices)
    ///
    /// - Returns: The corresponding ``VolumeViewportController/Axis`` value.
    func toControllerAxis() -> VolumeViewportController.Axis {
        switch self {
        case .sagittal:
            return .x
        case .coronal:
            return .y
        case .axial, .volume:
            return .z
        }
    }
}

/// Private helpers for grid index mapping.
private extension MPRGridComposer {
    /// Returns the grid index for a given anatomical axis.
    ///
    /// Maps anatomical plane axes to their position in the grid layout:
    /// - Axial → 0 (top-left)
    /// - Coronal → 1 (top-right)
    /// - Sagittal → 2 (bottom-left)
    /// - Volume → 3 (bottom-right)
    ///
    /// - Parameter axis: The anatomical plane axis.
    /// - Returns: The zero-based grid index (0-3).
    func mprIndex(for axis: VolumeGestureAxis) -> Int {
        switch axis {
        case .axial:
            return 0
        case .coronal:
            return 1
        case .sagittal:
            return 2
        case .volume:
            return 3
        }
    }
}
#endif
