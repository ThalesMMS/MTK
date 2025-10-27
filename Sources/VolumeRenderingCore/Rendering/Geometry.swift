//
//  Geometry.swift
//  Isis DICOM Viewer
//
//  Modela transformações entre espaço do voxel, mundo (LPS) e coordenadas de textura para volumes MPR.
//  Constrói matrizes de ida e volta, normaliza vetores de orientação e projeta planos em espaço normalizado para orientar reslices.
//  Thales Matheus Mendonça Santos - September 2025
//

import simd

/// Encapsulates the voxel ↔ world ↔ texture geometry required to reslice volumes.
public struct DICOMGeometry {
    public let cols: Int32
    public let rows: Int32
    public let slices: Int32

    public let spacingX: Float
    public let spacingY: Float
    public let spacingZ: Float

    public let iopRow: SIMD3<Float>
    public let iopCol: SIMD3<Float>
    public let ipp0: SIMD3<Float>

    public var iopNorm: SIMD3<Float> { simd_normalize(simd_cross(iopRow, iopCol)) }

    public init(cols: Int32,
                rows: Int32,
                slices: Int32,
                spacingX: Float,
                spacingY: Float,
                spacingZ: Float,
                iopRow: SIMD3<Float>,
                iopCol: SIMD3<Float>,
                ipp0: SIMD3<Float>) {
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

    /// Maps VOXEL → WORLD (mm): IPP0 + i*Δx*r + j*Δy*c + k*Δz*n
    public var voxelToWorld: simd_float4x4 {
        let Rx = iopRow * spacingX
        let Cy = iopCol * spacingY
        let Nz = iopNorm * spacingZ
        let t = ipp0

        return simd_float4x4(columns: (
            SIMD4<Float>(Rx.x, Rx.y, Rx.z, 0),
            SIMD4<Float>(Cy.x, Cy.y, Cy.z, 0),
            SIMD4<Float>(Nz.x, Nz.y, Nz.z, 0),
            SIMD4<Float>(t.x, t.y, t.z, 1)
        ))
    }

    public var worldToVoxel: simd_float4x4 { simd_inverse(voxelToWorld) }

    /// Maps VOXEL → TEX ([0,1]^3): (voxel + 0.5) / dims
    private var voxelToTex: simd_float4x4 {
        let dx = Float(cols)
        let dy = Float(rows)
        let dz = Float(slices)

        let scale = simd_float4x4(diagonal: SIMD4<Float>(1 / dx, 1 / dy, 1 / dz, 1))
        let translateToCenter = simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0.5, 0.5, 0.5, 1)
        ))

        return scale * translateToCenter
    }

    /// Maps WORLD → TEX ([0,1]^3).
    public var worldToTex: simd_float4x4 { voxelToTex * worldToVoxel }

    /// Converts a plane defined in WORLD (mm) into TEX ([0,1]^3).
    /// - Parameters:
    ///   - originW: Plane origin in patient LPS coordinates (mm).
    ///   - axisUW: Basis vector for the U axis (mm).
    ///   - axisVW: Basis vector for the V axis (mm).
    /// - Returns: Origin and basis vectors expressed in normalized texture space.
    public func planeWorldToTex(originW: SIMD3<Float>,
                                axisUW: SIMD3<Float>,
                                axisVW: SIMD3<Float>) -> (originT: SIMD3<Float>,
                                                          axisUT: SIMD3<Float>,
                                                          axisVT: SIMD3<Float>)
    {
        let origin4 = worldToTex * SIMD4<Float>(originW, 1)
        let u4 = worldToTex * SIMD4<Float>(originW + axisUW, 1)
        let v4 = worldToTex * SIMD4<Float>(originW + axisVW, 1)

        let originNormalized = origin4 / origin4.w
        let uNormalized = u4 / u4.w
        let vNormalized = v4 / v4.w

        let originT = SIMD3<Float>(originNormalized.x, originNormalized.y, originNormalized.z)
        let axisUT = SIMD3<Float>(uNormalized.x, uNormalized.y, uNormalized.z) - originT
        let axisVT = SIMD3<Float>(vNormalized.x, vNormalized.y, vNormalized.z) - originT

        return (originT, axisUT, axisVT)
    }
}
