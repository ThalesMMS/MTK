//
//  VolumeCropFilter.swift
//  MTKCore
//
//  CPU crop filter for structured volume datasets.
//

import Foundation
import simd

public struct VolumeCropFilter: VolumeDatasetFilter, Sendable, Equatable {
    public let executionPolicy: VolumeFilterExecutionPolicy = .cpu
    public var inclusiveVoxelMin: SIMD3<Int32>
    public var inclusiveVoxelMax: SIMD3<Int32>

    public init(inclusiveVoxelMin: SIMD3<Int32>,
                inclusiveVoxelMax: SIMD3<Int32>) throws {
        guard inclusiveVoxelMin.x >= 0,
              inclusiveVoxelMin.y >= 0,
              inclusiveVoxelMin.z >= 0,
              inclusiveVoxelMin.x <= inclusiveVoxelMax.x,
              inclusiveVoxelMin.y <= inclusiveVoxelMax.y,
              inclusiveVoxelMin.z <= inclusiveVoxelMax.z else {
            throw VolumePipelineError.invalidCropBounds
        }
        self.inclusiveVoxelMin = inclusiveVoxelMin
        self.inclusiveVoxelMax = inclusiveVoxelMax
    }

    public init(cropBox: VolumeCropBox,
                dimensions: VolumeDimensions) throws {
        try VolumePipelineScalarData.validateDimensions(dimensions)
        let size = SIMD3<Float>(Float(dimensions.width),
                                Float(dimensions.height),
                                Float(dimensions.depth))
        let lower = cropBox.textureMin * size
        let upper = cropBox.textureMax * size
        let inclusiveMin = SIMD3<Int32>(Int32(floor(lower.x)),
                                        Int32(floor(lower.y)),
                                        Int32(floor(lower.z)))
        let inclusiveMax = SIMD3<Int32>(Int32(ceil(upper.x)) - 1,
                                        Int32(ceil(upper.y)) - 1,
                                        Int32(ceil(upper.z)) - 1)
        try self.init(inclusiveVoxelMin: inclusiveMin,
                      inclusiveVoxelMax: inclusiveMax)
    }

    public func apply(to dataset: VolumeDataset) async throws -> VolumeDataset {
        try VolumePipelineScalarData.validate(dataset)
        try validateBounds(in: dataset.dimensions)

        let sourceScalars = try VolumePipelineScalarData.decodedScalars(from: dataset)
        let newDimensions = VolumeDimensions(width: Int(inclusiveVoxelMax.x - inclusiveVoxelMin.x + 1),
                                             height: Int(inclusiveVoxelMax.y - inclusiveVoxelMin.y + 1),
                                             depth: Int(inclusiveVoxelMax.z - inclusiveVoxelMin.z + 1))
        var output = [Int32]()
        output.reserveCapacity(newDimensions.voxelCount)

        for z in Int(inclusiveVoxelMin.z)...Int(inclusiveVoxelMax.z) {
            for y in Int(inclusiveVoxelMin.y)...Int(inclusiveVoxelMax.y) {
                for x in Int(inclusiveVoxelMin.x)...Int(inclusiveVoxelMax.x) {
                    let sourceIndex = VolumePipelineScalarData.linearIndex(x: x,
                                                                          y: y,
                                                                          z: z,
                                                                          dimensions: dataset.dimensions)
                    output.append(sourceScalars[sourceIndex])
                }
            }
        }

        var imageData = dataset.imageData
        imageData.dimensions = newDimensions
        imageData.origin = dataset.imageData.indexToWorld.transformPoint(
            SIMD3<Float>(Float(inclusiveVoxelMin.x),
                         Float(inclusiveVoxelMin.y),
                         Float(inclusiveVoxelMin.z))
        )
        imageData.intensityRange = VolumePipelineScalarData.recomputeIntensityRange(output)

        return VolumeDataset(data: try VolumePipelineScalarData.encodedData(from: output,
                                                                            pixelFormat: dataset.pixelFormat),
                             imageData: imageData)
    }
}

private extension VolumeCropFilter {
    func validateBounds(in dimensions: VolumeDimensions) throws {
        guard inclusiveVoxelMax.x < Int32(dimensions.width),
              inclusiveVoxelMax.y < Int32(dimensions.height),
              inclusiveVoxelMax.z < Int32(dimensions.depth) else {
            throw VolumePipelineError.invalidCropBounds
        }
    }
}
