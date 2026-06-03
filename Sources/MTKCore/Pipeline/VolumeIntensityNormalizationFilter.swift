//
//  VolumeIntensityNormalizationFilter.swift
//  MTKCore
//
//  CPU intensity normalization filter for scalar volume datasets.
//

import Foundation

public struct VolumeIntensityNormalizationFilter: VolumeDatasetFilter, Sendable, Equatable {
    public let executionPolicy: VolumeFilterExecutionPolicy = .cpu
    public var sourceRange: ClosedRange<Int32>?
    public var targetRange: ClosedRange<Int32>

    public init(sourceRange: ClosedRange<Int32>? = nil,
                targetRange: ClosedRange<Int32>) {
        self.sourceRange = sourceRange
        self.targetRange = targetRange
    }

    public func apply(to dataset: VolumeDataset) async throws -> VolumeDataset {
        try VolumePipelineScalarData.validate(dataset)
        try VolumePipelineScalarData.validateReplacementValue(targetRange.lowerBound,
                                                              pixelFormat: dataset.pixelFormat)
        try VolumePipelineScalarData.validateReplacementValue(targetRange.upperBound,
                                                              pixelFormat: dataset.pixelFormat)

        let resolvedSourceRange = sourceRange ?? dataset.intensityRange
        try validate(range: resolvedSourceRange)
        try validate(range: targetRange)

        let scalars = try VolumePipelineScalarData.decodedScalars(from: dataset)
        let output = scalars.map { scalar in
            normalize(scalar, sourceRange: resolvedSourceRange, targetRange: targetRange)
        }

        var imageData = dataset.imageData
        imageData.intensityRange = VolumePipelineScalarData.recomputeIntensityRange(output)
        if let recommendedWindow = dataset.recommendedWindow {
            let lower = normalize(recommendedWindow.lowerBound,
                                  sourceRange: resolvedSourceRange,
                                  targetRange: targetRange)
            let upper = normalize(recommendedWindow.upperBound,
                                  sourceRange: resolvedSourceRange,
                                  targetRange: targetRange)
            imageData.recommendedWindow = min(lower, upper)...max(lower, upper)
        }

        return VolumeDataset(data: try VolumePipelineScalarData.encodedData(from: output,
                                                                            pixelFormat: dataset.pixelFormat),
                             imageData: imageData)
    }
}

private extension VolumeIntensityNormalizationFilter {
    func validate(range: ClosedRange<Int32>) throws {
        guard range.lowerBound < range.upperBound else {
            throw VolumePipelineError.invalidIntensityRange
        }
    }

    func normalize(_ scalar: Int32,
                   sourceRange: ClosedRange<Int32>,
        targetRange: ClosedRange<Int32>) -> Int32 {
        let clampedScalar = min(max(scalar, sourceRange.lowerBound), sourceRange.upperBound)
        let sourceSpan = Double(sourceRange.upperBound) - Double(sourceRange.lowerBound)
        let targetSpan = Double(targetRange.upperBound) - Double(targetRange.lowerBound)
        let normalized = (Double(clampedScalar) - Double(sourceRange.lowerBound)) / sourceSpan
        let mapped = Double(targetRange.lowerBound) + normalized * targetSpan
        return Int32(mapped.rounded(.toNearestOrAwayFromZero))
    }
}
