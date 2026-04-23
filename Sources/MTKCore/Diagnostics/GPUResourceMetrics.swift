//
//  GPUResourceMetrics.swift
//  MTK
//
//  Aggregated GPU resource memory estimates for profiler diagnostics.
//

import Foundation

public struct ResourceMemoryBreakdown: Equatable, Sendable {
    public let volumeTextures: Int
    public let transferTextures: Int
    public let outputTextures: Int
    public let total: Int

    public init(volumeTextures: Int,
                transferTextures: Int,
                outputTextures: Int) {
        self.volumeTextures = volumeTextures
        self.transferTextures = transferTextures
        self.outputTextures = outputTextures
        self.total = volumeTextures + transferTextures + outputTextures
    }
}

public struct GPUResourceMetrics: Equatable, Sendable {
    public let estimatedMemoryBytes: Int
    public let volumeTextureCount: Int
    public let transferTextureCount: Int
    public let outputTexturePoolSize: Int
    public let uploadPeakMemoryBytes: Int?
    public let breakdown: ResourceMemoryBreakdown
    public let resources: [VolumeResourceHandle.Metadata]

    public init(estimatedMemoryBytes: Int,
                volumeTextureCount: Int,
                transferTextureCount: Int,
                outputTexturePoolSize: Int,
                uploadPeakMemoryBytes: Int? = nil,
                breakdown: ResourceMemoryBreakdown,
                resources: [VolumeResourceHandle.Metadata] = []) {
        self.estimatedMemoryBytes = estimatedMemoryBytes
        self.volumeTextureCount = volumeTextureCount
        self.transferTextureCount = transferTextureCount
        self.outputTexturePoolSize = outputTexturePoolSize
        self.uploadPeakMemoryBytes = uploadPeakMemoryBytes
        self.breakdown = breakdown
        self.resources = resources
    }
}
