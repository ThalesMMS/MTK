//
//  VolumetricMPRController.swift
//  MetalVolumetrics
//
//  MPR (Multi-Planar Reconstruction) operations for volumetric scene rendering including
//  plane orientation, axis alignment, slab configuration, and camera synchronization.
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

/// Manages MPR plane configuration, orientation, and camera alignment for volumetric rendering.
/// Provides utilities for plane indexing, rotation, and synchronization with volume transforms.
@MainActor
public final class VolumetricMPRController {

    // MARK: - Properties

    private weak var sceneView: SCNView?
    private weak var volumeNode: SCNNode?
    private weak var mprNode: SCNNode?
    private weak var mprMaterial: MPRPlaneMaterial?
    private weak var cameraController: VolumetricCameraController?
    private weak var volumeGeometry: VolumetricVolumeGeometry?

    // MARK: - Initialization

    public init(sceneView: SCNView,
                volumeNode: SCNNode,
                mprNode: SCNNode,
                mprMaterial: MPRPlaneMaterial,
                cameraController: VolumetricCameraController,
                volumeGeometry: VolumetricVolumeGeometry) {
        self.sceneView = sceneView
        self.volumeNode = volumeNode
        self.mprNode = mprNode
        self.mprMaterial = mprMaterial
        self.cameraController = cameraController
        self.volumeGeometry = volumeGeometry
    }

    // MARK: - Patient Orientation

    /// Applies patient orientation to the volume node based on DICOM geometry.
    /// Uses the patient basis matrix to compute a quaternion orientation.
    public func applyPatientOrientationIfNeeded(geometry: DICOMGeometry?) {
        guard let volumeNode else { return }
        guard let geometry else {
            volumeNode.simdOrientation = simd_quatf()
            return
        }
        guard let volumeGeometry else { return }
        let basis = volumeGeometry.patientBasis(from: geometry)
        let quaternion = simd_normalize(simd_quatf(basis))
        volumeNode.simdOrientation = quaternion
    }

    /// Synchronizes the MPR node transform with the volume node transform.
    public func synchronizeMprNodeTransform() {
        guard let volumeNode, let mprNode else { return }
        mprNode.simdTransform = volumeNode.simdTransform
    }

    // MARK: - Index and Position Conversion

    /// Converts a voxel index to a normalized position [0, 1] for the given axis.
    public func normalizedPosition(for axis: VolumetricSceneController.Axis, index: Int) -> Float {
        guard let mprMaterial else { return 0.5 }
        let dim = mprMaterial.dimension
        let maxIndex: Float
        switch axis {
        case .x:
            maxIndex = max(1.0, Float(dim.x - 1))
        case .y:
            maxIndex = max(1.0, Float(dim.y - 1))
        case .z:
            maxIndex = max(1.0, Float(dim.z - 1))
        }
        let clamped = Float(index)
        return VolumetricMath.clampFloat(clamped / maxIndex, lower: 0.0, upper: 1.0)
    }

    /// Converts a normalized position [0, 1] to a voxel index for the given axis.
    public func indexPosition(for axis: VolumetricSceneController.Axis, normalized: Float) -> Int {
        guard let mprMaterial else { return 0 }
        let clamped = VolumetricMath.clampFloat(normalized, lower: 0.0, upper: 1.0)
        let dim = mprMaterial.dimension
        switch axis {
        case .x:
            return Int(round(clamped * Float(max(0, dim.x - 1))))
        case .y:
            return Int(round(clamped * Float(max(0, dim.y - 1))))
        case .z:
            return Int(round(clamped * Float(max(0, dim.z - 1))))
        }
    }

    /// Clamps a voxel index to the valid range for the given axis.
    public func clampedIndex(for axis: VolumetricSceneController.Axis, index: Int) -> Int {
        guard let mprMaterial else { return 0 }
        let dim = mprMaterial.dimension
        switch axis {
        case .x:
            return VolumetricMath.clamp(index, min: 0, max: Int(dim.x) - 1)
        case .y:
            return VolumetricMath.clamp(index, min: 0, max: Int(dim.y) - 1)
        case .z:
            return VolumetricMath.clamp(index, min: 0, max: Int(dim.z) - 1)
        }
    }

    // MARK: - MPR Orientation and Alignment

    /// Applies MPR orientation based on current axis, plane index, and Euler rotation.
    /// Updates MPR material with oblique plane parameters and aligns camera to the plane.
    /// Handles both DICOM geometry (world space) and texture space (fallback) orientations.
    public func applyMprOrientation(
        datasetApplied: Bool,
        currentMprAxis: VolumetricSceneController.Axis?,
        mprPlaneIndex: Int,
        mprEuler: SIMD3<Float>,
        geometry: DICOMGeometry?,
        fallbackWorldUp: SIMD3<Float>,
        volumeWorldCenter: SIMD3<Float>,
        volumeBoundingRadius: Float,
        defaultCameraDistanceFactor: Float,
        updateState: (_ fallbackCameraTransform: simd_float4x4,
                      _ initialCameraTransform: simd_float4x4,
                      _ defaultCameraTarget: SCNVector3) -> Void
    ) {
        guard datasetApplied, let axis = currentMprAxis else { return }
        guard let mprMaterial, let mprNode else { return }
        guard let cameraController else { return }

        // Compute rotation quaternion from Euler angles
        let rotation = rotationQuaternion(for: mprEuler)
        let dims = datasetDimensions()
        let plane = MprPlaneComputation.make(
            axis: axis,
            index: mprPlaneIndex,
            dims: dims,
            rotation: rotation
        )

        let normal: SIMD3<Float>
        let up: SIMD3<Float>

        // Z-axis planes need vertical flip for correct orientation
        mprMaterial.setVerticalFlip(axis == .z)

        if let geometry {
            // Use DICOM geometry for world-space plane definition
            let world = plane.world(using: geometry)
            let (originTex, axisUT, axisVT) = geometry.planeWorldToTex(
                originW: world.origin,
                axisUW: world.axisU,
                axisVW: world.axisV
            )

            mprMaterial.setOblique(origin: originTex, axisU: axisUT, axisV: axisVT)
            mprNode.setTransformFromBasisTex(originTex: originTex, axisUTex: axisUT, axisVTex: axisVT)

            normal = cameraController.safeNormalize(simd_cross(world.axisU, world.axisV), fallback: fallbackWorldUp)
            up = cameraController.safeNormalize(world.axisV, fallback: fallbackWorldUp)
        } else {
            // Fallback to texture-space plane definition
            mprNode.simdOrientation = rotation
            let fallback = plane.tex(dims: dims)
            mprMaterial.setOblique(origin: fallback.origin, axisU: fallback.axisU, axisV: fallback.axisV)

            normal = cameraController.safeNormalize(simd_cross(fallback.axisU, fallback.axisV), fallback: SIMD3<Float>(0, 0, 1))
            up = cameraController.safeNormalize(fallback.axisV, fallback: SIMD3<Float>(0, 1, 0))
        }

        alignCameraToMpr(
            normal: normal,
            up: up,
            volumeWorldCenter: volumeWorldCenter,
            volumeBoundingRadius: volumeBoundingRadius,
            defaultCameraDistanceFactor: defaultCameraDistanceFactor,
            fallbackWorldUp: fallbackWorldUp,
            updateState: updateState
        )
    }

    /// Aligns camera to face the MPR plane with the given normal and up vectors.
    public func alignCameraToMpr(
        normal: SIMD3<Float>,
        up: SIMD3<Float>,
        volumeWorldCenter: SIMD3<Float>,
        volumeBoundingRadius: Float,
        defaultCameraDistanceFactor: Float,
        fallbackWorldUp: SIMD3<Float>,
        updateState: (_ fallbackCameraTransform: simd_float4x4,
                      _ initialCameraTransform: simd_float4x4,
                      _ defaultCameraTarget: SCNVector3) -> Void
    ) {
        guard let cameraController, let sceneView else { return }

        let cameraNode = cameraController.ensureCameraNode(
            volumeBoundingRadius: volumeBoundingRadius,
            cameraOffset: SIMD3<Float>(0, 0, 0)
        )

        let safeNormal = cameraController.safeNormalize(normal, fallback: SIMD3<Float>(0, 0, 1))
        let safeUp = cameraController.safeNormalize(up, fallback: fallbackWorldUp)
        let center = volumeWorldCenter
        let radius = max(volumeBoundingRadius, 1e-3)
        let distance = max(radius * defaultCameraDistanceFactor, radius * 1.25)
        let position = center + safeNormal * distance
        let transform = cameraController.makeLookAtTransform(position: position, target: center, up: safeUp)

        cameraNode.simdTransform = transform
        let defaultCameraTarget = SCNVector3(center)
        sceneView.defaultCameraController.pointOfView = cameraNode
        sceneView.defaultCameraController.target = defaultCameraTarget
        sceneView.defaultCameraController.worldUp = SCNVector3(safeUp)
        sceneView.defaultCameraController.clearRoll()

        updateState(transform, transform, defaultCameraTarget)
    }

    /// Computes a rotation quaternion from Euler angles (X, Y, Z).
    public func rotationQuaternion(for euler: SIMD3<Float>) -> simd_quatf {
        let qx = simd_quatf(angle: euler.x, axis: SIMD3<Float>(1, 0, 0))
        let qy = simd_quatf(angle: euler.y, axis: SIMD3<Float>(0, 1, 0))
        let qz = simd_quatf(angle: euler.z, axis: SIMD3<Float>(0, 0, 1))
        return simd_normalize(qz * qy * qx)
    }

    /// Returns the dataset dimensions as a SIMD3<Float> vector.
    public func datasetDimensions() -> SIMD3<Float> {
        guard let mprMaterial else { return SIMD3<Float>(1, 1, 1) }
        let dims = mprMaterial.dimension
        return MprPlaneComputation.datasetDimensions(width: Int(dims.x), height: Int(dims.y), depth: Int(dims.z))
    }

    // MARK: - MPR Configuration

    /// Configures MPR with axis, index, blend mode, and optional slab configuration.
    /// Updates current MPR state and applies the new orientation.
    public func configureMPR(
        axis: VolumetricSceneController.Axis,
        index: Int,
        blend: MPRPlaneMaterial.BlendMode,
        slab: VolumetricSceneController.SlabConfiguration?,
        datasetApplied: Bool,
        geometry: DICOMGeometry?,
        fallbackWorldUp: SIMD3<Float>,
        volumeWorldCenter: SIMD3<Float>,
        volumeBoundingRadius: Float,
        defaultCameraDistanceFactor: Float,
        updateState: (_ currentMprAxis: VolumetricSceneController.Axis,
                      _ mprPlaneIndex: Int,
                      _ mprNormalizedPosition: Float,
                      _ mprEuler: SIMD3<Float>,
                      _ fallbackCameraTransform: simd_float4x4,
                      _ initialCameraTransform: simd_float4x4,
                      _ defaultCameraTarget: SCNVector3) -> Void
    ) {
        guard let mprMaterial else { return }

        mprMaterial.setBlend(blend)
        if let slab {
            mprMaterial.setSlab(thicknessInVoxels: slab.thickness, axis: axis.rawValue, steps: slab.steps)
        } else {
            mprMaterial.setSlab(thicknessInVoxels: 1, axis: axis.rawValue, steps: 1)
        }

        let mprPlaneIndex = clampedIndex(for: axis, index: index)
        let mprNormalizedPosition = normalizedPosition(for: axis, index: mprPlaneIndex)
        let mprEuler = SIMD3<Float>.zero

        // Apply MPR orientation and capture state updates
        var capturedFallbackTransform: simd_float4x4 = simd_float4x4(1)
        var capturedInitialTransform: simd_float4x4 = simd_float4x4(1)
        var capturedDefaultCameraTarget = SCNVector3(0, 0, 0)

        applyMprOrientation(
            datasetApplied: datasetApplied,
            currentMprAxis: axis,
            mprPlaneIndex: mprPlaneIndex,
            mprEuler: mprEuler,
            geometry: geometry,
            fallbackWorldUp: fallbackWorldUp,
            volumeWorldCenter: volumeWorldCenter,
            volumeBoundingRadius: volumeBoundingRadius,
            defaultCameraDistanceFactor: defaultCameraDistanceFactor,
            updateState: { fallbackTransform, initialTransform, defaultTarget in
                capturedFallbackTransform = fallbackTransform
                capturedInitialTransform = initialTransform
                capturedDefaultCameraTarget = defaultTarget
            }
        )

        // Update state with new MPR configuration
        updateState(
            axis,
            mprPlaneIndex,
            mprNormalizedPosition,
            mprEuler,
            capturedFallbackTransform,
            capturedInitialTransform,
            capturedDefaultCameraTarget
        )
    }

}

#endif
