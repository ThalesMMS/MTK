//
//  VolumeCameraController.swift
//  MTK - MTKSceneKit
//
//  Enhanced camera controller combining simple state management with MTK protocols.
//  Phase 9: Migrated from MTK-Demo and enhanced for reuse across all MTK consumers.
//  Thales Matheus Mendonça Santos — November 2025
//

import Foundation
import simd
import SceneKit

/// Enhanced camera controller for volumetric rendering.
///
/// This controller provides a complete camera management solution that combines:
/// - Simple position/rotation state management
/// - MTK's VolumeCameraControlling protocol implementation
/// - Integration with CameraPose for complete camera state
/// - Standard camera operations (orbit, pan, zoom)
/// - Reset and preset configurations
///
/// ## Usage
///
/// ```swift
/// let cameraController = VolumeCameraController()
///
/// // Access camera state
/// let position = cameraController.position
/// let rotation = cameraController.rotation
///
/// // Apply camera operations
/// cameraController.orbit(by: SIMD2<Float>(0.1, 0.1))
/// cameraController.pan(by: SIMD2<Float>(0.5, 0.0))
/// cameraController.zoom(by: 1.2)
///
/// // Get complete camera pose
/// let pose = cameraController.cameraPose
///
/// // Reset to defaults
/// cameraController.reset()
/// ```
@MainActor
public final class VolumeCameraController: VolumeCameraControlling {

    // MARK: - Simple State Management

    private var _position: SIMD3<Float>
    private var _rotation: SIMD3<Float>
    private var _target: SIMD3<Float>
    private var _fieldOfView: Float

    /// The camera's position in world space
    public var position: SIMD3<Float> {
        get { _position }
        set { _position = newValue }
    }

    /// The camera's rotation in euler angles (radians)
    public var rotation: SIMD3<Float> {
        get { _rotation }
        set { _rotation = newValue }
    }

    /// The point in world space that the camera is looking at
    public var target: SIMD3<Float> {
        get { _target }
        set { _target = newValue }
    }

    /// The vertical field of view in degrees
    public var fieldOfView: Float {
        get { _fieldOfView }
        set { _fieldOfView = newValue }
    }

    // MARK: - Configuration

    /// Camera configuration defining position, orientation, and viewing parameters.
    ///
    /// This struct encapsulates all parameters needed to configure a camera state,
    /// including its position in world space, rotation angles, target point, and
    /// field of view. Use preset configurations like ``Configuration/default``,
    /// ``Configuration/frontView``, ``Configuration/sideView``, and ``Configuration/topView``
    /// for common viewing angles.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Create custom configuration
    /// let config = VolumeCameraController.Configuration(
    ///     position: SIMD3<Float>(3, 2, 4),
    ///     rotation: SIMD3<Float>(0.2, 0.5, 0),
    ///     target: SIMD3<Float>(0, 0, 0),
    ///     fieldOfView: 45.0
    /// )
    ///
    /// let controller = VolumeCameraController(configuration: config)
    ///
    /// // Or use a preset
    /// let frontView = VolumeCameraController.Configuration.frontView
    /// controller.apply(configuration: frontView)
    /// ```
    public struct Configuration {
        /// The camera's position in world space coordinates.
        public var position: SIMD3<Float>

        /// The camera's rotation in Euler angles (radians) for pitch, yaw, and roll.
        public var rotation: SIMD3<Float>

        /// The point in world space that the camera is looking at (focal point).
        public var target: SIMD3<Float>

        /// The vertical field of view in degrees (typically 30-90 degrees).
        public var fieldOfView: Float

        /// Standard default configuration with camera positioned at (0, 0, 5) looking at origin.
        ///
        /// This configuration provides a neutral front view of the volume:
        /// - Position: `(0, 0, 5)` — 5 units in front of the origin
        /// - Rotation: `(0, 0, 0)` — no rotation
        /// - Target: `(0, 0, 0)` — looking at the origin
        /// - Field of View: `60°` — standard perspective
        public static var `default`: Configuration {
            Configuration(
                position: SIMD3<Float>(0, 0, 5),
                rotation: SIMD3<Float>(0, 0, 0),
                target: SIMD3<Float>(0, 0, 0),
                fieldOfView: 60.0
            )
        }

        /// Front view configuration (identical to default).
        ///
        /// Positions the camera in front of the volume looking toward the origin.
        /// - Position: `(0, 0, 5)` — 5 units along positive Z-axis
        /// - Rotation: `(0, 0, 0)` — no rotation
        /// - Target: `(0, 0, 0)` — looking at origin
        /// - Field of View: `60°`
        public static var frontView: Configuration {
            Configuration(
                position: SIMD3<Float>(0, 0, 5),
                rotation: SIMD3<Float>(0, 0, 0),
                target: SIMD3<Float>(0, 0, 0),
                fieldOfView: 60.0
            )
        }

        /// Side view configuration (sagittal orientation).
        ///
        /// Positions the camera to the side of the volume for sagittal visualization.
        /// - Position: `(5, 0, 0)` — 5 units along positive X-axis
        /// - Rotation: `(0, π/2, 0)` — 90° yaw rotation
        /// - Target: `(0, 0, 0)` — looking at origin
        /// - Field of View: `60°`
        public static var sideView: Configuration {
            Configuration(
                position: SIMD3<Float>(5, 0, 0),
                rotation: SIMD3<Float>(0, .pi / 2, 0),
                target: SIMD3<Float>(0, 0, 0),
                fieldOfView: 60.0
            )
        }

        /// Top view configuration (axial orientation).
        ///
        /// Positions the camera above the volume for axial (top-down) visualization.
        /// - Position: `(0, 5, 0)` — 5 units along positive Y-axis
        /// - Rotation: `(π/2, 0, 0)` — 90° pitch rotation
        /// - Target: `(0, 0, 0)` — looking down at origin
        /// - Field of View: `60°`
        public static var topView: Configuration {
            Configuration(
                position: SIMD3<Float>(0, 5, 0),
                rotation: SIMD3<Float>(.pi / 2, 0, 0),
                target: SIMD3<Float>(0, 0, 0),
                fieldOfView: 60.0
            )
        }

        /// Creates a new camera configuration with the specified parameters.
        ///
        /// - Parameters:
        ///   - position: The camera's position in world space
        ///   - rotation: The camera's rotation in Euler angles (radians)
        ///   - target: The point the camera is looking at
        ///   - fieldOfView: The vertical field of view in degrees
        public init(position: SIMD3<Float>, rotation: SIMD3<Float>, target: SIMD3<Float>, fieldOfView: Float) {
            self.position = position
            self.rotation = rotation
            self.target = target
            self.fieldOfView = fieldOfView
        }
    }

    private let defaultConfiguration: Configuration

    // MARK: - Initialization

    /// Initializes a new camera controller with default configuration.
    ///
    /// Creates a camera positioned at `(0, 0, 5)` looking at the origin with a 60° field of view.
    /// This default configuration provides a neutral front view suitable for most volumetric
    /// rendering scenarios.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let controller = VolumeCameraController()
    /// // Camera is at (0, 0, 5) looking at (0, 0, 0)
    /// ```
    public init() {
        let config = Configuration.default
        self._position = config.position
        self._rotation = config.rotation
        self._target = config.target
        self._fieldOfView = config.fieldOfView
        self.defaultConfiguration = config
    }

    /// Initializes a new camera controller with a custom configuration.
    ///
    /// Use this initializer to set up a camera with specific position, rotation,
    /// target, and field of view parameters. The provided configuration also
    /// becomes the default for the ``reset()`` method.
    ///
    /// - Parameter configuration: The initial camera configuration that also serves
    ///                           as the reset target
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let customConfig = VolumeCameraController.Configuration(
    ///     position: SIMD3<Float>(2, 2, 2),
    ///     rotation: SIMD3<Float>(0.5, 0.5, 0),
    ///     target: SIMD3<Float>(0, 0, 0),
    ///     fieldOfView: 45.0
    /// )
    /// let controller = VolumeCameraController(configuration: customConfig)
    /// ```
    public init(configuration: Configuration) {
        self._position = configuration.position
        self._rotation = configuration.rotation
        self._target = configuration.target
        self._fieldOfView = configuration.fieldOfView
        self.defaultConfiguration = configuration
    }

    // MARK: - Camera Pose Integration

    /// The complete camera pose representation including position, target, up vector, and field of view.
    ///
    /// This computed property returns a ``CameraPose`` instance that encapsulates the current
    /// camera state. The pose can be used for rendering, serialization, or interchange with
    /// other camera systems. The up vector is always `(0, 1, 0)` (Y-up orientation).
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let controller = VolumeCameraController()
    /// let pose = controller.cameraPose
    ///
    /// // Use pose for rendering or serialization
    /// let viewMatrix = pose.toViewMatrix()
    /// let projectionMatrix = pose.toProjectionMatrix(aspectRatio: 16.0/9.0)
    /// ```
    ///
    /// - SeeAlso: ``CameraPose``
    /// - SeeAlso: ``apply(pose:)``
    public var cameraPose: CameraPose {
        CameraPose(
            position: _position,
            target: _target,
            up: SIMD3<Float>(0, 1, 0), // Standard up vector
            fieldOfView: _fieldOfView
        )
    }

    /// Applies a camera pose to this controller, updating position, target, rotation, and field of view.
    ///
    /// This method updates the controller's internal state to match the provided pose.
    /// The rotation is calculated from the pose's direction vector when valid, avoiding
    /// numerical issues (NaN) when position and target are identical.
    ///
    /// - Parameter pose: The camera pose to apply. Must have distinct position and target
    ///                  to calculate a valid rotation.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let controller = VolumeCameraController()
    /// let savedPose = CameraPose.frontView(distance: 3.0)
    /// controller.apply(pose: savedPose)
    /// ```
    ///
    /// - SeeAlso: ``cameraPose``
    /// - SeeAlso: ``CameraPose``
    public func apply(pose: CameraPose) {
        _position = pose.position
        _target = pose.target
        _fieldOfView = pose.fieldOfView

        // Calculate rotation from pose direction when it's valid to avoid NaNs
        let offset = pose.target - pose.position
        if simd_length_squared(offset) > Float.leastNonzeroMagnitude {
            let direction = simd_normalize(offset)
            _rotation = rotationFromDirection(direction)
        }
    }

    // MARK: - VolumeCameraControlling Protocol

    /// Orbits the camera around the target point by rotating in spherical coordinates.
    ///
    /// This method rotates the camera around the target (focal) point while maintaining
    /// the distance. The rotation is performed in spherical coordinates:
    /// - `delta.x` controls horizontal rotation (yaw)
    /// - `delta.y` controls vertical rotation (pitch)
    ///
    /// Vertical rotation is clamped to prevent gimbal lock, limiting pitch to approximately
    /// ±89° from the horizontal plane.
    ///
    /// - Parameter delta: Horizontal (X) and vertical (Y) orbit angles in radians.
    ///                   Positive X rotates right, positive Y rotates up.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let controller = VolumeCameraController()
    ///
    /// // Orbit 30 degrees right and 15 degrees up
    /// controller.orbit(by: SIMD2<Float>(0.524, 0.262))
    ///
    /// // Orbit from drag gesture delta
    /// let dragDelta = SIMD2<Float>(gesture.translation.x, gesture.translation.y)
    /// let orbitDelta = dragDelta * 0.01 // Scale down to radians
    /// controller.orbit(by: orbitDelta)
    /// ```
    ///
    /// - SeeAlso: ``VolumeCameraControlling/orbit(by:)``
    public func orbit(by delta: SIMD2<Float>) {
        // Update rotation
        _rotation.x += delta.y  // Vertical orbit (pitch)
        _rotation.y += delta.x  // Horizontal orbit (yaw)

        // Clamp vertical rotation to prevent gimbal lock
        _rotation.x = max(-.pi / 2 + 0.01, min(.pi / 2 - 0.01, _rotation.x))

        // Update position based on rotation around target
        updatePositionFromRotation()
    }

    /// Pans the camera by translating both position and target perpendicular to the view direction.
    ///
    /// This method moves the camera in the view plane (perpendicular to the forward vector)
    /// without changing the viewing direction. Both the camera position and target move by
    /// the same amount, maintaining the current orientation.
    ///
    /// - `delta.x` controls horizontal panning (right vector)
    /// - `delta.y` controls vertical panning (up vector)
    ///
    /// - Parameter delta: Horizontal (X) and vertical (Y) translation distances in world units.
    ///                   Positive X moves right, positive Y moves up.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let controller = VolumeCameraController()
    ///
    /// // Pan 2 units right and 1 unit up
    /// controller.pan(by: SIMD2<Float>(2.0, 1.0))
    ///
    /// // Pan from drag gesture
    /// let dragDelta = SIMD2<Float>(gesture.translation.x, gesture.translation.y)
    /// let panDelta = dragDelta * 0.01 // Scale to world units
    /// controller.pan(by: panDelta)
    /// ```
    ///
    /// - SeeAlso: ``VolumeCameraControlling/pan(by:)``
    public func pan(by delta: SIMD2<Float>) {
        let right = rightVector()
        let up = upVector()

        let panAmount = right * delta.x + up * delta.y

        _position += panAmount
        _target += panAmount
    }

    /// Zooms the camera by moving it toward or away from the target point.
    ///
    /// This method adjusts the distance between the camera and its target while maintaining
    /// the viewing direction. The zoom is clamped to a range of 0.1 to 100.0 units to prevent
    /// extreme values.
    ///
    /// - `factor > 1.0`: Zooms in (camera moves closer to target)
    /// - `factor < 1.0`: Zooms out (camera moves away from target)
    /// - `factor = 1.0`: No change
    ///
    /// - Parameter factor: The zoom factor. Values greater than 1 zoom in, less than 1 zoom out.
    ///                    Must be positive, finite, and non-zero.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let controller = VolumeCameraController()
    ///
    /// // Zoom in by 20%
    /// controller.zoom(by: 1.2)
    ///
    /// // Zoom out by 20%
    /// controller.zoom(by: 0.8)
    ///
    /// // Zoom from pinch gesture
    /// let zoomFactor = Float(gesture.scale)
    /// controller.zoom(by: zoomFactor)
    /// ```
    ///
    /// - SeeAlso: ``VolumeCameraControlling/zoom(by:)``
    public func zoom(by factor: Float) {
        guard factor.isFinite, factor != 0 else { return }
        let direction = _target - _position
        let distanceSquared = simd_length_squared(direction)
        guard distanceSquared > Float.leastNonzeroMagnitude else { return }

        let currentDistance = sqrt(distanceSquared)
        let safeFactor = max(0.01, abs(factor))
        let newDistance = currentDistance / safeFactor

        // Clamp zoom to reasonable limits
        let clampedDistance = max(0.1, min(100.0, newDistance))
        let normalizedDirection = simd_normalize(direction)

        _position = _target - normalizedDirection * clampedDistance
    }

    // MARK: - Reset and Configuration

    /// Resets the camera to its initial default configuration.
    ///
    /// This method restores the camera to the configuration that was provided during
    /// initialization. If initialized with ``init()``, this will be the standard default
    /// front view. If initialized with ``init(configuration:)``, this will be the custom
    /// configuration that was provided.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let controller = VolumeCameraController()
    ///
    /// // Apply various transformations
    /// controller.orbit(by: SIMD2<Float>(1.0, 0.5))
    /// controller.zoom(by: 2.0)
    ///
    /// // Reset to original state
    /// controller.reset()
    /// // Camera is back at (0, 0, 5) looking at (0, 0, 0)
    /// ```
    ///
    /// - SeeAlso: ``apply(configuration:)``
    public func reset() {
        _position = defaultConfiguration.position
        _rotation = defaultConfiguration.rotation
        _target = defaultConfiguration.target
        _fieldOfView = defaultConfiguration.fieldOfView
    }

    /// Applies a preset configuration to the camera, updating all parameters.
    ///
    /// This method immediately updates the camera's position, rotation, target, and
    /// field of view to match the provided configuration. Unlike initialization,
    /// this does not change the default configuration used by ``reset()``.
    ///
    /// - Parameter configuration: The configuration to apply. Can be a preset like
    ///                           ``Configuration/frontView``, ``Configuration/sideView``,
    ///                           or ``Configuration/topView``, or a custom configuration.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let controller = VolumeCameraController()
    ///
    /// // Switch to side view
    /// controller.apply(configuration: .sideView)
    ///
    /// // Or use a custom configuration
    /// let customConfig = VolumeCameraController.Configuration(
    ///     position: SIMD3<Float>(3, 3, 3),
    ///     rotation: SIMD3<Float>(0.5, 0.5, 0),
    ///     target: SIMD3<Float>(0, 0, 0),
    ///     fieldOfView: 70.0
    /// )
    /// controller.apply(configuration: customConfig)
    /// ```
    ///
    /// - SeeAlso: ``reset()``
    /// - SeeAlso: ``Configuration``
    public func apply(configuration: Configuration) {
        _position = configuration.position
        _rotation = configuration.rotation
        _target = configuration.target
        _fieldOfView = configuration.fieldOfView
    }

    // MARK: - Helper Methods

    /// Updates the camera position based on current rotation angles around the target point.
    ///
    /// This method converts spherical coordinates (rotation angles) to Cartesian coordinates
    /// while maintaining the current distance from the target. Used internally by ``orbit(by:)``
    /// to reposition the camera after rotation changes.
    private func updatePositionFromRotation() {
        let distance = simd_distance(_position, _target)

        // Calculate new position based on rotation
        let x = cos(_rotation.x) * sin(_rotation.y)
        let y = sin(_rotation.x)
        let z = cos(_rotation.x) * cos(_rotation.y)

        let direction = SIMD3<Float>(x, y, z)
        _position = _target - direction * distance
    }

    /// Calculates Euler rotation angles from a normalized direction vector.
    ///
    /// Converts a direction vector to pitch and yaw angles. Roll is always zero.
    /// Used internally by ``apply(pose:)`` to update rotation state from pose direction.
    ///
    /// - Parameter direction: A normalized direction vector
    /// - Returns: Euler angles `(pitch, yaw, 0)` in radians
    private func rotationFromDirection(_ direction: SIMD3<Float>) -> SIMD3<Float> {
        let pitch = asin(direction.y)
        let yaw = atan2(direction.x, direction.z)
        return SIMD3<Float>(pitch, yaw, 0)
    }

    /// Calculates the normalized forward vector (camera to target direction).
    ///
    /// - Returns: A normalized vector pointing from camera position to target
    private func forwardVector() -> SIMD3<Float> {
        simd_normalize(_target - _position)
    }

    /// Calculates the normalized right vector (perpendicular to forward and world up).
    ///
    /// This vector points to the camera's right side in the view plane.
    ///
    /// - Returns: A normalized vector pointing right relative to the camera
    private func rightVector() -> SIMD3<Float> {
        let forward = forwardVector()
        let up = SIMD3<Float>(0, 1, 0)
        return simd_normalize(simd_cross(forward, up))
    }

    /// Calculates the normalized up vector (perpendicular to right and forward).
    ///
    /// This vector points upward in the camera's view plane.
    ///
    /// - Returns: A normalized vector pointing up relative to the camera
    private func upVector() -> SIMD3<Float> {
        let forward = forwardVector()
        let right = rightVector()
        return simd_normalize(simd_cross(right, forward))
    }
}

// MARK: - VolumetricCameraPoseProviding Conformance

/// Conforms to `VolumetricCameraPoseProviding` protocol.
///
/// This conformance is satisfied by the ``cameraPose`` computed property, which provides
/// the complete camera pose including position, target, up vector, and field of view.
extension VolumeCameraController: VolumetricCameraPoseProviding {
    // Already implemented via cameraPose computed property
}

// MARK: - Preset Configurations

/// Convenience factory methods for creating camera controllers with preset configurations.
extension VolumeCameraController {
    /// Creates a camera controller with front view configuration.
    ///
    /// The camera is positioned at `(0, 0, 5)` looking at the origin with a 60° field of view.
    /// This is the standard front view of a volumetric dataset.
    ///
    /// - Returns: A new camera controller configured for front view
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let frontCamera = VolumeCameraController.withFrontView()
    /// // Camera at (0, 0, 5) looking at (0, 0, 0)
    /// ```
    ///
    /// - SeeAlso: ``Configuration/frontView``
    public static func withFrontView() -> VolumeCameraController {
        VolumeCameraController(configuration: .frontView)
    }

    /// Creates a camera controller with side view configuration.
    ///
    /// The camera is positioned at `(5, 0, 0)` looking at the origin with a 60° field of view.
    /// This provides a sagittal view of a medical volumetric dataset.
    ///
    /// - Returns: A new camera controller configured for side view
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let sideCamera = VolumeCameraController.withSideView()
    /// // Camera at (5, 0, 0) looking at (0, 0, 0)
    /// ```
    ///
    /// - SeeAlso: ``Configuration/sideView``
    public static func withSideView() -> VolumeCameraController {
        VolumeCameraController(configuration: .sideView)
    }

    /// Creates a camera controller with top view configuration.
    ///
    /// The camera is positioned at `(0, 5, 0)` looking down at the origin with a 60° field of view.
    /// This provides an axial (top-down) view of a medical volumetric dataset.
    ///
    /// - Returns: A new camera controller configured for top view
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let topCamera = VolumeCameraController.withTopView()
    /// // Camera at (0, 5, 0) looking at (0, 0, 0)
    /// ```
    ///
    /// - SeeAlso: ``Configuration/topView``
    public static func withTopView() -> VolumeCameraController {
        VolumeCameraController(configuration: .topView)
    }
}
