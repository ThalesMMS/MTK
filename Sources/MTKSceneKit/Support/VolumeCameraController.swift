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

    /// Default camera configuration
    public struct Configuration {
        public var position: SIMD3<Float>
        public var rotation: SIMD3<Float>
        public var target: SIMD3<Float>
        public var fieldOfView: Float

        /// Standard default configuration
        public static var `default`: Configuration {
            Configuration(
                position: SIMD3<Float>(0, 0, 5),
                rotation: SIMD3<Float>(0, 0, 0),
                target: SIMD3<Float>(0, 0, 0),
                fieldOfView: 60.0
            )
        }

        /// Front view configuration
        public static var frontView: Configuration {
            Configuration(
                position: SIMD3<Float>(0, 0, 5),
                rotation: SIMD3<Float>(0, 0, 0),
                target: SIMD3<Float>(0, 0, 0),
                fieldOfView: 60.0
            )
        }

        /// Side view configuration
        public static var sideView: Configuration {
            Configuration(
                position: SIMD3<Float>(5, 0, 0),
                rotation: SIMD3<Float>(0, .pi / 2, 0),
                target: SIMD3<Float>(0, 0, 0),
                fieldOfView: 60.0
            )
        }

        /// Top view configuration
        public static var topView: Configuration {
            Configuration(
                position: SIMD3<Float>(0, 5, 0),
                rotation: SIMD3<Float>(.pi / 2, 0, 0),
                target: SIMD3<Float>(0, 0, 0),
                fieldOfView: 60.0
            )
        }

        public init(position: SIMD3<Float>, rotation: SIMD3<Float>, target: SIMD3<Float>, fieldOfView: Float) {
            self.position = position
            self.rotation = rotation
            self.target = target
            self.fieldOfView = fieldOfView
        }
    }

    private let defaultConfiguration: Configuration

    // MARK: - Initialization

    /// Initialize with default configuration
    public init() {
        let config = Configuration.default
        self._position = config.position
        self._rotation = config.rotation
        self._target = config.target
        self._fieldOfView = config.fieldOfView
        self.defaultConfiguration = config
    }

    /// Initialize with custom configuration
    ///
    /// - Parameter configuration: The initial camera configuration
    public init(configuration: Configuration) {
        self._position = configuration.position
        self._rotation = configuration.rotation
        self._target = configuration.target
        self._fieldOfView = configuration.fieldOfView
        self.defaultConfiguration = configuration
    }

    // MARK: - Camera Pose Integration

    /// Get the complete camera pose
    public var cameraPose: CameraPose {
        CameraPose(
            position: _position,
            target: _target,
            up: SIMD3<Float>(0, 1, 0), // Standard up vector
            fieldOfView: _fieldOfView
        )
    }

    /// Apply a camera pose to this controller
    ///
    /// - Parameter pose: The camera pose to apply
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

    /// Orbit the camera around the target point
    ///
    /// - Parameter delta: Horizontal and vertical orbit deltas in radians
    public func orbit(by delta: SIMD2<Float>) {
        // Update rotation
        _rotation.x += delta.y  // Vertical orbit (pitch)
        _rotation.y += delta.x  // Horizontal orbit (yaw)

        // Clamp vertical rotation to prevent gimbal lock
        _rotation.x = max(-.pi / 2 + 0.01, min(.pi / 2 - 0.01, _rotation.x))

        // Update position based on rotation around target
        updatePositionFromRotation()
    }

    /// Pan the camera (translate perpendicular to view direction)
    ///
    /// - Parameter delta: Horizontal and vertical pan deltas
    public func pan(by delta: SIMD2<Float>) {
        let right = rightVector()
        let up = upVector()

        let panAmount = right * delta.x + up * delta.y

        _position += panAmount
        _target += panAmount
    }

    /// Zoom the camera (move toward/away from target)
    ///
    /// - Parameter factor: Zoom factor (>1 = zoom in, <1 = zoom out)
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

    /// Reset camera to default configuration
    public func reset() {
        _position = defaultConfiguration.position
        _rotation = defaultConfiguration.rotation
        _target = defaultConfiguration.target
        _fieldOfView = defaultConfiguration.fieldOfView
    }

    /// Apply a preset configuration
    ///
    /// - Parameter configuration: The configuration to apply
    public func apply(configuration: Configuration) {
        _position = configuration.position
        _rotation = configuration.rotation
        _target = configuration.target
        _fieldOfView = configuration.fieldOfView
    }

    // MARK: - Helper Methods

    private func updatePositionFromRotation() {
        let distance = simd_distance(_position, _target)

        // Calculate new position based on rotation
        let x = cos(_rotation.x) * sin(_rotation.y)
        let y = sin(_rotation.x)
        let z = cos(_rotation.x) * cos(_rotation.y)

        let direction = SIMD3<Float>(x, y, z)
        _position = _target - direction * distance
    }

    private func rotationFromDirection(_ direction: SIMD3<Float>) -> SIMD3<Float> {
        let pitch = asin(direction.y)
        let yaw = atan2(direction.x, direction.z)
        return SIMD3<Float>(pitch, yaw, 0)
    }

    private func forwardVector() -> SIMD3<Float> {
        simd_normalize(_target - _position)
    }

    private func rightVector() -> SIMD3<Float> {
        let forward = forwardVector()
        let up = SIMD3<Float>(0, 1, 0)
        return simd_normalize(simd_cross(forward, up))
    }

    private func upVector() -> SIMD3<Float> {
        let forward = forwardVector()
        let right = rightVector()
        return simd_normalize(simd_cross(right, forward))
    }
}

// MARK: - VolumetricCameraPoseProviding Conformance

extension VolumeCameraController: VolumetricCameraPoseProviding {
    // Already implemented via cameraPose computed property
}

// MARK: - Preset Configurations

extension VolumeCameraController {
    /// Create a camera controller with front view
    public static func withFrontView() -> VolumeCameraController {
        VolumeCameraController(configuration: .frontView)
    }

    /// Create a camera controller with side view
    public static func withSideView() -> VolumeCameraController {
        VolumeCameraController(configuration: .sideView)
    }

    /// Create a camera controller with top view
    public static func withTopView() -> VolumeCameraController {
        VolumeCameraController(configuration: .topView)
    }
}
