//  TriplanarMPRComposer.swift
//  MTK
//  SwiftUI container syncing three orthogonal MPR panes.
//  Thales Matheus Mendonca Santos - April 2026

#if canImport(SwiftUI) && (os(iOS) || os(macOS))
import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A SwiftUI view that composes synchronized axial, coronal, and sagittal MPR panes.
///
/// `TriplanarMPRComposer` presents tri-planar multi-planar reconstruction as a
/// first-class layout without requiring a 3D volume controller. It coordinates three
/// ``VolumetricSceneController`` instances, one for each anatomical plane, and keeps
/// shared MPR controls such as window/level and slab thickness synchronized across
/// those panes only.
///
/// Use this component when an interface needs pure tri-planar MPR instead of the
/// higher-level MPR plus 3D composition provided by ``MPRGridComposer``.
///
/// ## Overview
///
/// Multi-planar reconstruction displays volume data along three orthogonal planes:
/// - **Axial**: Horizontal slices
/// - **Coronal**: Frontal slices
/// - **Sagittal**: Lateral slices
///
/// The composer applies shared control changes to the axial, coronal, and sagittal
/// controllers. No volume controller participates in layout, synchronization, or
/// dataset lifecycle.
///
/// ## Topics
///
/// ### Creating a Tri-Planar Composer
/// - ``init(axialController:coronalController:sagittalController:style:layout:)``
///
/// ### Choosing a Layout
/// - ``Layout``
///
/// ### Instance Properties
/// - ``body``
@MainActor
public struct TriplanarMPRComposer: View {
    /// Supported arrangements for the three MPR panes.
    public enum Layout {
        /// Places axial, coronal, and sagittal panes in a single horizontal row.
        case horizontal

        /// Places axial, coronal, and sagittal panes in a single vertical column.
        case vertical

        /// Places axial and coronal panes on the first row and sagittal on the second row.
        case grid
    }

    /// Controller for the axial MPR view.
    private let axialController: VolumetricSceneController

    /// Controller for the coronal MPR view.
    private let coronalController: VolumetricSceneController

    /// Controller for the sagittal MPR view.
    private let sagittalController: VolumetricSceneController

    /// Visual style for overlay UI elements and controls.
    private let style: any VolumetricUIStyle

    /// Pane arrangement used by the composer.
    private let layout: Layout

    /// Current slab thickness in millimeters applied to all MPR views.
    @State private var slabThickness: Double = 3

    /// Current window/level settings synchronized across MPR views.
    @State private var windowLevel = WindowLevelShift(window: 400, level: 40)

    /// Creates a tri-planar MPR composer with three synchronized MPR controllers.
    ///
    /// - Parameters:
    ///   - axialController: The controller managing the axial MPR view.
    ///   - coronalController: The controller managing the coronal MPR view.
    ///   - sagittalController: The controller managing the sagittal MPR view.
    ///   - style: The visual style for overlay UI elements and controls.
    ///     Defaults to ``DefaultVolumetricUIStyle``.
    ///   - layout: The pane arrangement. Defaults to ``Layout/horizontal``.
    ///
    /// - Important: Configure the three MPR controllers with the same dataset for
    ///   consistent crosshair, slice navigation, slab, and window/level behavior.
    public init(axialController: VolumetricSceneController,
                coronalController: VolumetricSceneController,
                sagittalController: VolumetricSceneController,
                style: any VolumetricUIStyle = DefaultVolumetricUIStyle(),
                layout: Layout = .horizontal) {
        self.axialController = axialController
        self.coronalController = coronalController
        self.sagittalController = sagittalController
        self.style = style
        self.layout = layout
    }

    /// The SwiftUI view hierarchy composing the tri-planar MPR layout.
    public var body: some View {
        VStack(spacing: 12) {
            switch layout {
            case .horizontal:
                HStack(spacing: 12) {
                    mprPane(axis: .axial, controller: axialController)
                    mprPane(axis: .coronal, controller: coronalController)
                    mprPane(axis: .sagittal, controller: sagittalController)
                }
            case .vertical:
                VStack(spacing: 12) {
                    mprPane(axis: .axial, controller: axialController)
                    mprPane(axis: .coronal, controller: coronalController)
                    mprPane(axis: .sagittal, controller: sagittalController)
                }
            case .grid:
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        mprPane(axis: .axial, controller: axialController)
                        mprPane(axis: .coronal, controller: coronalController)
                    }
                    HStack(spacing: 12) {
                        mprPane(axis: .sagittal, controller: sagittalController)
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .accessibilityHidden(true)
                    }
                }
            }

            SlabThicknessControlView(thickness: $slabThickness,
                                     style: style,
                                     onCommit: commitSlab(thickness:))
            WindowLevelControlView(level: Binding(get: { windowLevel.level },
                                                  set: { windowLevel.level = $0 }),
                                   window: Binding(get: { windowLevel.window },
                                                   set: { windowLevel.window = $0 }),
                                   style: style,
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

    /// Returns the array of MPR controllers in anatomical order.
    private var mprControllers: [VolumetricSceneController] {
        [axialController, coronalController, sagittalController]
    }

    /// Creates a single MPR pane for the specified anatomical axis backed by the given volumetric controller.
    /// 
    /// The pane presents the controller's volumetric display with orientation labels, crosshair, and gesture handling, and applies consistent styling (square aspect ratio, background, rounded corners, and shadow).
    /// - Parameters:
    ///   - axis: The anatomical axis used to configure orientation labels and gesture translation.
    ///   - controller: The `VolumetricSceneController` that provides the display and interaction state for the pane.
    /// - Returns: A view representing the composed, styled MPR pane.
    private func mprPane(axis: VolumeGestureAxis,
                         controller: VolumetricSceneController) -> some View {
        let gestureConfiguration = VolumeGestureConfiguration(translationAxis: axis)
        return VolumetricDisplayContainer(controller: controller) {
            ZStack {
                CrosshairOverlayView(style: style)
                OrientationOverlayView(labels: labels(for: axis), style: style)
                gestureOverlay(controller: controller,
                               configuration: gestureConfiguration)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .background(paneBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
    }

    /// Creates the platform-specific gesture layer for an MPR pane.
    @ViewBuilder
    private func gestureOverlay(controller: VolumetricSceneController,
                                configuration: VolumeGestureConfiguration) -> some View {
#if os(iOS)
        VolumetricGestureOverlay(controller: controller,
                                 configuration: configuration)
#else
        Color.clear
            .accessibilityHidden(true)
#endif
    }

    /// Platform-native pane background color.
    private var paneBackground: Color {
#if os(iOS)
        Color(.systemBackground)
#elseif os(macOS)
        Color(NSColor.windowBackgroundColor)
#endif
    }

    /// Applies slab thickness changes to all tri-planar MPR controllers.
    ///
    /// The provided thickness is truncated to whole voxels and converted to a
    /// thickness-scaled sample count before being applied to each MPR controller.
    /// - Parameter thickness: Desired slab thickness from the shared MPR control.
    private func commitSlab(thickness: Double) {
        Task {
            let thicknessInVoxels = Int(thickness)
            let steps = max(thicknessInVoxels * 2, 6)
            let snap = VolumetricSceneController.SlabConfiguration(thickness: thicknessInVoxels,
                                                                   steps: steps)
            for controller in mprControllers {
                await controller.setMprSlab(thickness: snap.thickness, steps: snap.steps)
            }
        }
    }

    /// Updates all MPR controllers with the current window/level by computing HU min/max and applying them.
    /// 
    /// Computes HU bounds as:
    /// - min = Int32(windowLevel.level - windowLevel.window / 2)
    /// - max = Int32(windowLevel.level + windowLevel.window / 2)
    /// Then applies these bounds to each controller in `mprControllers`.
    private func commitWindowLevel() {
        Task {
            let min = Int32(windowLevel.level - windowLevel.window / 2)
            let max = Int32(windowLevel.level + windowLevel.window / 2)
            for controller in mprControllers {
                await controller.setMprHuWindow(min: min, max: max)
            }
        }
    }

    /// Returns orientation labels for the given gesture axis.
    /// - Parameter axis: The volume gesture axis representing the displayed plane.
    /// - Returns: A tuple `(left, right, top, bottom)` containing single-character orientation labels for that plane; empty strings for the `.volume` axis.
    private func labels(for axis: VolumeGestureAxis) -> (String, String, String, String) {
        switch axis {
        case .axial:
            return ("R", "L", "A", "P")
        case .coronal:
            return ("R", "L", "S", "I")
        case .sagittal:
            return ("P", "A", "S", "I")
        case .volume:
            return ("", "", "", "")
        }
    }
}
#endif
