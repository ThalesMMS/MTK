//
//  MprPlaneComputation.swift
//  MTK
//
//  Replicates the volumetric plane helper previously hosted in the app target. Provides axis helpers
//  and coordinate conversions for MPR plane positioning within the volume datasets.
//

import simd
import MTKCore

#if os(iOS) || os(macOS)

struct MprPlaneComputation {
    let originVoxel: SIMD3<Float>
    let axisUVoxel: SIMD3<Float>
    let axisVVoxel: SIMD3<Float>

    static func make(axis: VolumetricSceneController.Axis,
                     index: Int,
                     dims: SIMD3<Float>,
                     rotation: simd_quatf) -> MprPlaneComputation {
        let identityQuaternion = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let normalizedRotation: simd_quatf
        if rotation.real == 0, rotation.imag == .zero {
            normalizedRotation = identityQuaternion
        } else {
            normalizedRotation = simd_normalize(rotation)
        }
        let rotationMatrix = simd_float3x3(normalizedRotation)
        let basis = defaultAxes(for: axis)
        let span = simd_max(dims - SIMD3<Float>(repeating: 1), SIMD3<Float>(repeating: 0))
        let scaledU = basis.u * span
        let scaledV = basis.v * span
        var axisUVoxel = rotationMatrix * scaledU
        var axisVVoxel = rotationMatrix * scaledV

        let center = planeCenterVoxel(for: axis, index: index, dims: dims)
        let halfU = axisUVoxel * 0.5
        let halfV = axisVVoxel * 0.5
        let combinedHalf = simd_abs(halfU) + simd_abs(halfV)

        var scale: Float = 1
        for component in 0..<3 {
            let extent = combinedHalf[component]
            guard extent > 0 else { continue }

            let lowerBound: Float = -0.5
            let upperBound = dims[component] - 0.5

            let spaceBelow = center[component] - lowerBound
            let spaceAbove = upperBound - center[component]
            let maxScaleBelow = spaceBelow / extent
            let maxScaleAbove = spaceAbove / extent
            let componentScale = min(maxScaleBelow, maxScaleAbove)
            scale = min(scale, componentScale)
        }

        if !scale.isFinite {
            scale = 1
        } else {
            scale = max(min(scale, 1), 0)
        }

        if scale < 1 {
            axisUVoxel *= scale
            axisVVoxel *= scale
        }

        let origin = center - 0.5 * axisUVoxel - 0.5 * axisVVoxel

        return MprPlaneComputation(originVoxel: origin,
                                   axisUVoxel: axisUVoxel,
                                   axisVVoxel: axisVVoxel)
    }

    func world(using geometry: DICOMGeometry) -> (origin: SIMD3<Float>, axisU: SIMD3<Float>, axisV: SIMD3<Float>) {
        let originWorld = geometry.voxelToWorld.transformPoint(originVoxel)
        let axisUWWorld = geometry.voxelToWorld.transformPoint(originVoxel + axisUVoxel) - originWorld
        let axisVWWorld = geometry.voxelToWorld.transformPoint(originVoxel + axisVVoxel) - originWorld
        return (originWorld, axisUWWorld, axisVWWorld)
    }

    func tex(using geometry: DICOMGeometry) -> (origin: SIMD3<Float>, axisU: SIMD3<Float>, axisV: SIMD3<Float>) {
        let world = world(using: geometry)
        let texBasis = geometry.planeWorldToTex(originW: world.origin, axisUW: world.axisU, axisVW: world.axisV)
        return (origin: texBasis.originT, axisU: texBasis.axisUT, axisV: texBasis.axisVT)
    }

    func tex(dims: SIMD3<Float>) -> (origin: SIMD3<Float>, axisU: SIMD3<Float>, axisV: SIMD3<Float>) {
        let safeDims = SIMD3<Float>(
            max(dims.x, 1),
            max(dims.y, 1),
            max(dims.z, 1)
        )
        let origin = (originVoxel + 0.5) / safeDims
        let axisU = axisUVoxel / safeDims
        let axisV = axisVVoxel / safeDims
        return (origin, axisU, axisV)
    }
}

extension MprPlaneComputation {
    static func datasetDimensions(width: Int, height: Int, depth: Int) -> SIMD3<Float> {
        SIMD3<Float>(
            max(1, Float(width)),
            max(1, Float(height)),
            max(1, Float(depth))
        )
    }

    static func defaultAxes(for axis: VolumetricSceneController.Axis) -> (u: SIMD3<Float>, v: SIMD3<Float>) {
        switch axis {
        case .x:
            return (SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1))
        case .y:
            return (SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, 1))
        case .z:
            return (SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0))
        }
    }

    static func planeCenterVoxel(for axis: VolumetricSceneController.Axis,
                                 index: Int,
                                 dims: SIMD3<Float>) -> SIMD3<Float> {
        let span = simd_max(dims - SIMD3<Float>(repeating: 1), SIMD3<Float>(repeating: 0))
        let halfSpan = span * 0.5
        switch axis {
        case .x:
            return SIMD3<Float>(Float(index), halfSpan.y, halfSpan.z)
        case .y:
            return SIMD3<Float>(halfSpan.x, Float(index), halfSpan.z)
        case .z:
            return SIMD3<Float>(halfSpan.x, halfSpan.y, Float(index))
        }
    }
}

#endif
