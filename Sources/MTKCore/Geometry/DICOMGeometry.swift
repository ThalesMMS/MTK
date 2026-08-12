//
//  DICOMGeometry.swift
//  MTKCore
//
//  Maps DICOM LPS patient coordinates, voxel indices, and normalized texture coordinates.
//  Builds the voxel-to-world affine from the volume origin, direction vectors, and
//  spacing, with half-voxel texture center offsets.
//
//  Thales Matheus Mendonça Santos — November 2025
//

import simd

/// Essential DICOM geometry utilities for coordinate system transformations
public struct DICOMGeometry {
    private let imageData: ImageData3D

    public var cols: Int32 { Int32(imageData.dimensions.width) }
    public var rows: Int32 { Int32(imageData.dimensions.height) }
    public var slices: Int32 { Int32(imageData.dimensions.depth) }
    public var spacingX: Float { Float(imageData.spacing.x) }  // mm
    public var spacingY: Float { Float(imageData.spacing.y) }  // mm
    public var spacingZ: Float { Float(imageData.spacing.z) }  // mm
    public var iopRow: simd_float3 { imageData.rowDirection }  // ImageOrientationPatient row
    public var iopCol: simd_float3 { imageData.columnDirection }  // ImageOrientationPatient column
    public var ipp0: simd_float3 { imageData.origin }  // ImagePositionPatient of first slice

    /// Initialize DICOM geometry with volume parameters
    public init(cols: Int32, rows: Int32, slices: Int32,
                spacingX: Float, spacingY: Float, spacingZ: Float,
                iopRow: simd_float3, iopCol: simd_float3, ipp0: simd_float3) {
        let dimensions = VolumeDimensions(width: Int(cols), height: Int(rows), depth: Int(slices))
        let spacing = VolumeSpacing(x: Double(spacingX), y: Double(spacingY), z: Double(spacingZ))
        let normal = ImageData3D.normalizedCross(iopRow, iopCol, fallback: SIMD3<Float>(0, 0, 1))
        self.imageData = ImageData3D(dimensions: dimensions,
                                     spacing: spacing,
                                     origin: ipp0,
                                     direction: simd_float3x3(columns: (iopRow, iopCol, normal)),
                                     pixelFormat: .int16Signed)
    }

    /// Initialize geometry from the canonical structured-image contract.
    public init(imageData: ImageData3D) {
        self.imageData = imageData
    }

    /// Normal vector perpendicular to image plane
    public var iopNorm: simd_float3 {
        imageData.sliceDirection
    }

    /// Transformation matrix from voxel coordinates to world coordinates (mm)
    /// Formula: IPP0 + i*Δx*r + j*Δy*c + k*Δz*n
    public var voxelToWorld: simd_float4x4 {
        imageData.indexToWorld
    }

    /// Transformation matrix from world coordinates to voxel coordinates
    public var worldToVoxel: simd_float4x4 {
        imageData.worldToIndex
    }

    /// Transformation matrix from voxel coordinates to texture coordinates [0,1]^3
    /// Formula: (voxel + 0.5) / dims
    public var voxelToTex: simd_float4x4 {
        imageData.voxelToTexture
    }

    /// Transformation matrix from world coordinates to texture coordinates [0,1]^3
    public var worldToTex: simd_float4x4 {
        imageData.worldToTexture
    }

    /// Convert a plane defined in world coordinates (mm) to texture coordinates ([0,1]^3)
    /// - Parameters:
    ///   - originW: Plane origin in world space (mm, LPS)
    ///   - axisUW: Plane U axis in world space
    ///   - axisVW: Plane V axis in world space
    /// - Returns: Plane origin and axes in texture coordinates
    public func planeWorldToTex(originW: simd_float3,
                                axisUW: simd_float3,
                                axisVW: simd_float3) -> (originT: simd_float3,
                                                         axisUT: simd_float3,
                                                         axisVT: simd_float3) {
        let O = (worldToTex * simd_float4(originW, 1)).xyz
        let U = (worldToTex * simd_float4(originW + axisUW, 1)).xyz - O
        let V = (worldToTex * simd_float4(originW + axisVW, 1)).xyz - O
        return (O, U, V)
    }
}

// MARK: - SIMD Extensions
public extension simd_float4x4 {
    func transformPoint(_ point: SIMD3<Float>) -> SIMD3<Float> {
        let result = self * SIMD4<Float>(point.x, point.y, point.z, 1)
        let w = result.w
        if abs(w) <= Float.ulpOfOne {
            preconditionFailure("simd_float4x4.transformPoint requires a non-zero homogeneous w result")
        }
        if abs(w - 1) <= 1e-6 {
            return SIMD3<Float>(result.x, result.y, result.z)
        }
        return SIMD3<Float>(result.x, result.y, result.z) / w
    }
}

extension simd_float4 {
    /// Extracts the first three components (x, y, z) from this `simd_float4` and returns them as a `simd_float3`.
    var xyz: simd_float3 {
        simd_float3(x, y, z)
    }
}
