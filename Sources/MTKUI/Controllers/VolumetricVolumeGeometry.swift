//
//  VolumetricVolumeGeometry.swift
//  MetalVolumetrics
//
//  Volume geometry calculations including bounds, patient basis, and coordinate transformations.
//  Extracted from VolumetricSceneController+Camera for focused responsibility.
//
//  Thales Matheus Mendonça Santos - February 2026
//

import Foundation

#if os(iOS) || os(macOS)
import SceneKit
import simd
import MTKCore
import MTKSceneKit

/// Manages volume geometry calculations for volumetric rendering.
/// Provides utilities for computing volume bounds, patient coordinate systems,
/// and DICOM geometry transformations.
@MainActor
public final class VolumetricVolumeGeometry {

    // MARK: - Properties

    private weak var volumeNode: SCNNode?
    private weak var volumeMaterial: VolumeCubeMaterial?

    // MARK: - Initialization

    public init(volumeNode: SCNNode, volumeMaterial: VolumeCubeMaterial) {
        self.volumeNode = volumeNode
        self.volumeMaterial = volumeMaterial
    }

    // MARK: - Volume Bounds

    /// Updates volume world center and bounding radius based on current node transform.
    /// Uses multiple fallback strategies to ensure robust bounds calculation:
    /// 1. Transform diagonal length (fastest)
    /// 2. Bounding box corner projection (most accurate)
    /// 3. Scaled bounding sphere (fallback)
    /// 4. Material scale diagonal (last resort)
    public func updateVolumeBounds(
        patientLongitudinalAxis: SIMD3<Float>,
        updateState: (_ volumeWorldCenter: SIMD3<Float>,
                      _ volumeBoundingRadius: Float,
                      _ patientLongitudinalAxis: SIMD3<Float>) -> Void
    ) {
        guard let node = volumeNode else { return }
        let worldTransform = node.simdWorldTransform

        // Step 1: Compute world center from bounding sphere
        let sphere = node.boundingSphere
        let localCenter = SIMD4<Float>(Float(sphere.center.x),
                                       Float(sphere.center.y),
                                       Float(sphere.center.z),
                                       1)
        var worldCenter = worldTransform * localCenter
        if !worldCenter.x.isFinite || !worldCenter.y.isFinite || !worldCenter.z.isFinite {
            worldCenter = worldTransform * SIMD4<Float>(0, 0, 0, 1)
        }
        let volumeWorldCenter = SIMD3<Float>(worldCenter.x, worldCenter.y, worldCenter.z)

        // Step 2: Extract transform axes and update patient longitudinal axis
        let axisX = SIMD3<Float>(worldTransform.columns.0.x,
                                 worldTransform.columns.0.y,
                                 worldTransform.columns.0.z)
        let axisY = SIMD3<Float>(worldTransform.columns.1.x,
                                 worldTransform.columns.1.y,
                                 worldTransform.columns.1.z)
        let axisZ = SIMD3<Float>(worldTransform.columns.2.x,
                                 worldTransform.columns.2.y,
                                 worldTransform.columns.2.z)
        let updatedPatientLongitudinalAxis = safeNormalize(axisZ, fallback: patientLongitudinalAxis)

        let lengthX = simd_length(axisX)
        let lengthY = simd_length(axisY)
        let lengthZ = simd_length(axisZ)

        // Strategy 1: Use transform diagonal length (fast approximation)
        let diagonalSquared = lengthX * lengthX + lengthY * lengthY + lengthZ * lengthZ
        var radius: Float = 0
        if diagonalSquared > Float.ulpOfOne {
            radius = 0.5 * sqrt(diagonalSquared)
        }

        // Strategy 2: Project bounding box corners if diagonal approach fails
        if radius <= Float.ulpOfOne {
            let boundingBox = node.boundingBox
            let localMin = boundingBox.min
            let localMax = boundingBox.max

            if localMin.x <= localMax.x &&
                localMin.y <= localMax.y &&
                localMin.z <= localMax.z {
                let corners: [SIMD4<Float>] = [
                    SIMD4<Float>(Float(localMin.x), Float(localMin.y), Float(localMin.z), 1),
                    SIMD4<Float>(Float(localMin.x), Float(localMin.y), Float(localMax.z), 1),
                    SIMD4<Float>(Float(localMin.x), Float(localMax.y), Float(localMin.z), 1),
                    SIMD4<Float>(Float(localMin.x), Float(localMax.y), Float(localMax.z), 1),
                    SIMD4<Float>(Float(localMax.x), Float(localMin.y), Float(localMin.z), 1),
                    SIMD4<Float>(Float(localMax.x), Float(localMin.y), Float(localMax.z), 1),
                    SIMD4<Float>(Float(localMax.x), Float(localMax.y), Float(localMin.z), 1),
                    SIMD4<Float>(Float(localMax.x), Float(localMax.y), Float(localMax.z), 1)
                ]

                for corner in corners {
                    let worldCorner = worldTransform * corner
                    let offset = SIMD3<Float>(worldCorner.x, worldCorner.y, worldCorner.z) - volumeWorldCenter
                    radius = max(radius, simd_length(offset))
                }
            }
        }

        // Strategy 3: Use scaled bounding sphere radius
        if radius <= Float.ulpOfOne {
            let maxScale = max(lengthX, max(lengthY, lengthZ))
            if maxScale > Float.ulpOfOne {
                radius = Float(sphere.radius) * maxScale
            }
        }

        // Strategy 4: Fallback to material scale diagonal
        if radius <= Float.ulpOfOne {
            guard let material = volumeMaterial else { return }
            let scale = material.scale
            let diagonal = simd_length(scale)
            if diagonal > Float.ulpOfOne {
                radius = 0.5 * diagonal
            }
        }

        // Ensure minimum radius to prevent degenerate camera calculations
        let volumeBoundingRadius = max(radius, 1e-3)
        updateState(volumeWorldCenter, volumeBoundingRadius, updatedPatientLongitudinalAxis)
    }

    /// Clamps camera target to allowed distance from volume center.
    /// Prevents camera from panning too far from the volume, ensuring it stays
    /// within a sphere of radius (volumeBoundingRadius * maximumPanDistanceMultiplier).
    public func clampCameraTarget(
        _ target: SIMD3<Float>,
        volumeWorldCenter: SIMD3<Float>,
        volumeBoundingRadius: Float,
        maximumPanDistanceMultiplier: Float
    ) -> SIMD3<Float> {
        let offset = target - volumeWorldCenter
        let limit = max(volumeBoundingRadius * maximumPanDistanceMultiplier, 1.0)
        let distance = simd_length(offset)
        guard distance > limit else { return target }
        if distance <= Float.ulpOfOne {
            return volumeWorldCenter
        }
        // Project target back onto the limit sphere
        return volumeWorldCenter + (offset / distance) * limit
    }

    // MARK: - Patient Coordinate System

    /// Computes patient basis matrix from DICOM geometry orientation vectors.
    /// Ensures orthonormal basis with safe fallbacks for degenerate cases.
    public func patientBasis(from geometry: DICOMGeometry) -> simd_float3x3 {
        let row = safeNormalize(geometry.iopRow, fallback: SIMD3<Float>(1, 0, 0))
        var column = safeNormalize(geometry.iopCol, fallback: SIMD3<Float>(0, 1, 0))
        let cross = simd_cross(row, column)
        if simd_length_squared(cross) <= Float.ulpOfOne {
            column = safePerpendicular(to: row)
        }
        var normal = simd_cross(row, column)
        if simd_length_squared(normal) <= Float.ulpOfOne {
            normal = SIMD3<Float>(0, 0, 1)
        }
        normal = safeNormalize(normal, fallback: SIMD3<Float>(0, 0, 1))
        column = safeNormalize(simd_cross(normal, row), fallback: SIMD3<Float>(0, 1, 0))
        return simd_float3x3(columns: (row, column, normal))
    }

    // MARK: - Geometry Creation

    /// Creates DICOM geometry from volume dataset.
    public func makeGeometry(from dataset: VolumeDataset) -> DICOMGeometry {
        let orientation = dataset.orientation
        return DICOMGeometry(
            cols: Int32(dataset.dimensions.width),
            rows: Int32(dataset.dimensions.height),
            slices: Int32(dataset.dimensions.depth),
            spacingX: Float(dataset.spacing.x),
            spacingY: Float(dataset.spacing.y),
            spacingZ: Float(dataset.spacing.z),
            iopRow: orientation.row,
            iopCol: orientation.column,
            ipp0: orientation.origin
        )
    }

    // MARK: - Helper Methods

    /// Safely normalizes a vector, returning fallback if length is too small.
    private func safeNormalize(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let lengthSquared = simd_length_squared(vector)
        guard lengthSquared > Float.ulpOfOne else { return fallback }
        return vector / sqrt(lengthSquared)
    }

    /// Finds a safe perpendicular vector to the given vector.
    private func safePerpendicular(to vector: SIMD3<Float>) -> SIMD3<Float> {
        let axis = abs(vector.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        let perpendicular = simd_cross(vector, axis)
        return safeNormalize(perpendicular, fallback: SIMD3<Float>(0, 0, 1))
    }
}

#endif
