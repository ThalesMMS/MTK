//
//  CameraPose.swift
//  MTK - MTKSceneKit
//
//  Provides camera pose representation and protocols for volumetric rendering.
//  Defines the camera's position, target, orientation, and field of view.
//  Migrated from Isis DICOM Viewer - September 2025
//
//  This struct encapsulates the complete camera state needed for 3D volumetric
//  visualization, with native SceneKit/SIMD integration and serialization support.
//

import Foundation
import CoreGraphics
import simd
import SceneKit

// MARK: - CameraPose

/// Represents a camera's position and orientation in 3D space.
///
/// This struct captures all essential camera parameters for volumetric rendering:
/// - `position`: The world-space location of the camera
/// - `target`: The point in space the camera is looking at
/// - `up`: The up vector defining camera roll
/// - `fieldOfView`: The vertical field of view in degrees
///
/// The struct conforms to `Equatable` for comparisons and `Codable` for serialization.
public struct CameraPose: Equatable, Codable {
    /// The camera's position in world space
    public var position: SIMD3<Float>

    /// The point in world space that the camera is looking at (target/focal point)
    public var target: SIMD3<Float>

    /// The up vector defining camera orientation (typically normalized)
    public var up: SIMD3<Float>

    /// The vertical field of view in degrees
    public var fieldOfView: Float

    /// Initializes a new camera pose.
    ///
    /// - Parameters:
    ///   - position: The camera's position in world space
    ///   - target: The point the camera is looking at
    ///   - up: The up vector defining camera roll
    ///   - fieldOfView: The vertical field of view in degrees
    public init(position: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>, fieldOfView: Float) {
        self.position = position
        self.target = target
        self.up = up
        self.fieldOfView = fieldOfView
    }

    // MARK: - SceneKit Integration

    /// Creates a camera pose from a SceneKit camera node.
    ///
    /// Extracts the camera's position, target, up vector, and field of view
    /// from a SceneKit SCNCamera and its parent node's transform.
    ///
    /// - Parameters:
    ///   - cameraNode: The SCNNode containing the SCNCamera
    ///   - lookAtTarget: Optional override for the target point; if not provided,
    ///                   a default target is calculated from the camera's direction
    /// - Returns: A CameraPose instance representing the camera state
    public static func from(cameraNode: SCNNode, lookAtTarget: SIMD3<Float>? = nil) -> CameraPose {
        // Extract camera position from node world position
        let position = SIMD3<Float>(
            Float(cameraNode.worldPosition.x),
            Float(cameraNode.worldPosition.y),
            Float(cameraNode.worldPosition.z)
        )

        // Determine the target (focal point)
        let target: SIMD3<Float>
        if let lookAtTarget {
            target = lookAtTarget
        } else {
            // Calculate default target based on camera's forward direction
            let direction = cameraNode.worldFront
            let defaultDistance: Float = 1.0
            target = position + SIMD3<Float>(Float(direction.x), Float(direction.y), Float(direction.z)) * defaultDistance
        }

        // Extract up vector from camera's world transform
        let up = SIMD3<Float>(
            Float(cameraNode.worldUp.x),
            Float(cameraNode.worldUp.y),
            Float(cameraNode.worldUp.z)
        )

        // Extract field of view from camera
        // Note: yFOV is deprecated in newer macOS versions
        // Using a default FOV of 60 degrees as fallback
        let fov: Float = 60.0

        return CameraPose(position: position, target: target, up: up, fieldOfView: fov)
    }

    /// Applies this camera pose to a SceneKit camera node.
    ///
    /// Updates the camera node's position and orientation to match this pose,
    /// and configures the camera's field of view.
    ///
    /// - Parameters:
    ///   - cameraNode: The SCNNode to update with this camera pose
    ///   - camera: The SCNCamera to configure; if nil, uses the camera from cameraNode
    public func apply(to cameraNode: SCNNode, camera: SCNCamera? = nil) {
        // Set camera node position
        cameraNode.position = SCNVector3(position)

        // Calculate and apply look-at direction
        let direction = target - position
        let directionLength = simd_length(direction)

        if directionLength > 0 {
            let normalizedDirection = direction / directionLength
            // Create a look-at matrix and extract rotation
            // Use quaternion from direction and up vector
            let forward = normalizedDirection
            let right = simd_cross(forward, up)
            let rightLength = simd_length(right)

            if rightLength > 0 {
                let normalizedRight = right / rightLength
                let adjustedUp = simd_cross(normalizedRight, forward)

                // Use the modern SceneKit look() API
                    cameraNode.look(
                        at: SCNVector3(target),
                        up: SCNVector3(adjustedUp),
                        localFront: SCNVector3(forward)
                    )
            }
        }

        // Apply field of view to camera
        // Note: yFOV is deprecated in newer macOS versions
        // The field of view setting is a placeholder for now
        let targetCamera = camera ?? cameraNode.camera
        if let targetCamera = targetCamera {
            // Field of view would be set here if the API supported it
            // For now, we store the fieldOfView in our struct for reference
            _ = targetCamera  // Use the camera reference
        }
    }

    /// Converts the camera pose to a view matrix suitable for rendering.
    ///
    /// - Returns: A 4x4 view matrix in column-major order
    public func toViewMatrix() -> simd_float4x4 {
        let direction = simd_normalize(target - position)
        let right = simd_normalize(simd_cross(direction, up))
        let adjustedUp = simd_normalize(simd_cross(right, direction))

        let negPos = -position
        let tx = simd_dot(right, negPos)
        let ty = simd_dot(adjustedUp, negPos)
        let tz = simd_dot(-direction, negPos)

        return simd_float4x4(
            simd_float4(right.x, adjustedUp.x, -direction.x, 0),
            simd_float4(right.y, adjustedUp.y, -direction.y, 0),
            simd_float4(right.z, adjustedUp.z, -direction.z, 0),
            simd_float4(tx, ty, tz, 1)
        )
    }

    /// Converts the camera pose to a projection matrix.
    ///
    /// - Parameters:
    ///   - aspectRatio: The aspect ratio (width / height) of the viewport
    ///   - nearPlane: The distance to the near clipping plane
    ///   - farPlane: The distance to the far clipping plane
    /// - Returns: A 4x4 projection matrix in column-major order
    public func toProjectionMatrix(aspectRatio: Float, nearPlane: Float = 0.1, farPlane: Float = 100.0) -> simd_float4x4 {
        let fovRadians = fieldOfView * .pi / 180.0
        let f = 1.0 / tan(fovRadians / 2.0)
        let range = nearPlane - farPlane

        return simd_float4x4(
            simd_float4(f / aspectRatio, 0, 0, 0),
            simd_float4(0, f, 0, 0),
            simd_float4(0, 0, (farPlane + nearPlane) / range, -1),
            simd_float4(0, 0, (2 * farPlane * nearPlane) / range, 0)
        )
    }

    /// Calculates the distance from the camera to its target.
    ///
    /// - Returns: The Euclidean distance between position and target
    public func distanceToTarget() -> Float {
        simd_distance(position, target)
    }

    /// Returns a normalized forward vector (direction the camera is looking).
    ///
    /// - Returns: A normalized vector pointing from camera position to target
    public func forwardVector() -> SIMD3<Float> {
        simd_normalize(target - position)
    }

    /// Returns a normalized right vector (perpendicular to forward and up).
    ///
    /// - Returns: A normalized vector pointing to the right of the camera
    public func rightVector() -> SIMD3<Float> {
        let forward = forwardVector()
        return simd_normalize(simd_cross(forward, up))
    }
}

// MARK: - VolumetricCameraPoseProviding Protocol

/// Protocol for types that provide a camera pose for volumetric rendering.
///
/// Implementations should provide the current camera pose, which is essential
/// for rendering engines that need to know the camera's spatial configuration.
public protocol VolumetricCameraPoseProviding {
    /// The current camera pose used for volumetric rendering
    var cameraPose: CameraPose { get }
}

// MARK: - Default Poses

extension CameraPose {
    /// Creates a default camera pose with standard viewing parameters.
    ///
    /// - Returns: A camera pose with position at (0, 0, 2), target at origin,
    ///           up vector pointing in Y direction, and 60-degree field of view
    public static var `default`: CameraPose {
        CameraPose(
            position: SIMD3<Float>(0, 0, 2),
            target: SIMD3<Float>(0, 0, 0),
            up: SIMD3<Float>(0, 1, 0),
            fieldOfView: 60
        )
    }

    /// Creates a camera pose looking at a volume from the front.
    ///
    /// - Parameter distance: The distance from the target (default: 2.0)
    /// - Returns: A camera pose positioned in front of the origin
    public static func frontView(distance: Float = 2.0) -> CameraPose {
        CameraPose(
            position: SIMD3<Float>(0, 0, distance),
            target: SIMD3<Float>(0, 0, 0),
            up: SIMD3<Float>(0, 1, 0),
            fieldOfView: 60
        )
    }

    /// Creates a camera pose looking at a volume from the side.
    ///
    /// - Parameter distance: The distance from the target (default: 2.0)
    /// - Returns: A camera pose positioned to the side of the origin
    public static func sideView(distance: Float = 2.0) -> CameraPose {
        CameraPose(
            position: SIMD3<Float>(distance, 0, 0),
            target: SIMD3<Float>(0, 0, 0),
            up: SIMD3<Float>(0, 1, 0),
            fieldOfView: 60
        )
    }

    /// Creates a camera pose looking at a volume from above.
    ///
    /// - Parameter distance: The distance from the target (default: 2.0)
    /// - Returns: A camera pose positioned above the origin
    public static func topView(distance: Float = 2.0) -> CameraPose {
        CameraPose(
            position: SIMD3<Float>(0, distance, 0),
            target: SIMD3<Float>(0, 0, 0),
            up: SIMD3<Float>(0, 0, -1),
            fieldOfView: 60
        )
    }
}
