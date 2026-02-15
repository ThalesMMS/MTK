//  CameraInteraction.swift
//  MTK
//  Protocols for SceneKit camera interaction bridging to the UI layer.
//  Thales Matheus Mendonça Santos — October 2025

import Foundation
import simd

// MARK: - VolumeCameraControlling Protocol

/// Protocol for camera controllers that support interactive volumetric visualization.
///
/// This protocol defines the standard camera interaction operations for 3D volumetric
/// rendering: orbiting around a target, panning in the view plane, and zooming toward/away
/// from the focal point. Implementations provide the core camera manipulation behaviors
/// needed for interactive medical imaging applications.
///
/// ## Overview
///
/// The protocol supports three fundamental camera operations:
/// - **Orbit**: Rotate the camera around a target point in spherical coordinates
/// - **Pan**: Translate the camera and target together in the view plane
/// - **Zoom**: Move the camera toward or away from the target point
///
/// ## Conformance
///
/// Types conforming to this protocol should implement camera transformations that:
/// - Maintain numerical stability (avoid gimbal lock, handle degenerate cases)
/// - Clamp parameters to reasonable ranges
/// - Provide smooth, predictable camera motion
///
/// ## Usage
///
/// Gesture handlers typically call these methods to respond to user input:
///
/// ```swift
/// func handleDragGesture(_ gesture: DragGesture.Value, controller: VolumeCameraControlling) {
///     let delta = SIMD2<Float>(
///         Float(gesture.translation.width),
///         Float(gesture.translation.height)
///     )
///     controller.orbit(by: delta * 0.01)
/// }
///
/// func handlePinchGesture(_ gesture: MagnificationGesture.Value, controller: VolumeCameraControlling) {
///     controller.zoom(by: Float(gesture))
/// }
/// ```
///
/// - SeeAlso: ``VolumeCameraController``
/// - SeeAlso: ``CameraPose``
public protocol VolumeCameraControlling: AnyObject {
    /// Orbits the camera around the target point by the specified angular delta.
    ///
    /// - Parameter delta: Horizontal (X) and vertical (Y) orbit angles in radians
    func orbit(by delta: SIMD2<Float>)

    /// Pans the camera by translating both position and target in the view plane.
    ///
    /// - Parameter delta: Horizontal (X) and vertical (Y) translation distances in world units
    func pan(by delta: SIMD2<Float>)

    /// Zooms the camera by adjusting the distance to the target point.
    ///
    /// - Parameter factor: Zoom factor where values >1 zoom in, values <1 zoom out
    func zoom(by factor: Float)
}

// MARK: - VolumeCameraControllerStore

/// A thread-safe storage for weakly-held camera controllers keyed by arbitrary objects.
///
/// This store provides a central registry for camera controllers, allowing UI components
/// to register and retrieve controllers using weak references. Both keys and values are
/// stored weakly, preventing retain cycles and allowing automatic cleanup when either
/// the key or controller is deallocated.
///
/// ## Usage
///
/// ```swift
/// let store = VolumeCameraControllerStore()
/// let controller = VolumeCameraController()
///
/// // Register a controller
/// store.register(key: self, controller: controller)
///
/// // Retrieve the controller later
/// if let controller = store.controller(for: self) {
///     controller.orbit(by: SIMD2<Float>(0.1, 0.0))
/// }
///
/// // Clean up when done
/// store.remove(key: self)
/// ```
///
/// - Note: Uses `NSMapTable.weakToWeakObjects()` for automatic memory management
public final class VolumeCameraControllerStore {
    /// Internal weak-to-weak map table for storing controllers
    private var controllers: NSMapTable<AnyObject, AnyObject>

    /// Initializes a new camera controller store with weak references.
    public init() {
        controllers = NSMapTable<AnyObject, AnyObject>.weakToWeakObjects()
    }

    /// Registers a camera controller with the specified key.
    ///
    /// Both the key and controller are held weakly. If either is deallocated,
    /// the entry is automatically removed from the store.
    ///
    /// - Parameters:
    ///   - key: The object to use as a lookup key (typically a view or view controller)
    ///   - controller: The camera controller to associate with this key
    public func register(key: AnyObject, controller: VolumeCameraControlling) {
        controllers.setObject(controller, forKey: key)
    }

    /// Retrieves the camera controller associated with the specified key.
    ///
    /// - Parameter key: The object used as a lookup key during registration
    /// - Returns: The associated camera controller, or `nil` if not found or deallocated
    public func controller(for key: AnyObject) -> VolumeCameraControlling? {
        controllers.object(forKey: key) as? VolumeCameraControlling
    }

    /// Removes the camera controller associated with the specified key.
    ///
    /// - Parameter key: The object used as a lookup key during registration
    public func remove(key: AnyObject) {
        controllers.removeObject(forKey: key)
    }
}

