//
//  VolumeHistogramFilter.swift
//  MTKCore
//
//  CPU analysis filters for scalar volume histograms.
//

import Foundation

public struct VolumeHistogramFilter: VolumeAnalysisFilter, Sendable, Equatable {
    public let executionPolicy: VolumeFilterExecutionPolicy = .cpu
    public var descriptor: VolumeHistogramDescriptor

    public init(descriptor: VolumeHistogramDescriptor) {
        self.descriptor = descriptor
    }

    public func analyze(_ dataset: VolumeDataset) async throws -> VolumeHistogram {
        guard descriptor.binCount > 0 else {
            throw VolumePipelineError.invalidHistogramBinCount
        }

        let scalars = try VolumePipelineScalarData.decodedScalars(from: dataset)
        var bins = [Float](repeating: 0, count: descriptor.binCount)
        for scalar in scalars {
            let index = try VolumePipelineHistogramBinner.binIndex(value: Float(scalar),
                                                                  range: descriptor.intensityRange,
                                                                  binCount: descriptor.binCount)
            bins[index] += 1
        }

        if descriptor.normalize {
            VolumePipelineHistogramBinner.normalize(&bins)
        }

        return VolumeHistogram(descriptor: descriptor, bins: bins)
    }
}

public struct VolumeGradientHistogramDescriptor: Sendable, Equatable {
    public var intensityBinCount: Int
    public var gradientBinCount: Int
    public var intensityRange: ClosedRange<Float>
    public var gradientRange: ClosedRange<Float>
    public var normalize: Bool

    public init(intensityBinCount: Int,
                gradientBinCount: Int,
                intensityRange: ClosedRange<Float>,
                gradientRange: ClosedRange<Float>,
                normalize: Bool = false) {
        self.intensityBinCount = intensityBinCount
        self.gradientBinCount = gradientBinCount
        self.intensityRange = intensityRange
        self.gradientRange = gradientRange
        self.normalize = normalize
    }
}

public struct VolumeGradientHistogram: Sendable, Equatable {
    public var descriptor: VolumeGradientHistogramDescriptor
    public var bins: [[Float]]

    public init(descriptor: VolumeGradientHistogramDescriptor,
                bins: [[Float]]) {
        self.descriptor = descriptor
        self.bins = bins
    }
}

public struct VolumeGradientHistogramFilter: VolumeAnalysisFilter, Sendable, Equatable {
    public let executionPolicy: VolumeFilterExecutionPolicy = .cpu
    public var descriptor: VolumeGradientHistogramDescriptor

    public init(descriptor: VolumeGradientHistogramDescriptor) {
        self.descriptor = descriptor
    }

    public func analyze(_ dataset: VolumeDataset) async throws -> VolumeGradientHistogram {
        guard descriptor.intensityBinCount > 0, descriptor.gradientBinCount > 0 else {
            throw VolumePipelineError.invalidHistogramBinCount
        }
        try VolumePipelineScalarData.validateSpacing(dataset.spacing)

        let scalars = try VolumePipelineScalarData.decodedScalars(from: dataset)
        var bins = Array(
            repeating: [Float](repeating: 0, count: descriptor.gradientBinCount),
            count: descriptor.intensityBinCount
        )

        for z in 0..<dataset.dimensions.depth {
            for y in 0..<dataset.dimensions.height {
                for x in 0..<dataset.dimensions.width {
                    let value = scalar(scalars, dataset: dataset, x: x, y: y, z: z)
                    let magnitude = gradientMagnitude(scalars, dataset: dataset, x: x, y: y, z: z)
                    let intensityBin = try VolumePipelineHistogramBinner.binIndex(
                        value: value,
                        range: descriptor.intensityRange,
                        binCount: descriptor.intensityBinCount
                    )
                    let gradientBin = try VolumePipelineHistogramBinner.binIndex(
                        value: magnitude,
                        range: descriptor.gradientRange,
                        binCount: descriptor.gradientBinCount
                    )
                    bins[intensityBin][gradientBin] += 1
                }
            }
        }

        if descriptor.normalize {
            VolumePipelineHistogramBinner.normalize(&bins)
        }

        return VolumeGradientHistogram(descriptor: descriptor, bins: bins)
    }
}

private extension VolumeGradientHistogramFilter {
    func gradientMagnitude(_ scalars: [Int32],
                           dataset: VolumeDataset,
                           x: Int,
                           y: Int,
                           z: Int) -> Float {
        let dx = finiteDifference(scalars,
                                  dataset: dataset,
                                  x: x,
                                  y: y,
                                  z: z,
                                  axis: .x,
                                  spacing: Float(dataset.spacing.x))
        let dy = finiteDifference(scalars,
                                  dataset: dataset,
                                  x: x,
                                  y: y,
                                  z: z,
                                  axis: .y,
                                  spacing: Float(dataset.spacing.y))
        let dz = finiteDifference(scalars,
                                  dataset: dataset,
                                  x: x,
                                  y: y,
                                  z: z,
                                  axis: .z,
                                  spacing: Float(dataset.spacing.z))
        return sqrt(dx * dx + dy * dy + dz * dz)
    }

    func finiteDifference(_ scalars: [Int32],
                          dataset: VolumeDataset,
                          x: Int,
                          y: Int,
                          z: Int,
                          axis: GradientAxis,
                          spacing: Float) -> Float {
        let dimensions = dataset.dimensions
        let maximumIndex: Int
        switch axis {
        case .x:
            maximumIndex = dimensions.width - 1
        case .y:
            maximumIndex = dimensions.height - 1
        case .z:
            maximumIndex = dimensions.depth - 1
        }
        guard maximumIndex > 0 else { return 0 }

        let currentIndex = axis.value(x: x, y: y, z: z)
        if currentIndex == 0 {
            return (sampleOffset(scalars, dataset: dataset, x: x, y: y, z: z, axis: axis, delta: 1) -
                scalar(scalars, dataset: dataset, x: x, y: y, z: z)) / spacing
        }
        if currentIndex == maximumIndex {
            return (scalar(scalars, dataset: dataset, x: x, y: y, z: z) -
                sampleOffset(scalars, dataset: dataset, x: x, y: y, z: z, axis: axis, delta: -1)) / spacing
        }
        return (sampleOffset(scalars, dataset: dataset, x: x, y: y, z: z, axis: axis, delta: 1) -
            sampleOffset(scalars, dataset: dataset, x: x, y: y, z: z, axis: axis, delta: -1)) / (2 * spacing)
    }

    func sampleOffset(_ scalars: [Int32],
                      dataset: VolumeDataset,
                      x: Int,
                      y: Int,
                      z: Int,
                      axis: GradientAxis,
                      delta: Int) -> Float {
        switch axis {
        case .x:
            return scalar(scalars, dataset: dataset, x: x + delta, y: y, z: z)
        case .y:
            return scalar(scalars, dataset: dataset, x: x, y: y + delta, z: z)
        case .z:
            return scalar(scalars, dataset: dataset, x: x, y: y, z: z + delta)
        }
    }

    func scalar(_ scalars: [Int32],
                dataset: VolumeDataset,
                x: Int,
                y: Int,
                z: Int) -> Float {
        let index = VolumePipelineScalarData.linearIndex(x: x,
                                                         y: y,
                                                         z: z,
                                                         dimensions: dataset.dimensions)
        return Float(scalars[index])
    }
}

private enum GradientAxis {
    case x
    case y
    case z

    func value(x: Int, y: Int, z: Int) -> Int {
        switch self {
        case .x:
            return x
        case .y:
            return y
        case .z:
            return z
        }
    }
}
