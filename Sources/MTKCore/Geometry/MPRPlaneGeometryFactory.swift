//
//  MPRPlaneGeometryFactory.swift
//  MTKCore
//
//  Clinical MPR plane generation backed by the dataset's DICOM geometry.
//

import simd

public enum MPRPlaneGeometryFactory {
    public static func makePlane(for dataset: VolumeDataset,
                                 axis: MPRPlaneAxis,
                                 slicePosition: Float) -> MPRPlaneGeometry {
        let geometry = makeGeometry(for: dataset)
        let spans = voxelSpans(for: dataset.dimensions)
        let clampedPosition = VolumetricMath.clampFloat(slicePosition, lower: 0, upper: 1)

        let sliceIndex: Float
        let originVoxel: SIMD3<Float>
        let axisUVoxel: SIMD3<Float>
        let axisVVoxel: SIMD3<Float>
        let expectedNormal: SIMD3<Float>

        switch axis {
        case .x:
            sliceIndex = spans.x * clampedPosition
            originVoxel = SIMD3<Float>(sliceIndex, 0, 0)
            axisUVoxel = SIMD3<Float>(0, spans.y, 0)
            axisVVoxel = SIMD3<Float>(0, 0, spans.z)
            expectedNormal = normalized(vector: dataset.orientation.row,
                                        fallback: SIMD3<Float>(1, 0, 0))
        case .y:
            sliceIndex = spans.y * clampedPosition
            originVoxel = SIMD3<Float>(spans.x, sliceIndex, 0)
            axisUVoxel = SIMD3<Float>(-spans.x, 0, 0)
            axisVVoxel = SIMD3<Float>(0, 0, spans.z)
            expectedNormal = normalized(vector: dataset.orientation.column,
                                        fallback: SIMD3<Float>(0, 1, 0))
        case .z:
            sliceIndex = spans.z * clampedPosition
            originVoxel = SIMD3<Float>(0, 0, sliceIndex)
            axisUVoxel = SIMD3<Float>(spans.x, 0, 0)
            axisVVoxel = SIMD3<Float>(0, spans.y, 0)
            expectedNormal = normalized(cross: dataset.orientation.row,
                                        dataset.orientation.column,
                                        fallback: SIMD3<Float>(0, 0, 1))
        }

        let originWorld = geometry.voxelToWorld.transformPoint(originVoxel)
        let axisUWorld = geometry.voxelToWorld.transformPoint(originVoxel + axisUVoxel) - originWorld
        let axisVWorld = geometry.voxelToWorld.transformPoint(originVoxel + axisVVoxel) - originWorld
        let textureBasis = geometry.planeWorldToTex(originW: originWorld,
                                                    axisUW: axisUWorld,
                                                    axisVW: axisVWorld)
        let normalWorld = normalized(cross: axisUWorld, axisVWorld, fallback: expectedNormal)

        return MPRPlaneGeometry(
            originVoxel: originVoxel,
            axisUVoxel: axisUVoxel,
            axisVVoxel: axisVVoxel,
            originWorld: originWorld,
            axisUWorld: axisUWorld,
            axisVWorld: axisVWorld,
            originTexture: textureBasis.originT,
            axisUTexture: textureBasis.axisUT,
            axisVTexture: textureBasis.axisVT,
            normalWorld: normalWorld
        )
    }

    @_spi(Testing)
    public static func makeGeometry(for dataset: VolumeDataset) -> DICOMGeometry {
        // Preserve the dataset's established world units so every transform
        // used by the plane geometry and slab thickness calculation stays aligned.
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

    @_spi(Testing)
    public static func effectiveNormalSpacing(for dataset: VolumeDataset,
                                              plane: MPRPlaneGeometry) -> Float {
        let normal = normalized(vector: plane.normalWorld, fallback: SIMD3<Float>(0, 0, 1))
        let sliceNormal = normalized(cross: dataset.orientation.row,
                                     dataset.orientation.column,
                                     fallback: SIMD3<Float>(0, 0, 1))
        let axisX = normalized(vector: dataset.orientation.row, fallback: SIMD3<Float>(1, 0, 0))
            * Float(dataset.spacing.x)
        let axisY = normalized(vector: dataset.orientation.column, fallback: SIMD3<Float>(0, 1, 0))
            * Float(dataset.spacing.y)
        let axisZ = sliceNormal * Float(dataset.spacing.z)
        let projectedSpacings = [
            abs(simd_dot(axisX, normal)),
            abs(simd_dot(axisY, normal)),
            abs(simd_dot(axisZ, normal))
        ]
        return projectedSpacings.max() ?? 0
    }

    @_spi(Testing)
    public static func volumeExtentAlongNormal(for dataset: VolumeDataset,
                                               plane: MPRPlaneGeometry) -> Float {
        let geometry = makeGeometry(for: dataset)
        let normal = normalized(vector: plane.normalWorld, fallback: SIMD3<Float>(0, 0, 1))
        let originTexture = geometry.worldToTex.transformPoint(plane.originWorld)
        let targetTexture = geometry.worldToTex.transformPoint(plane.originWorld + normal)
        let textureUnitsPerWorldUnit = simd_length(targetTexture - originTexture)
        guard textureUnitsPerWorldUnit > Float.ulpOfOne else { return 0 }
        return 1 / textureUnitsPerWorldUnit
    }

    @_spi(Testing)
    public static func normalizedTextureThickness(for thickness: Float,
                                                  dataset: VolumeDataset,
                                                  plane: MPRPlaneGeometry) -> Float {
        guard thickness > 0 else { return 0 }

        let effectiveSpacing = effectiveNormalSpacing(for: dataset, plane: plane)
        let volumeExtentAlongNormal = volumeExtentAlongNormal(for: dataset, plane: plane)
        guard effectiveSpacing > Float.ulpOfOne,
              volumeExtentAlongNormal > Float.ulpOfOne else {
            return 0
        }

        return (thickness * effectiveSpacing) / volumeExtentAlongNormal
    }
}

private extension MPRPlaneGeometryFactory {
    static func voxelSpans(for dimensions: VolumeDimensions) -> SIMD3<Float> {
        SIMD3<Float>(
            max(Float(dimensions.width - 1), 0),
            max(Float(dimensions.height - 1), 0),
            max(Float(dimensions.depth - 1), 0)
        )
    }

    static func normalized(cross lhs: SIMD3<Float>,
                           _ rhs: SIMD3<Float>,
                           fallback: SIMD3<Float>) -> SIMD3<Float> {
        normalized(vector: simd_cross(lhs, rhs), fallback: fallback)
    }

    static func normalized(vector: SIMD3<Float>,
                           fallback: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(vector)
        if length > Float.ulpOfOne {
            return vector / length
        }

        let fallbackLength = simd_length(fallback)
        if fallbackLength > Float.ulpOfOne {
            return fallback / fallbackLength
        }

        return SIMD3<Float>(0, 0, 1)
    }
}
