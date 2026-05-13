//
//  VolumeRenderGeometry.swift
//  MTKCore
//
//  Shared visual 3D geometry for volume raycasting and interaction.
//

import simd

package struct VolumeRenderGeometry: Sendable {
    package let physicalExtents: SIMD3<Float>
    package let normalizedExtents: SIMD3<Float>
    package let rowDirection: SIMD3<Float>
    package let columnDirection: SIMD3<Float>
    package let sliceDirection: SIMD3<Float>
    package let modelMatrix: simd_float4x4
    package let inverseModelMatrix: simd_float4x4
    package let boundingRadius: Float

    package init(imageData: ImageData3D) {
        let dimensions = imageData.dimensions
        let physical = SIMD3<Float>(
            Float(max(dimensions.width - 1, 0)) * Float(imageData.spacing.x),
            Float(max(dimensions.height - 1, 0)) * Float(imageData.spacing.y),
            Float(max(dimensions.depth - 1, 0)) * Float(imageData.spacing.z)
        )
        let longest = max(physical.x, max(physical.y, physical.z))
        let normalized = longest > 1e-6 && longest.isFinite
            ? physical / longest
            : SIMD3<Float>(repeating: 1)
        let safeExtents = SIMD3<Float>(
            max(normalized.x.isFinite ? normalized.x : 1, 1e-4),
            max(normalized.y.isFinite ? normalized.y : 1, 1e-4),
            max(normalized.z.isFinite ? normalized.z : 1, 1e-4)
        )

        let row = Self.safeNormalize(imageData.rowDirection,
                                     fallback: SIMD3<Float>(1, 0, 0))
        let column = Self.safeNormalize(imageData.columnDirection,
                                        fallback: SIMD3<Float>(0, 1, 0))
        let slice = Self.safeNormalize(imageData.sliceDirection,
                                       fallback: Self.safeCross(row, column))

        let xAxis = row * safeExtents.x
        let yAxis = column * safeExtents.y
        let zAxis = slice * safeExtents.z
        let model = simd_float4x4(columns: (
            SIMD4<Float>(xAxis, 0),
            SIMD4<Float>(yAxis, 0),
            SIMD4<Float>(zAxis, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))

        self.physicalExtents = physical
        self.normalizedExtents = safeExtents
        self.rowDirection = row
        self.columnDirection = column
        self.sliceDirection = slice
        self.modelMatrix = model
        self.inverseModelMatrix = simd_inverse(model)
        self.boundingRadius = max(0.5 * simd_length(safeExtents), 1e-3)
    }

    package init(dataset: VolumeDataset) {
        self.init(imageData: dataset.imageData)
    }

    package static func make(for dataset: VolumeDataset) -> VolumeRenderGeometry {
        VolumeRenderGeometry(dataset: dataset)
    }

    package func centeredTextureCoordinate(for textureCoordinate: SIMD3<Float>) -> SIMD3<Float> {
        textureCoordinate - SIMD3<Float>(repeating: 0.5)
    }

    package func textureCoordinate(forCenteredTextureCoordinate centered: SIMD3<Float>) -> SIMD3<Float> {
        centered + SIMD3<Float>(repeating: 0.5)
    }

    package func worldPosition(forTextureCoordinate textureCoordinate: SIMD3<Float>) -> SIMD3<Float> {
        modelMatrix.transformPoint(centeredTextureCoordinate(for: textureCoordinate))
    }

    package func textureCoordinate(forWorldPosition worldPosition: SIMD3<Float>) -> SIMD3<Float> {
        textureCoordinate(forCenteredTextureCoordinate: inverseModelMatrix.transformPoint(worldPosition))
    }

    package func worldDirection(forTextureDirection textureDirection: SIMD3<Float>) -> SIMD3<Float> {
        let transformed = modelMatrix.transformVector(textureDirection)
        return Self.safeNormalize(transformed, fallback: textureDirection)
    }

    package func textureDirection(forWorldDirection worldDirection: SIMD3<Float>) -> SIMD3<Float> {
        let transformed = inverseModelMatrix.transformVector(worldDirection)
        return Self.safeNormalize(transformed, fallback: worldDirection)
    }

    package func renderCamera(for camera: VolumeRenderRequest.Camera) -> VolumeRenderRequest.Camera {
        let position = worldPosition(forTextureCoordinate: camera.position)
        let target = worldPosition(forTextureCoordinate: camera.target)
        let up = worldDirection(forTextureDirection: camera.up)
        return VolumeRenderRequest.Camera(position: position,
                                          target: target,
                                          up: up,
                                          fieldOfView: camera.fieldOfView,
                                          projectionType: camera.projectionType)
    }

    private static func safeCross(_ lhs: SIMD3<Float>,
                                  _ rhs: SIMD3<Float>) -> SIMD3<Float> {
        safeNormalize(simd_cross(lhs, rhs), fallback: SIMD3<Float>(0, 0, 1))
    }

    private static func safeNormalize(_ value: SIMD3<Float>,
                                      fallback: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(value)
        if length > Float.ulpOfOne, length.isFinite {
            return value / length
        }
        let fallbackLength = simd_length(fallback)
        if fallbackLength > Float.ulpOfOne, fallbackLength.isFinite {
            return fallback / fallbackLength
        }
        return SIMD3<Float>(0, 0, 1)
    }
}

package extension simd_float4x4 {
    func transformVector(_ vector: SIMD3<Float>) -> SIMD3<Float> {
        let result = self * SIMD4<Float>(vector.x, vector.y, vector.z, 0)
        return SIMD3<Float>(result.x, result.y, result.z)
    }
}
