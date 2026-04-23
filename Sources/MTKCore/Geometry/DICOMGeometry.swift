//
//  DICOMGeometry.swift
//  MTKCore
//
//  Essential DICOM geometry: maps WORLD(mm, LPS) <-> VOXEL(i,j,k) <-> TEX([0,1]^3)
//  Originally from MTK-Demo — Migrated to MTKCore for reusability.
//  Thales Matheus Mendonça Santos — November 2025
//

import simd

/// Essential DICOM geometry utilities for coordinate system transformations
public struct DICOMGeometry {
    public let cols: Int32
    public let rows: Int32
    public let slices: Int32
    public let spacingX: Float  // mm
    public let spacingY: Float  // mm
    public let spacingZ: Float  // mm
    public let iopRow: simd_float3    // ImageOrientationPatient (row)
    public let iopCol: simd_float3    // ImageOrientationPatient (column)
    public let ipp0: simd_float3      // ImagePositionPatient of first slice

    /// Initialize DICOM geometry with volume parameters
    public init(cols: Int32, rows: Int32, slices: Int32,
                spacingX: Float, spacingY: Float, spacingZ: Float,
                iopRow: simd_float3, iopCol: simd_float3, ipp0: simd_float3) {
        self.cols = cols
        self.rows = rows
        self.slices = slices
        self.spacingX = spacingX
        self.spacingY = spacingY
        self.spacingZ = spacingZ
        self.iopRow = iopRow
        self.iopCol = iopCol
        self.ipp0 = ipp0
    }

    /// Normal vector perpendicular to image plane
    public var iopNorm: simd_float3 {
        simd_normalize(simd_cross(iopRow, iopCol))
    }

    /// Transformation matrix from voxel coordinates to world coordinates (mm)
    /// Formula: IPP0 + i*Δx*r + j*Δy*c + k*Δz*n
    public var voxelToWorld: simd_float4x4 {
        let Rx = iopRow * spacingX
        let Cy = iopCol * spacingY
        let Nz = iopNorm * spacingZ
        let t  = ipp0
        return simd_float4x4(columns: (
            simd_float4(Rx.x, Rx.y, Rx.z, 0),
            simd_float4(Cy.x, Cy.y, Cy.z, 0),
            simd_float4(Nz.x, Nz.y, Nz.z, 0),
            simd_float4(t.x, t.y, t.z, 1)
        ))
    }

    /// Transformation matrix from world coordinates to voxel coordinates
    public var worldToVoxel: simd_float4x4 {
        simd_inverse(voxelToWorld)
    }

    /// Transformation matrix from voxel coordinates to texture coordinates [0,1]^3
    /// Formula: (voxel + 0.5) / dims
    public var voxelToTex: simd_float4x4 {
        precondition(cols > 0 && rows > 0 && slices > 0,
                     "DICOMGeometry.voxelToTex requires positive volume dimensions; got cols=\(cols), rows=\(rows), slices=\(slices)")
        let dx = Float(cols), dy = Float(rows), dz = Float(slices)
        return simd_float4x4(columns: (
            simd_float4(1 / dx, 0, 0, 0),
            simd_float4(0, 1 / dy, 0, 0),
            simd_float4(0, 0, 1 / dz, 0),
            simd_float4(0.5 / dx, 0.5 / dy, 0.5 / dz, 1)
        ))
    }

    /// Transformation matrix from world coordinates to texture coordinates [0,1]^3
    public var worldToTex: simd_float4x4 {
        voxelToTex * worldToVoxel
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
