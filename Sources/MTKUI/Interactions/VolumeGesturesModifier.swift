//  VolumeGesturesModifier.swift
//  MTK
//  SwiftUI modifiers that forward user gestures to the volumetric controller.
//  Thales Matheus Mendonça Santos — October 2025

#if canImport(SwiftUI) && os(iOS)
import SwiftUI

/// SwiftUI view modifier that attaches volumetric interaction gestures to a view.
///
/// This modifier wires drag, pinch, and rotation gestures to a ``VolumetricSceneController``,
/// enabling interactive camera control, volume rotation, MPR slice navigation, and windowing adjustments.
/// The gesture behavior is controlled by a ``VolumeGestureConfiguration`` and state is tracked
/// through a ``VolumeGestureState`` observable object.
///
/// Use the ``SwiftUI/View/volumeGestures(controller:state:configuration:)`` extension instead
/// of instantiating this modifier directly.
///
/// - SeeAlso: ``VolumeGestureConfiguration``, ``VolumeGestureState``, ``VolumeGestureContext``
@MainActor
struct VolumeGesturesModifier: ViewModifier {
    /// Observable state tracking gesture events and accumulated windowing/slab changes.
    @ObservedObject private var state: VolumeGestureState

    /// The volumetric scene controller that will receive gesture-driven updates.
    private let controller: VolumetricSceneController

    /// Configuration toggles that enable or disable specific gesture capabilities.
    private let configuration: VolumeGestureConfiguration

    /// Creates a gesture modifier bound to the specified controller, state, and configuration.
    ///
    /// - Parameters:
    ///   - state: Observable state object that records gesture events and publishes changes.
    ///   - controller: Scene controller that will handle camera, rotation, and windowing updates.
    ///   - configuration: Toggles controlling which gestures are active.
    init(state: VolumeGestureState,
         controller: VolumetricSceneController,
         configuration: VolumeGestureConfiguration) {
        self.state = state
        self.controller = controller
        self.configuration = configuration
    }

    /// Attaches drag, magnification, and rotation gestures to the modified view.
    ///
    /// All three gestures are installed as simultaneous gestures, allowing multi-touch
    /// interactions. The gesture context merges state tracking with controller actions.
    ///
    /// - Parameter content: The SwiftUI view to which gestures will be attached.
    /// - Returns: The content view with volumetric gestures applied.
    func body(content: Content) -> some View {
        let context = state.makeContext(merging: controller.gestureContext(using: state))
        content
            .simultaneousGesture(makeTranslationGesture(context: context))
            .simultaneousGesture(makeMagnificationGesture(context: context))
            .simultaneousGesture(makeRotationGesture(context: context))
    }

    /// Builds a drag gesture that drives translation along the configured axis.
    ///
    /// When ``VolumeGestureConfiguration/translationAxis`` is `.volume`, the drag rotates
    /// the camera orbit. When set to a specific plane (`.axial`, `.coronal`, `.sagittal`),
    /// the drag translates the MPR slice along that axis. The gesture triggers a reset
    /// callback when the drag ends.
    ///
    /// - Parameter context: Callback context for routing gesture events.
    /// - Returns: A drag gesture configured with minimum distance and axis-aware handling.
    private func makeTranslationGesture(context: VolumeGestureContext) -> some Gesture {
        let axis = configuration.translationAxis ?? .volume
        return DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard configuration.allowsTranslation else { return }
                context.onTranslate(axis, value.translation)
            }
            .onEnded { _ in context.onReset() }
    }

    /// Builds a pinch gesture that drives camera zoom (dolly).
    ///
    /// The magnification value is forwarded to the context's `onZoom` callback, which
    /// typically maps it to camera distance changes via the controller's dolly method.
    ///
    /// - Parameter context: Callback context for routing gesture events.
    /// - Returns: A magnification gesture that forwards zoom factors when ``VolumeGestureConfiguration/allowsZoom`` is enabled.
    private func makeMagnificationGesture(context: VolumeGestureContext) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard configuration.allowsZoom else { return }
                context.onZoom(value)
            }
    }

    /// Builds a rotation gesture that drives camera roll or volume rotation.
    ///
    /// The rotation is always applied to the `.volume` axis, typically mapping to
    /// camera roll when the controller interprets volume-axis rotation as a camera operation.
    ///
    /// - Parameter context: Callback context for routing gesture events.
    /// - Returns: A rotation gesture that forwards angle changes when ``VolumeGestureConfiguration/allowsRotation`` is enabled.
    private func makeRotationGesture(context: VolumeGestureContext) -> some Gesture {
        RotationGesture()
            .onChanged { radians in
                guard configuration.allowsRotation else { return }
                context.onRotate(.volume, CGFloat(radians.radians))
            }
    }
}

/// SwiftUI view extensions for volumetric gesture handling.
public extension View {
    /// Attaches interactive volumetric gestures to the view, forwarding drag, pinch, and rotation to a scene controller.
    ///
    /// This modifier enables multi-touch interaction for volumetric rendering, including camera orbit, MPR slice navigation,
    /// zoom/dolly, and volume rotation. Gesture capabilities can be selectively enabled or disabled via the configuration parameter.
    ///
    /// ```swift
    /// VolumetricDisplayContainer(controller: coordinator.controller)
    ///     .volumeGestures(controller: coordinator.controller)
    /// ```
    ///
    /// For MPR-specific interactions with constrained translation axes:
    ///
    /// ```swift
    /// VolumetricDisplayContainer(controller: coordinator.controller)
    ///     .volumeGestures(
    ///         controller: coordinator.controller,
    ///         configuration: VolumeGestureConfiguration(translationAxis: .axial)
    ///     )
    /// ```
    ///
    /// - Parameters:
    ///   - controller: The volumetric scene controller that will handle gesture-driven updates.
    ///     This controller receives camera, rotation, windowing, and slab thickness events.
    ///   - state: Optional observable state object for tracking gesture events. When `nil`, a new
    ///     state instance is created automatically. Pass a shared instance to coordinate gesture
    ///     state across multiple views or to observe gesture events externally.
    ///   - configuration: Toggles controlling which gesture types are active and how translation
    ///     gestures are interpreted. Defaults to ``VolumeGestureConfiguration/default`` with all
    ///     gestures enabled and volume-axis translation.
    ///
    /// - Returns: A view modified with simultaneous drag, magnification, and rotation gesture recognizers.
    ///
    /// - SeeAlso: ``VolumeGestureConfiguration``, ``VolumeGestureState``, ``VolumetricSceneController``
    @MainActor
    func volumeGestures(controller: VolumetricSceneController,
                        state: VolumeGestureState? = nil,
                        configuration: VolumeGestureConfiguration = .default) -> some View {
        let resolvedState = state ?? VolumeGestureState()
        return modifier(
            VolumeGesturesModifier(state: resolvedState,
                                   controller: controller,
                                   configuration: configuration)
        )
    }
}

#endif
