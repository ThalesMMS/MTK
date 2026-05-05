//
//  VolumePipeline.swift
//  MTKCore
//
//  Public VTK-like volume pipeline contracts for source/filter/mapper flows.
//

import Foundation

/// Execution backend used by a volume pipeline stage.
public enum VolumeFilterExecutionPolicy: Sendable, Equatable {
    /// Deterministic CPU implementation. V1 pipeline filters use this policy so
    /// they remain testable without UI or interactive rendering.
    case cpu

    /// Metal compute implementation. Reserved for GPU-backed pipeline stages.
    case metalCompute
}

/// Source stage that produces a structured volume dataset.
public protocol VolumeSource: Sendable {
    func volumeDataset() async throws -> VolumeDataset
}

/// Source that wraps an existing ``VolumeDataset``.
public struct VolumeDatasetSource: VolumeSource, Sendable, Equatable {
    public var dataset: VolumeDataset

    public init(_ dataset: VolumeDataset) {
        self.dataset = dataset
    }

    public init(dataset: VolumeDataset) {
        self.dataset = dataset
    }

    public func volumeDataset() async throws -> VolumeDataset {
        dataset
    }
}

/// Dataset transform stage for volume-to-volume filters.
public protocol VolumeDatasetFilter: Sendable {
    var executionPolicy: VolumeFilterExecutionPolicy { get }
    func apply(to dataset: VolumeDataset) async throws -> VolumeDataset
}

/// Analysis stage for derived data such as histograms.
public protocol VolumeAnalysisFilter: Sendable {
    associatedtype Output: Sendable

    var executionPolicy: VolumeFilterExecutionPolicy { get }
    func analyze(_ dataset: VolumeDataset) async throws -> Output
}

/// Maps a filtered dataset into MTK's existing Metal-native rendering contract.
public protocol VolumeMapper: Sendable {
    func map(_ dataset: VolumeDataset) async throws -> MappedVolume
}

/// Dataset plus rendering defaults ready for MTKCore/MTKUI viewports.
public struct MappedVolume: Sendable, Equatable {
    public var dataset: VolumeDataset
    public var transferFunction: VolumeTransferFunction
    public var recommendedWindow: ClosedRange<Int32>?
    public var primaryLayer: VolumeLayer

    public init(dataset: VolumeDataset,
                transferFunction: VolumeTransferFunction,
                recommendedWindow: ClosedRange<Int32>?,
                primaryLayer: VolumeLayer) {
        self.dataset = dataset
        self.transferFunction = transferFunction
        self.recommendedWindow = recommendedWindow
        self.primaryLayer = primaryLayer
    }
}

/// Default mapper that keeps rendering on the existing Metal-native path.
public struct DefaultVolumeMapper: VolumeMapper, Sendable, Equatable {
    public var transferFunction: VolumeTransferFunction?

    public init(transferFunction: VolumeTransferFunction? = nil) {
        self.transferFunction = transferFunction
    }

    public func map(_ dataset: VolumeDataset) async throws -> MappedVolume {
        let resolvedTransferFunction = transferFunction ?? .defaultGrayscale(for: dataset)
        let layer = VolumeLayer(id: VolumeRenderRequest.primaryVolumeLayerID,
                                dataset: dataset,
                                transferFunction: resolvedTransferFunction)
        return MappedVolume(dataset: dataset,
                            transferFunction: resolvedTransferFunction,
                            recommendedWindow: dataset.recommendedWindow,
                            primaryLayer: layer)
    }
}

/// Minimal source-filter-mapper pipeline for volume data.
public struct VolumePipeline: Sendable {
    public var source: any VolumeSource
    public var filters: [any VolumeDatasetFilter]
    public var mapper: any VolumeMapper

    public init(source: any VolumeSource,
                filters: [any VolumeDatasetFilter] = [],
                mapper: any VolumeMapper = DefaultVolumeMapper()) {
        self.source = source
        self.filters = filters
        self.mapper = mapper
    }

    public func dataset() async throws -> VolumeDataset {
        var current = try await source.volumeDataset()
        for filter in filters {
            current = try await filter.apply(to: current)
        }
        return current
    }

    public func mappedVolume() async throws -> MappedVolume {
        let finalDataset = try await dataset()
        return try await mapper.map(finalDataset)
    }

    public func analyze<Filter: VolumeAnalysisFilter>(_ filter: Filter) async throws -> Filter.Output {
        try await filter.analyze(dataset())
    }
}
