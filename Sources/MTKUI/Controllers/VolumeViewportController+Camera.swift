//
//  VolumeViewportController+Camera.swift
//  MTKUI
//
//  Camera and geometry helpers for VolumeViewportController.
//

import Foundation
import MTKCore
import simd

extension VolumeViewportController {
    /// Updates internal volume metrics and camera distance limits using the provided dataset.
    /// 
    /// Sets the volume world center, computes a normalized per-axis scale from `dataset.scale` (falling back to `(1, 1, 1)` if the maximum axis scale is near zero), and updates the computed bounding radius. If a `geometry` is available, updates `patientLongitudinalAxis` by safely normalizing `geometry.iopNorm` (preserving the existing axis on failure). Recomputes `cameraDistanceLimits` from the resulting bounding radius.
    /// - Parameter dataset: Source volume metadata (dimensions, spacing/orientation) used to derive scale and bounds.
    func updateVolumeBounds(for dataset: VolumeDataset) {
        volumeWorldCenter = SIMD3<Float>(repeating: 0.5)
        let scale = SIMD3<Float>(
            Float(dataset.scale.x),
            Float(dataset.scale.y),
            Float(dataset.scale.z)
        )
        let maxScale = max(scale.x, max(scale.y, scale.z))
        let normalizedScale = maxScale > Float.ulpOfOne ? scale / maxScale : SIMD3<Float>(repeating: 1)
        volumeBoundingRadius = max(0.5 * simd_length(normalizedScale), 1e-3)
        if let geometry {
            patientLongitudinalAxis = safeNormalize(geometry.iopNorm, fallback: patientLongitudinalAxis)
        }
        cameraDistanceLimits = makeCameraDistanceLimits(radius: volumeBoundingRadius)
    }

    /// Create a DICOMGeometry populated from the provided volume dataset.
    /// - Parameter dataset: The volume dataset whose dimensions, voxel spacing, and orientation will be used.
    /// - Returns: A `DICOMGeometry` initialized with the dataset's cols, rows, slices, spacing (X/Y/Z) and orientation vectors (`iopRow`, `iopCol`, `ipp0`).
    func makeGeometry(from dataset: VolumeDataset) -> DICOMGeometry {
        DICOMGeometry(
            cols: Int32(dataset.dimensions.width),
            rows: Int32(dataset.dimensions.height),
            slices: Int32(dataset.dimensions.depth),
            spacingX: Float(dataset.spacing.x),
            spacingY: Float(dataset.spacing.y),
            spacingZ: Float(dataset.spacing.z),
            iopRow: dataset.orientation.row,
            iopCol: dataset.orientation.column,
            ipp0: dataset.orientation.origin
        )
    }

    /// Resets the camera to a default state centered on the volume using the provided orientation.
    /// - Parameters:
    ///   - radius: The volume bounding radius in world units; used to compute the initial camera distance and distance limits.
    ///   - normal: The desired camera forward/view direction; will be normalized and, if near-zero, replaced with (0, 0, 1).
    ///   - up: The desired camera up direction; will be normalized and, if near-zero, replaced with (0, 1, 0).
    func resetCameraState(radius: Float,
                          normal: SIMD3<Float>,
                          up: SIMD3<Float>) {
        let safeNormal = safeNormalize(normal, fallback: SIMD3<Float>(0, 0, 1))
        let safeUp = safeNormalize(up, fallback: SIMD3<Float>(0, 1, 0))
        let distance = max(radius * defaultCameraDistanceFactor, radius * 1.25, 1.5)
        cameraTarget = volumeWorldCenter
        cameraOffset = safeNormal * distance
        cameraUpVector = safeUp
        fallbackWorldUp = safeUp
        fallbackCameraTarget = volumeWorldCenter
        initialCameraTarget = cameraTarget
        initialCameraOffset = cameraOffset
        initialCameraUp = cameraUpVector
        cameraDistanceLimits = makeCameraDistanceLimits(radius: radius)
        publishCameraState()
    }

    /// Records the controller's current camera state with the state publisher.
    /// 
    /// The recorded state includes the camera position (computed as `cameraTarget + cameraOffset`), the camera target (`cameraTarget`), and the up vector (`cameraUpVector`).
    func publishCameraState() {
        statePublisher.recordCameraState(position: cameraTarget + cameraOffset,
                                         target: cameraTarget,
                                         up: cameraUpVector)
    }

    /// Compute allowable camera distance limits from a volume radius.
    /// - Parameters:
    ///   - radius: The volume bounding radius used to derive distance limits.
    /// - Returns: A closed range where the lower bound is max(radius * 0.25, 0.1) and the upper bound is max(radius * 12, lowerBound + 0.5).
    func makeCameraDistanceLimits(radius: Float) -> ClosedRange<Float> {
        let minimum = max(radius * 0.25, 0.1)
        let maximum = max(radius * 12, minimum + 0.5)
        return minimum...maximum
    }

    /// Constrains a camera offset vector to the current distance limits while preserving its direction.
    /// - Parameters:
    ///   - offset: The vector from the camera target to the camera position.
    /// - Returns: The offset vector scaled to have a magnitude within `cameraDistanceLimits`. If `offset` has negligible length, returns a default offset along +Z with magnitude `max(cameraDistanceLimits.lowerBound, 0.1)`.
    func clampCameraOffset(_ offset: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(offset)
        guard length > Float.ulpOfOne else {
            return SIMD3<Float>(0, 0, max(cameraDistanceLimits.lowerBound, 0.1))
        }
        let clamped = max(cameraDistanceLimits.lowerBound, min(length, cameraDistanceLimits.upperBound))
        return offset / length * clamped
    }

    /// Constrains a desired camera target to lie within the allowed pan distance from the volume center.
    /// - Parameters:
    ///   - target: Desired camera target position in world coordinates.
    /// - Returns: A camera target position clamped to the sphere centered at `volumeWorldCenter` with radius `max(volumeBoundingRadius * maximumPanDistanceMultiplier, 1)`. If `target` is within that limit, it is returned unchanged; if `target` is effectively at the volume center, `volumeWorldCenter` is returned.
    func clampCameraTarget(_ target: SIMD3<Float>) -> SIMD3<Float> {
        let offset = target - volumeWorldCenter
        let limit = max(volumeBoundingRadius * maximumPanDistanceMultiplier, 1)
        let distance = simd_length(offset)
        guard distance > limit else { return target }
        guard distance > Float.ulpOfOne else { return volumeWorldCenter }
        return volumeWorldCenter + offset / distance * limit
    }

    /// Computes the world-space size of a single screen pixel at a given camera distance.
    /// - Parameter distance: Distance from the camera to the target point in world units.
    /// - Returns: A tuple containing `horizontal` and `vertical` world-unit sizes per screen pixel; falls back to (0.002, 0.002) if the computed scales are non-finite or not positive.
    func screenSpaceScale(distance: Float) -> (horizontal: Float, vertical: Float) {
        let bounds = viewportSurface.view.bounds
        let width = max(Float(bounds.width), 1)
        let height = max(Float(bounds.height), 1)
        let fovRadians = Float.pi / 3
        let verticalScale = 2 * distance * tan(fovRadians / 2) / height
        let horizontalScale = verticalScale * (width / height)
        if !verticalScale.isFinite || !horizontalScale.isFinite || verticalScale <= 0 || horizontalScale <= 0 {
            return (0.002, 0.002)
        }
        return (horizontalScale, verticalScale)
    }

    /// Safely normalizes a 3D vector, returning the provided fallback when the vector's length is too small.
    /// - Parameters:
    ///   - vector: The vector to normalize.
    ///   - fallback: The vector to return if `vector` has near-zero length.
    /// - Returns: The normalized `vector`, or `fallback` if the input's length is approximately zero.
    func safeNormalize(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let lengthSquared = simd_length_squared(vector)
        guard lengthSquared > Float.ulpOfOne else { return fallback }
        return vector / sqrt(lengthSquared)
    }

    /// Computes a normalized vector perpendicular to the given vector.
    /// - Parameters:
    ///   - vector: A 3D vector to which the result will be orthogonal.
    /// - Returns: A unit-length vector perpendicular to `vector`. If `vector` is near-zero or the computed perpendicular is numerically unstable, returns the fallback vector `(0, 0, 1)`.
    func safePerpendicular(to vector: SIMD3<Float>) -> SIMD3<Float> {
        let axis = abs(vector.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        return safeNormalize(simd_cross(vector, axis), fallback: SIMD3<Float>(0, 0, 1))
    }
}
