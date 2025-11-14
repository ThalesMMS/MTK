//
//  SCNNode+Volumetric.swift
//  MTKSceneKit
//
//  SceneKit extensions for volumetric rendering plane transformations.
//  Originally from MTK-Demo — Migrated to MTKSceneKit for reusability.
//  Thales Matheus Mendonça Santos — November 2025
//

import SceneKit
import simd

public extension SCNNode {
    /// Configure pose of a plane (SCNPlane) child of the volume cube.
    /// - Parameters:
    ///   - originTex: Plane origin in texture coordinates [0,1]^3
    ///   - UTex: U axis in texture coordinates
    ///   - VTex: V axis in texture coordinates
    /// - Note: The node must be a CHILD of the volume cube to inherit anisotropic scaling
    func setTransformFromBasisTex(originTex o: simd_float3,
                                  UTex u: simd_float3,
                                  VTex v: simd_float3) {
        // Rectangle dimensions in [0,1] space
        let width  = simd_length(u)
        let height = simd_length(v)

        // Orthonormal basis (U, V, N)
        let Uhat = width > 0 ? simd_normalize(u) : simd_float3(1, 0, 0)
        let vOrtho = v - simd_dot(v, Uhat) * Uhat
        let Vhat = simd_length(vOrtho) > 0 ? simd_normalize(vOrtho) : simd_float3(0, 1, 0)
        let Nhat = simd_normalize(simd_cross(Uhat, Vhat))
        let R = simd_float3x3(columns: (Uhat, Vhat, Nhat))

        // Plane center in cube local space [-0.5..+0.5]^3
        let centerLocal = o + 0.5 * u + 0.5 * v - simd_float3(0.5, 0.5, 0.5)

        // Apply rotation and position
        self.simdOrientation = simd_quatf(R)
        self.simdPosition    = centerLocal

        // Set width/height of SCNPlane in cube local space
        if let plane = self.geometry as? SCNPlane {
            plane.width  = CGFloat(width)
            plane.height = CGFloat(height)
        }
    }
}
