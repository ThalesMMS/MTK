//
//  VolumeResampleFilter.swift
//  MTKCore
//
//  CPU resampling filter for scalar volume datasets.
//

import Foundation

public enum VolumeResampleInterpolation: Sendable, Equatable {
    case nearest
    case trilinear
}

public struct VolumeResampleFilter: VolumeDatasetFilter, Sendable, Equatable {
    public let executionPolicy: VolumeFilterExecutionPolicy = .cpu
    public var targetDimensions: VolumeDimensions
    public var interpolation: VolumeResampleInterpolation

    public init(targetDimensions: VolumeDimensions,
                interpolation: VolumeResampleInterpolation = .trilinear) throws {
        try VolumePipelineScalarData.validateDimensions(targetDimensions)
        self.targetDimensions = targetDimensions
        self.interpolation = interpolation
    }

    public func apply(to dataset: VolumeDataset) async throws -> VolumeDataset {
        try VolumePipelineScalarData.validate(dataset)
        try VolumePipelineScalarData.validateSpacing(dataset.spacing)

        let source = try VolumePipelineScalarData.decodedScalars(from: dataset)
        var output = [Int32]()
        output.reserveCapacity(targetDimensions.voxelCount)

        for z in 0..<targetDimensions.depth {
            let sourceZ = sourceCoordinate(destinationIndex: z,
                                          sourceCount: dataset.dimensions.depth,
                                          destinationCount: targetDimensions.depth)
            for y in 0..<targetDimensions.height {
                let sourceY = sourceCoordinate(destinationIndex: y,
                                              sourceCount: dataset.dimensions.height,
                                              destinationCount: targetDimensions.height)
                for x in 0..<targetDimensions.width {
                    let sourceX = sourceCoordinate(destinationIndex: x,
                                                  sourceCount: dataset.dimensions.width,
                                                  destinationCount: targetDimensions.width)
                    let sample: Float
                    switch interpolation {
                    case .nearest:
                        sample = nearestSample(source,
                                               dimensions: dataset.dimensions,
                                               x: sourceX,
                                               y: sourceY,
                                               z: sourceZ)
                    case .trilinear:
                        sample = trilinearSample(source,
                                                 dimensions: dataset.dimensions,
                                                 x: sourceX,
                                                 y: sourceY,
                                                 z: sourceZ)
                    }
                    output.append(Int32(sample.rounded(.toNearestOrAwayFromZero)))
                }
            }
        }

        var imageData = dataset.imageData
        imageData.dimensions = targetDimensions
        imageData.spacing = VolumeSpacing(
            x: dataset.spacing.x * Double(dataset.dimensions.width) / Double(targetDimensions.width),
            y: dataset.spacing.y * Double(dataset.dimensions.height) / Double(targetDimensions.height),
            z: dataset.spacing.z * Double(dataset.dimensions.depth) / Double(targetDimensions.depth)
        )
        imageData.intensityRange = VolumePipelineScalarData.recomputeIntensityRange(output)

        return VolumeDataset(data: try VolumePipelineScalarData.encodedData(from: output,
                                                                            pixelFormat: dataset.pixelFormat),
                             imageData: imageData)
    }
}

private extension VolumeResampleFilter {
    func sourceCoordinate(destinationIndex: Int,
                          sourceCount: Int,
                          destinationCount: Int) -> Float {
        guard sourceCount > 1 else { return 0 }
        return (Float(destinationIndex) + 0.5) * Float(sourceCount) / Float(destinationCount) - 0.5
    }

    func nearestSample(_ source: [Int32],
                       dimensions: VolumeDimensions,
                       x: Float,
                       y: Float,
                       z: Float) -> Float {
        let sampleX = clamp(Int(x.rounded(.toNearestOrAwayFromZero)), upperBound: dimensions.width - 1)
        let sampleY = clamp(Int(y.rounded(.toNearestOrAwayFromZero)), upperBound: dimensions.height - 1)
        let sampleZ = clamp(Int(z.rounded(.toNearestOrAwayFromZero)), upperBound: dimensions.depth - 1)
        let index = VolumePipelineScalarData.linearIndex(x: sampleX, y: sampleY, z: sampleZ, dimensions: dimensions)
        return Float(source[index])
    }

    func trilinearSample(_ source: [Int32],
                         dimensions: VolumeDimensions,
                         x: Float,
                         y: Float,
                         z: Float) -> Float {
        let clampedX = VolumetricMath.clampFloat(x, lower: 0, upper: Float(dimensions.width - 1))
        let clampedY = VolumetricMath.clampFloat(y, lower: 0, upper: Float(dimensions.height - 1))
        let clampedZ = VolumetricMath.clampFloat(z, lower: 0, upper: Float(dimensions.depth - 1))

        let x0 = Int(floor(clampedX))
        let y0 = Int(floor(clampedY))
        let z0 = Int(floor(clampedZ))
        let x1 = min(x0 + 1, dimensions.width - 1)
        let y1 = min(y0 + 1, dimensions.height - 1)
        let z1 = min(z0 + 1, dimensions.depth - 1)

        let tx = clampedX - Float(x0)
        let ty = clampedY - Float(y0)
        let tz = clampedZ - Float(z0)

        let c000 = scalar(source, dimensions: dimensions, x: x0, y: y0, z: z0)
        let c100 = scalar(source, dimensions: dimensions, x: x1, y: y0, z: z0)
        let c010 = scalar(source, dimensions: dimensions, x: x0, y: y1, z: z0)
        let c110 = scalar(source, dimensions: dimensions, x: x1, y: y1, z: z0)
        let c001 = scalar(source, dimensions: dimensions, x: x0, y: y0, z: z1)
        let c101 = scalar(source, dimensions: dimensions, x: x1, y: y0, z: z1)
        let c011 = scalar(source, dimensions: dimensions, x: x0, y: y1, z: z1)
        let c111 = scalar(source, dimensions: dimensions, x: x1, y: y1, z: z1)

        let c00 = lerp(c000, c100, tx)
        let c01 = lerp(c001, c101, tx)
        let c10 = lerp(c010, c110, tx)
        let c11 = lerp(c011, c111, tx)
        let c0 = lerp(c00, c10, ty)
        let c1 = lerp(c01, c11, ty)
        return lerp(c0, c1, tz)
    }

    func scalar(_ source: [Int32],
                dimensions: VolumeDimensions,
                x: Int,
                y: Int,
                z: Int) -> Float {
        Float(source[VolumePipelineScalarData.linearIndex(x: x, y: y, z: z, dimensions: dimensions)])
    }

    func lerp(_ lhs: Float, _ rhs: Float, _ t: Float) -> Float {
        lhs + (rhs - lhs) * t
    }

    func clamp(_ value: Int, upperBound: Int) -> Int {
        min(max(value, 0), upperBound)
    }
}
