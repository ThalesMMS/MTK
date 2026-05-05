//
//  VolumeThresholdFilter.swift
//  MTKCore
//
//  CPU threshold filter for scalar volume datasets.
//

import Foundation

public enum VolumeThresholdMode: Sendable, Equatable {
    /// Preserve samples inside the threshold range and replace samples outside it.
    case keepInside

    /// Preserve samples outside the threshold range and replace samples inside it.
    case keepOutside
}

public struct VolumeThresholdFilter: VolumeDatasetFilter, Sendable, Equatable {
    public let executionPolicy: VolumeFilterExecutionPolicy = .cpu
    public var range: ClosedRange<Int32>
    public var replacementValue: Int32
    public var mode: VolumeThresholdMode

    public init(range: ClosedRange<Int32>,
                replacementValue: Int32,
                mode: VolumeThresholdMode = .keepInside) {
        self.range = range
        self.replacementValue = replacementValue
        self.mode = mode
    }

    public func apply(to dataset: VolumeDataset) async throws -> VolumeDataset {
        try VolumePipelineScalarData.validate(dataset)
        try VolumePipelineScalarData.validateReplacementValue(replacementValue,
                                                              pixelFormat: dataset.pixelFormat)

        let input = try VolumePipelineScalarData.decodedScalars(from: dataset)
        let output = input.map { value in
            let containsValue = range.contains(value)
            switch mode {
            case .keepInside:
                return containsValue ? value : replacementValue
            case .keepOutside:
                return containsValue ? replacementValue : value
            }
        }

        var imageData = dataset.imageData
        imageData.intensityRange = VolumePipelineScalarData.recomputeIntensityRange(output)

        return VolumeDataset(data: try VolumePipelineScalarData.encodedData(from: output,
                                                                            pixelFormat: dataset.pixelFormat),
                             imageData: imageData)
    }
}
