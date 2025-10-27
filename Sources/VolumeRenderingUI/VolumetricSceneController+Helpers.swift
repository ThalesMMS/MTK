//
//  VolumetricSceneController+Helpers.swift
//  MetalVolumetrics
//
//  Supporting math helpers for the volumetric controller.
//
#if os(iOS)
import Foundation
import SceneKit
import VolumeRenderingCore
import VolumeRenderingCore
import simd
#if canImport(Metal)
import Metal
#endif


private extension SCNVector3 {
    init(_ vector: SIMD3<Float>) {
        self.init(vector.x, vector.y, vector.z)
    }
}

extension simd_float4x4 {
    func transformPoint(_ point: SIMD3<Float>) -> SIMD3<Float> {
        (self * SIMD4<Float>(point.x, point.y, point.z, 1)).xyz
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3<Float>(x, y, z) }
}

extension SCNNode {
    func setTransformFromBasisTex(originTex: SIMD3<Float>, axisUTex: SIMD3<Float>, axisVTex: SIMD3<Float>) {
        let width = simd_length(axisUTex)
        let height = simd_length(axisVTex)

        let uHat = width > 0 ? axisUTex / width : SIMD3<Float>(1, 0, 0)
        let vProjection = axisVTex - simd_dot(axisVTex, uHat) * uHat
        let vLength = simd_length(vProjection)
        let vHat = vLength > 0 ? vProjection / vLength : SIMD3<Float>(0, 1, 0)
        let nHat = simd_normalize(simd_cross(uHat, vHat))

        simdOrientation = simd_quatf(simd_float3x3(columns: (uHat, vHat, nHat)))

        let center = originTex + 0.5 * axisUTex + 0.5 * axisVTex - SIMD3<Float>(repeating: 0.5)
        simdPosition = center

        if let plane = geometry as? SCNPlane {
            plane.width = CGFloat(width)
            plane.height = CGFloat(height)
        }
    }
}

func clampFloat(_ value: Float, lower: Float, upper: Float) -> Float {
    min(upper, max(lower, value))
}
#endif
