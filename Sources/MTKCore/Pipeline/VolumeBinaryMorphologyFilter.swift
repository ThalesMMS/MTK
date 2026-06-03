//
//  VolumeBinaryMorphologyFilter.swift
//  MTKCore
//
//  CPU binary morphology filter for scalar volume datasets.
//

import Foundation

public enum VolumeBinaryMorphologyOperation: Sendable, Equatable {
    case dilate
    case erode
    case open
    case close
}

public struct VolumeBinaryMorphologyFilter: VolumeDatasetFilter, Sendable, Equatable {
    public let executionPolicy: VolumeFilterExecutionPolicy = .cpu
    public var operation: VolumeBinaryMorphologyOperation
    public var foregroundRange: ClosedRange<Int32>
    public var foregroundValue: Int32
    public var backgroundValue: Int32
    public var radius: Int

    public init(operation: VolumeBinaryMorphologyOperation,
                foregroundRange: ClosedRange<Int32> = 1...Int32.max,
                foregroundValue: Int32 = 1,
                backgroundValue: Int32 = 0,
                radius: Int = 1) throws {
        guard radius > 0 else {
            throw VolumePipelineError.invalidKernelRadius
        }
        self.operation = operation
        self.foregroundRange = foregroundRange
        self.foregroundValue = foregroundValue
        self.backgroundValue = backgroundValue
        self.radius = radius
    }

    public func apply(to dataset: VolumeDataset) async throws -> VolumeDataset {
        try VolumePipelineScalarData.validate(dataset)
        try VolumePipelineScalarData.validateReplacementValue(foregroundValue,
                                                              pixelFormat: dataset.pixelFormat)
        try VolumePipelineScalarData.validateReplacementValue(backgroundValue,
                                                              pixelFormat: dataset.pixelFormat)

        let scalars = try VolumePipelineScalarData.decodedScalars(from: dataset)
        let foreground = scalars.map { foregroundRange.contains($0) }
        let processed: [Bool]
        switch operation {
        case .dilate:
            processed = dilated(foreground, dimensions: dataset.dimensions)
        case .erode:
            processed = eroded(foreground, dimensions: dataset.dimensions)
        case .open:
            processed = dilated(eroded(foreground, dimensions: dataset.dimensions), dimensions: dataset.dimensions)
        case .close:
            processed = eroded(dilated(foreground, dimensions: dataset.dimensions), dimensions: dataset.dimensions)
        }

        let output = processed.map { $0 ? foregroundValue : backgroundValue }
        var imageData = dataset.imageData
        imageData.intensityRange = VolumePipelineScalarData.recomputeIntensityRange(output)

        return VolumeDataset(data: try VolumePipelineScalarData.encodedData(from: output,
                                                                            pixelFormat: dataset.pixelFormat),
                             imageData: imageData)
    }
}

private extension VolumeBinaryMorphologyFilter {
    func dilated(_ foreground: [Bool], dimensions: VolumeDimensions) -> [Bool] {
        var output = [Bool](repeating: false, count: foreground.count)
        for z in 0..<dimensions.depth {
            for y in 0..<dimensions.height {
                for x in 0..<dimensions.width {
                    let index = VolumePipelineScalarData.linearIndex(x: x, y: y, z: z, dimensions: dimensions)
                    output[index] = hasForegroundNeighbor(foreground, dimensions: dimensions, x: x, y: y, z: z)
                }
            }
        }
        return output
    }

    func eroded(_ foreground: [Bool], dimensions: VolumeDimensions) -> [Bool] {
        var output = [Bool](repeating: false, count: foreground.count)
        for z in 0..<dimensions.depth {
            for y in 0..<dimensions.height {
                for x in 0..<dimensions.width {
                    let index = VolumePipelineScalarData.linearIndex(x: x, y: y, z: z, dimensions: dimensions)
                    output[index] = allNeighborsForeground(foreground, dimensions: dimensions, x: x, y: y, z: z)
                }
            }
        }
        return output
    }

    func hasForegroundNeighbor(_ foreground: [Bool],
                               dimensions: VolumeDimensions,
                               x: Int,
                               y: Int,
                               z: Int) -> Bool {
        for neighborZ in (z - radius)...(z + radius) {
            for neighborY in (y - radius)...(y + radius) {
                for neighborX in (x - radius)...(x + radius)
                    where isInside(dimensions, x: neighborX, y: neighborY, z: neighborZ) {
                    let index = VolumePipelineScalarData.linearIndex(x: neighborX,
                                                                     y: neighborY,
                                                                     z: neighborZ,
                                                                     dimensions: dimensions)
                    if foreground[index] {
                        return true
                    }
                }
            }
        }
        return false
    }

    func allNeighborsForeground(_ foreground: [Bool],
                                dimensions: VolumeDimensions,
                                x: Int,
                                y: Int,
                                z: Int) -> Bool {
        for neighborZ in (z - radius)...(z + radius) {
            for neighborY in (y - radius)...(y + radius) {
                for neighborX in (x - radius)...(x + radius) {
                    guard isInside(dimensions, x: neighborX, y: neighborY, z: neighborZ) else {
                        continue
                    }
                    let index = VolumePipelineScalarData.linearIndex(x: neighborX,
                                                                     y: neighborY,
                                                                     z: neighborZ,
                                                                     dimensions: dimensions)
                    guard foreground[index] else {
                        return false
                    }
                }
            }
        }
        return true
    }

    func isInside(_ dimensions: VolumeDimensions, x: Int, y: Int, z: Int) -> Bool {
        x >= 0 && y >= 0 && z >= 0 &&
            x < dimensions.width && y < dimensions.height && z < dimensions.depth
    }
}
