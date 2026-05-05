//
//  VolumePipelineSupport.swift
//  MTKCore
//
//  Shared CPU helpers for volume pipeline filters.
//

import Foundation

public enum VolumePipelineError: Error, Equatable, LocalizedError {
    case invalidDimensions
    case invalidCropBounds
    case datasetReadFailed
    case scalarValueOutOfRange(value: Int32, pixelFormat: VolumePixelFormat)
    case invalidHistogramBinCount
    case invalidSpacing

    public var errorDescription: String? {
        switch self {
        case .invalidDimensions:
            return "Invalid volume dimensions"
        case .invalidCropBounds:
            return "Invalid crop bounds"
        case .datasetReadFailed:
            return "Dataset read failed"
        case .scalarValueOutOfRange(let value, let pixelFormat):
            return "Scalar value \(value) is outside \(pixelFormat.scalarTypeDescription)"
        case .invalidHistogramBinCount:
            return "Invalid histogram bin count"
        case .invalidSpacing:
            return "Invalid volume spacing"
        }
    }

    public var failureReason: String? {
        switch self {
        case .invalidDimensions:
            return "Volume dimensions must be positive and fit the dataset buffer."
        case .invalidCropBounds:
            return "Crop bounds must be non-negative, ordered, and inside the dataset dimensions."
        case .datasetReadFailed:
            return "The dataset buffer could not be decoded as the declared pixel format."
        case .scalarValueOutOfRange:
            return "The replacement or resampled scalar cannot be represented by the dataset pixel format."
        case .invalidHistogramBinCount:
            return "Histogram bin counts must be greater than zero."
        case .invalidSpacing:
            return "Spacing values must be finite and greater than zero."
        }
    }
}

enum VolumePipelineScalarData {
    static func decodedScalars(from dataset: VolumeDataset) throws -> [Int32] {
        try validate(dataset)
        switch dataset.pixelFormat {
        case .int16Signed:
            return try dataset.data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    throw VolumePipelineError.datasetReadFailed
                }
                let pointer = baseAddress.assumingMemoryBound(to: Int16.self)
                let values = UnsafeBufferPointer(start: pointer, count: dataset.voxelCount)
                return values.map(Int32.init)
            }
        case .int16Unsigned:
            return try dataset.data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    throw VolumePipelineError.datasetReadFailed
                }
                let pointer = baseAddress.assumingMemoryBound(to: UInt16.self)
                let values = UnsafeBufferPointer(start: pointer, count: dataset.voxelCount)
                return values.map(Int32.init)
            }
        }
    }

    static func encodedData(from scalars: [Int32],
                            pixelFormat: VolumePixelFormat) throws -> Data {
        switch pixelFormat {
        case .int16Signed:
            let values = try scalars.map { value in
                guard value >= Int32(Int16.min), value <= Int32(Int16.max) else {
                    throw VolumePipelineError.scalarValueOutOfRange(value: value,
                                                                    pixelFormat: pixelFormat)
                }
                return Int16(value)
            }
            return values.withUnsafeBytes { Data($0) }
        case .int16Unsigned:
            let values = try scalars.map { value in
                guard value >= Int32(UInt16.min), value <= Int32(UInt16.max) else {
                    throw VolumePipelineError.scalarValueOutOfRange(value: value,
                                                                    pixelFormat: pixelFormat)
                }
                return UInt16(value)
            }
            return values.withUnsafeBytes { Data($0) }
        }
    }

    static func validateReplacementValue(_ value: Int32,
                                         pixelFormat: VolumePixelFormat) throws {
        _ = try encodedData(from: [value], pixelFormat: pixelFormat)
    }

    static func recomputeIntensityRange(_ scalars: [Int32]) -> ClosedRange<Int32> {
        guard let first = scalars.first else { return 0...0 }
        var minimum = first
        var maximum = first
        for value in scalars.dropFirst() {
            minimum = min(minimum, value)
            maximum = max(maximum, value)
        }
        return minimum...maximum
    }

    static func linearIndex(x: Int, y: Int, z: Int, dimensions: VolumeDimensions) -> Int {
        z * dimensions.width * dimensions.height + y * dimensions.width + x
    }

    static func validate(_ dataset: VolumeDataset) throws {
        try validateDimensions(dataset.dimensions)
        let (expectedByteCount, overflow) = dataset.voxelCount.multipliedReportingOverflow(
            by: dataset.pixelFormat.bytesPerVoxel
        )
        guard !overflow, dataset.data.count >= expectedByteCount else {
            throw VolumePipelineError.datasetReadFailed
        }
    }

    static func validateDimensions(_ dimensions: VolumeDimensions) throws {
        guard dimensions.width > 0, dimensions.height > 0, dimensions.depth > 0 else {
            throw VolumePipelineError.invalidDimensions
        }
        let (area, areaOverflow) = dimensions.width.multipliedReportingOverflow(by: dimensions.height)
        let (_, voxelOverflow) = area.multipliedReportingOverflow(by: dimensions.depth)
        guard !areaOverflow, !voxelOverflow else {
            throw VolumePipelineError.invalidDimensions
        }
    }

    static func validateSpacing(_ spacing: VolumeSpacing) throws {
        guard spacing.x.isFinite, spacing.y.isFinite, spacing.z.isFinite,
              spacing.x > 0, spacing.y > 0, spacing.z > 0 else {
            throw VolumePipelineError.invalidSpacing
        }
    }
}

enum VolumePipelineHistogramBinner {
    static func binIndex(value: Float,
                         range: ClosedRange<Float>,
                         binCount: Int) throws -> Int {
        guard binCount > 0 else {
            throw VolumePipelineError.invalidHistogramBinCount
        }
        let lower = range.lowerBound
        let upper = range.upperBound
        let clamped = VolumetricMath.clampFloat(value, lower: lower, upper: upper)
        let span = max(upper - lower, Float.leastNonzeroMagnitude)
        let binWidth = span / Float(binCount)
        let rawIndex = Int((clamped - lower) / binWidth)
        return min(max(rawIndex, 0), binCount - 1)
    }

    static func normalize(_ bins: inout [Float]) {
        let total = bins.reduce(0, +)
        guard total > 0 else { return }
        for index in bins.indices {
            bins[index] /= total
        }
    }

    static func normalize(_ bins: inout [[Float]]) {
        let total = bins.reduce(Float(0)) { partial, row in
            partial + row.reduce(0, +)
        }
        guard total > 0 else { return }
        for rowIndex in bins.indices {
            for columnIndex in bins[rowIndex].indices {
                bins[rowIndex][columnIndex] /= total
            }
        }
    }
}
