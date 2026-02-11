//
//  VolumetricCameraController.swift
//  MetalVolumetrics
//
//  Camera operations for volumetric scene rendering including node setup,
//  transform calculations, clipping plane management, and interactive camera state.
//  Extracted from VolumetricSceneController+Camera for focused responsibility.
//
//  Thales Matheus Mendonça Santos - February 2026
//

import Foundation

#if os(iOS) || os(macOS)
import SceneKit
import simd
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Metal)
import Metal
#endif
import MTKCore
import MTKSceneKit

/// Manages camera configuration, transforms, and interactive state for volumetric rendering.
/// Provides utilities for camera node setup, look-at transforms, clipping plane adjustments,
/// and screen-space scaling calculations.
@MainActor
public final class VolumetricCameraController {

    // MARK: - Properties

    private weak var sceneView: SCNView?
    private weak var rootNode: SCNNode?
    private weak var statePublisher: VolumetricStatePublisher?

    // MARK: - Initialization

    public init(sceneView: SCNView, rootNode: SCNNode, statePublisher: VolumetricStatePublisher) {
        self.sceneView = sceneView
        self.rootNode = rootNode
        self.statePublisher = statePublisher
    }

    // MARK: - Camera Node Management

    /// Ensures a camera node exists in the scene, creating one if necessary.
    /// Returns the existing or newly created camera node.
    @discardableResult
    public func ensureCameraNode(volumeBoundingRadius: Float, cameraOffset: SIMD3<Float>) -> SCNNode {
        guard let sceneView, let rootNode else {
            fatalError("VolumetricCameraController: sceneView or rootNode is nil")
        }

        if let existing = sceneView.pointOfView {
            if existing.parent == nil {
                rootNode.addChildNode(existing)
            }
            sceneView.defaultCameraController.pointOfView = existing
            return existing
        }

        let cameraNode = SCNNode()
        cameraNode.name = "Volumetric.Camera"
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(x: 0, y: 0, z: 2)
        cameraNode.eulerAngles = SCNVector3(x: 0, y: 0, z: 0)
        rootNode.addChildNode(cameraNode)
        sceneView.pointOfView = cameraNode
        sceneView.defaultCameraController.pointOfView = cameraNode
        updateCameraClippingPlanes(cameraNode.camera,
                                   radius: volumeBoundingRadius,
                                   offsetLength: simd_length(cameraOffset))
        return cameraNode
    }

    // MARK: - Camera Configuration

    /// Configures camera position and orientation using DICOM geometry.
    /// Updates camera node transform, fallback state, and interactive camera parameters.
    public func configureCamera(
        using geometry: DICOMGeometry,
        volumeWorldCenter: SIMD3<Float>,
        volumeBoundingRadius: Float,
        defaultCameraDistanceFactor: Float,
        updateState: (_ cameraTarget: SIMD3<Float>,
                      _ cameraOffset: SIMD3<Float>,
                      _ cameraUpVector: SIMD3<Float>,
                      _ fallbackCameraTransform: simd_float4x4,
                      _ initialCameraTransform: simd_float4x4,
                      _ fallbackWorldUp: SIMD3<Float>,
                      _ fallbackCameraTarget: SIMD3<Float>,
                      _ patientLongitudinalAxis: SIMD3<Float>,
                      _ defaultCameraTarget: SCNVector3,
                      _ cameraDistanceLimits: ClosedRange<Float>) -> Void
    ) -> SCNNode {
        guard let sceneView else {
            fatalError("VolumetricCameraController: sceneView is nil")
        }

        let center = volumeWorldCenter
        let normal = safeNormalize(geometry.iopNorm, fallback: SIMD3<Float>(0, 0, 1))
        let up = safeNormalize(geometry.iopCol, fallback: SIMD3<Float>(0, 1, 0))
        let radius = max(volumeBoundingRadius, 1e-3)
        let distance = max(radius * defaultCameraDistanceFactor, radius * 1.25)
        let position = center + normal * distance
        let transform = makeLookAtTransform(position: position, target: center, up: up)

        let cameraNode = ensureCameraNode(volumeBoundingRadius: radius, cameraOffset: position - center)
        cameraNode.simdTransform = transform

        sceneView.defaultCameraController.pointOfView = cameraNode

        let cameraDistanceLimits = makeCameraDistanceLimits(radius: radius)
        let cameraOffset = position - center
        let cameraUpVector = safeNormalize(up, fallback: SIMD3<Float>(0, 1, 0))
        let patientLongitudinalAxis = safeNormalize(normal, fallback: SIMD3<Float>(0, 0, 1))
        let defaultCameraTarget = SCNVector3(x: SCNFloat(center.x),
                                            y: SCNFloat(center.y),
                                            z: SCNFloat(center.z))

        updateState(
            center,
            cameraOffset,
            cameraUpVector,
            transform,
            transform,
            up,
            center,
            patientLongitudinalAxis,
            defaultCameraTarget,
            cameraDistanceLimits
        )

        prepareCameraControllerForExternalGestures(worldUp: up, defaultCameraTarget: defaultCameraTarget)
        updateCameraClippingPlanes(cameraNode.camera,
                                   radius: radius,
                                   offsetLength: simd_length(cameraOffset))

        statePublisher?.recordCameraState(position: position, target: center, up: up)

        return cameraNode
    }

    /// Restores camera to fallback position and orientation.
    public func restoreFallbackCamera(
        fallbackCameraTransform: simd_float4x4?,
        fallbackCameraTarget: SIMD3<Float>,
        fallbackWorldUp: SIMD3<Float>,
        volumeBoundingRadius: Float,
        updateState: (_ cameraTarget: SIMD3<Float>,
                      _ cameraOffset: SIMD3<Float>,
                      _ cameraUpVector: SIMD3<Float>,
                      _ defaultCameraTarget: SCNVector3,
                      _ cameraDistanceLimits: ClosedRange<Float>) -> Void
    ) -> SCNNode {
        guard let sceneView else {
            fatalError("VolumetricCameraController: sceneView is nil")
        }

        let cameraNode = ensureCameraNode(volumeBoundingRadius: volumeBoundingRadius, cameraOffset: SIMD3<Float>(0, 0, 1))
        if let transform = fallbackCameraTransform {
            cameraNode.simdTransform = transform
        }
        sceneView.defaultCameraController.pointOfView = cameraNode
        let radius = max(volumeBoundingRadius, 1e-3)

        let cameraDistanceLimits = makeCameraDistanceLimits(radius: radius)
        let cameraUpVector = safeNormalize(fallbackWorldUp, fallback: SIMD3<Float>(0, 1, 0))
        let cameraOffset = cameraNode.simdWorldPosition - fallbackCameraTarget
        let defaultCameraTarget = SCNVector3(x: SCNFloat(fallbackCameraTarget.x),
                                            y: SCNFloat(fallbackCameraTarget.y),
                                            z: SCNFloat(fallbackCameraTarget.z))

        updateState(
            fallbackCameraTarget,
            cameraOffset,
            cameraUpVector,
            defaultCameraTarget,
            cameraDistanceLimits
        )

        prepareCameraControllerForExternalGestures(worldUp: nil, defaultCameraTarget: defaultCameraTarget)

        statePublisher?.recordCameraState(
            position: fallbackCameraTarget + cameraOffset,
            target: fallbackCameraTarget,
            up: cameraUpVector
        )

        return cameraNode
    }

    // MARK: - Interactive Camera State

    /// Updates interactive camera state including target, offset, and up vector.
    public func updateInteractiveCameraState(
        target: SIMD3<Float>,
        up: SIMD3<Float>,
        cameraNode: SCNNode,
        radius: Float,
        clampTargetFn: (SIMD3<Float>) -> SIMD3<Float>,
        fallbackWorldUp: SIMD3<Float>,
        updateState: (_ cameraTarget: SIMD3<Float>,
                      _ cameraUpVector: SIMD3<Float>,
                      _ cameraOffset: SIMD3<Float>,
                      _ defaultCameraTarget: SCNVector3,
                      _ cameraDistanceLimits: ClosedRange<Float>,
                      _ fallbackWorldUp: SIMD3<Float>) -> Void
    ) {
        let cameraDistanceLimits = makeCameraDistanceLimits(radius: radius)
        let clampedTarget = clampTargetFn(target)
        let cameraUpVector = safeNormalize(up, fallback: fallbackWorldUp)
        var cameraOffset = cameraNode.simdWorldPosition - clampedTarget
        cameraOffset = clampCameraOffset(cameraOffset, distanceLimits: cameraDistanceLimits)
        let defaultCameraTarget = SCNVector3(x: SCNFloat(clampedTarget.x),
                                            y: SCNFloat(clampedTarget.y),
                                            z: SCNFloat(clampedTarget.z))

        updateState(
            clampedTarget,
            cameraUpVector,
            cameraOffset,
            defaultCameraTarget,
            cameraDistanceLimits,
            cameraUpVector
        )

        updateCameraControllerTargets(cameraTarget: clampedTarget, cameraUpVector: cameraUpVector)
        updateCameraClippingPlanes(cameraNode.camera,
                                   radius: radius,
                                   offsetLength: simd_length(cameraOffset))
        statePublisher?.recordCameraState(position: clampedTarget + cameraOffset,
                                         target: clampedTarget,
                                         up: cameraUpVector)
    }

    /// Applies interactive camera transform based on current target, offset, and up vector.
    public func applyInteractiveCameraTransform(
        _ cameraNode: SCNNode,
        cameraTarget: SIMD3<Float>,
        cameraOffset: SIMD3<Float>,
        cameraUpVector: SIMD3<Float>,
        volumeBoundingRadius: Float,
        fallbackWorldUp: SIMD3<Float>,
        clampTargetFn: (SIMD3<Float>) -> SIMD3<Float>,
        clampOffsetFn: (SIMD3<Float>) -> SIMD3<Float>,
        updateState: (_ cameraTarget: SIMD3<Float>,
                      _ cameraUpVector: SIMD3<Float>,
                      _ cameraOffset: SIMD3<Float>,
                      _ defaultCameraTarget: SCNVector3) -> Void,
        updateRayCastingCache: (() -> Void)?
    ) {
        let clampedTarget = clampTargetFn(cameraTarget)
        let clampedOffset = clampOffsetFn(cameraOffset)
        let position = clampedTarget + clampedOffset
        let forward = safeNormalize(clampedTarget - position, fallback: SIMD3<Float>(0, 0, -1))
        var up = safeNormalize(cameraUpVector, fallback: fallbackWorldUp)
        if abs(simd_dot(forward, up)) > 0.999 {
            up = safePerpendicular(to: forward)
        }
        let right = safeNormalize(simd_cross(forward, up), fallback: safePerpendicular(to: forward))
        up = safeNormalize(simd_cross(right, forward), fallback: up)

        var transform = matrix_identity_float4x4
        transform.columns.0 = SIMD4<Float>(right.x, right.y, right.z, 0)
        transform.columns.1 = SIMD4<Float>(up.x, up.y, up.z, 0)
        transform.columns.2 = SIMD4<Float>(-forward.x, -forward.y, -forward.z, 0)
        transform.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        cameraNode.simdTransform = transform

        let defaultCameraTarget = SCNVector3(x: SCNFloat(clampedTarget.x),
                                            y: SCNFloat(clampedTarget.y),
                                            z: SCNFloat(clampedTarget.z))

        updateState(clampedTarget, up, clampedOffset, defaultCameraTarget)

        updateCameraControllerTargets(cameraTarget: clampedTarget, cameraUpVector: up)
        updateCameraClippingPlanes(cameraNode.camera,
                                   radius: volumeBoundingRadius,
                                   offsetLength: simd_length(clampedOffset))

        updateRayCastingCache?()

        statePublisher?.recordCameraState(position: position, target: clampedTarget, up: up)
    }

    // MARK: - Camera Distance and Offset

    /// Clamps camera offset to valid distance range.
    /// Ensures camera stays within min/max distance from target while preserving direction.
    /// Falls back to default offset if length is degenerate.
    public func clampCameraOffset(_ offset: SIMD3<Float>, distanceLimits: ClosedRange<Float>) -> SIMD3<Float> {
        let length = simd_length(offset)
        guard length > Float.ulpOfOne else {
            let fallbackDistance = max(distanceLimits.lowerBound, 0.1)
            return SIMD3<Float>(0, 0, fallbackDistance)
        }
        let clamped = max(distanceLimits.lowerBound, min(length, distanceLimits.upperBound))
        let normalized = offset / length
        return normalized * clamped
    }

    /// Creates camera distance limits based on volume bounding radius.
    public func makeCameraDistanceLimits(radius: Float) -> ClosedRange<Float> {
        let minimum = max(radius * 0.25, 0.1)
        let maximum = max(radius * 12, minimum + 0.5)
        return minimum...maximum
    }

    // MARK: - Camera Controller Updates

    /// Updates SceneKit camera controller targets for interactive manipulation.
    public func updateCameraControllerTargets(cameraTarget: SIMD3<Float>, cameraUpVector: SIMD3<Float>) {
        guard let sceneView else { return }
        let controller = sceneView.defaultCameraController
        guard controller.pointOfView != nil else { return }
        controller.target = SCNVector3(x: SCNFloat(cameraTarget.x),
                                       y: SCNFloat(cameraTarget.y),
                                       z: SCNFloat(cameraTarget.z))
        controller.worldUp = SCNVector3(x: SCNFloat(cameraUpVector.x),
                                        y: SCNFloat(cameraUpVector.y),
                                        z: SCNFloat(cameraUpVector.z))
    }

    /// Prepares camera controller for external gesture handling.
    public func prepareCameraControllerForExternalGestures(
        worldUp: SIMD3<Float>?,
        defaultCameraTarget: SCNVector3
    ) {
        guard let sceneView else { return }
        sceneView.allowsCameraControl = false
        let cameraNode = ensureCameraNode(volumeBoundingRadius: 1.0, cameraOffset: SIMD3<Float>(0, 0, 1))
        let controller = sceneView.defaultCameraController
        controller.inertiaEnabled = false
        if controller.pointOfView !== cameraNode {
            controller.pointOfView = cameraNode
        }
        controller.target = defaultCameraTarget
        let resolvedWorldUp = worldUp ?? SIMD3<Float>(0, 1, 0)
        controller.worldUp = SCNVector3(x: SCNFloat(resolvedWorldUp.x),
                                        y: SCNFloat(resolvedWorldUp.y),
                                        z: SCNFloat(resolvedWorldUp.z))
        controller.clearRoll()
    }

    // MARK: - Clipping Planes

    /// Updates camera near and far clipping planes based on volume bounds.
    /// Dynamically adjusts planes to ensure the volume is fully visible while
    /// preventing Z-fighting and excessive depth buffer precision loss.
    public func updateCameraClippingPlanes(_ camera: SCNCamera?, radius: Float, offsetLength: Float) {
        guard let camera else { return }

        let safeRadius = max(radius, 1e-3)
        let safeDistance = max(offsetLength, 1e-3)
        let margin = max(safeRadius * 0.05, 0.01)

        // Adjust near plane based on camera distance relative to volume
        let near: Float
        if safeDistance <= safeRadius {
            // Camera is inside or very close to volume
            near = max(0.01, safeDistance * 0.1)
        } else {
            // Camera is outside volume - place near plane before volume surface
            near = max(0.01, safeDistance - safeRadius - margin)
        }

        // Far plane must encompass the entire volume
        let far = max(near + margin, safeDistance + safeRadius + margin)

        camera.zNear = Double(near)
        camera.zFar = Double(far)
    }

    // MARK: - Screen Space Calculations

    /// Calculates screen space scale factors for distance-based UI elements.
    public func screenSpaceScale(distance: Float, cameraNode: SCNNode) -> (horizontal: Float, vertical: Float) {
        guard let sceneView else {
            return (0.002, 0.002)
        }

        let bounds = sceneView.bounds
        let width = max(Float(bounds.width), 1)
        let height = max(Float(bounds.height), 1)
        let fallback: Float = 0.002
        guard height > Float.ulpOfOne else { return (fallback, fallback) }

        let fovDegrees = Float(cameraNode.camera?.fieldOfView ?? 60)
        let clampedFov = max(min(fovDegrees, 179), 1)
        let radians = clampedFov * Float.pi / 180
        let tangent = tan(Double(radians) / 2)
        let verticalScale = 2 * distance * Float(tangent) / height
        let aspect = width / height
        let horizontalScale = verticalScale * aspect

        if !verticalScale.isFinite || !horizontalScale.isFinite || verticalScale <= 0 || horizontalScale <= 0 {
            return (fallback, fallback)
        }
        return (horizontalScale, verticalScale)
    }

    // MARK: - Transform Utilities

    /// Creates a look-at transform matrix from position, target, and up vector.
    public func makeLookAtTransform(position: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let forward = safeNormalize(target - position, fallback: SIMD3<Float>(0, 0, -1))
        var right = simd_cross(up, forward)
        right = safeNormalize(right, fallback: safePerpendicular(to: forward))
        let correctedUp = safeNormalize(simd_cross(forward, right), fallback: SIMD3<Float>(0, 1, 0))
        let rotation = simd_float3x3(columns: (right, correctedUp, -forward))
        var transform = matrix_identity_float4x4
        transform.columns.0 = SIMD4<Float>(rotation.columns.0.x, rotation.columns.0.y, rotation.columns.0.z, 0)
        transform.columns.1 = SIMD4<Float>(rotation.columns.1.x, rotation.columns.1.y, rotation.columns.1.z, 0)
        transform.columns.2 = SIMD4<Float>(rotation.columns.2.x, rotation.columns.2.y, rotation.columns.2.z, 0)
        transform.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        return transform
    }

    // MARK: - Vector Utilities

    /// Safely normalizes a vector, returning fallback if length is too small.
    public func safeNormalize(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let lengthSquared = simd_length_squared(vector)
        guard lengthSquared > Float.ulpOfOne else { return fallback }
        return vector / sqrt(lengthSquared)
    }

    /// Finds a safe perpendicular vector to the given vector.
    public func safePerpendicular(to vector: SIMD3<Float>) -> SIMD3<Float> {
        let axis = abs(vector.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        let perpendicular = simd_cross(vector, axis)
        return safeNormalize(perpendicular, fallback: SIMD3<Float>(0, 0, 1))
    }
}

#endif
