//
//  VolumeUploadProgress.swift
//  MTK
//
//  Progress and metric types for chunked GPU volume upload.
//

import Foundation

public typealias VolumeUploadProgressHandler = @MainActor @Sendable (VolumeUploadProgress) -> Void

public struct VolumeUploadMetrics: Sendable, Equatable {
    public let uploadTimeSeconds: Double
    public let peakMemoryBytes: Int
    public let slicesProcessed: Int

    public init(uploadTimeSeconds: Double,
                peakMemoryBytes: Int,
                slicesProcessed: Int) {
        self.uploadTimeSeconds = uploadTimeSeconds
        self.peakMemoryBytes = peakMemoryBytes
        self.slicesProcessed = slicesProcessed
    }
}

public enum VolumeUploadProgress: Sendable, Equatable {
    case started(totalSlices: Int)
    case uploadingSlice(current: Int, total: Int)
    case processingHistogram
    case completed(metrics: VolumeUploadMetrics)
}

public struct VolumeUploadSlice: Sendable, Equatable {
    public let index: Int
    public let data: Data
    public let slope: Double
    public let intercept: Double
    public let minClamp: Int32
    public let maxClamp: Int32

    public init(index: Int,
                data: Data,
                slope: Double = 1,
                intercept: Double = 0,
                minClamp: Int32 = Int32(Int16.min),
                maxClamp: Int32 = Int32(Int16.max)) {
        self.index = index
        self.data = data
        self.slope = slope
        self.intercept = intercept
        self.minClamp = minClamp
        self.maxClamp = maxClamp
    }
}

public struct VolumeUploadDescriptor: Sendable, Equatable {
    public let dimensions: VolumeDimensions
    public let spacing: VolumeSpacing
    public let sourcePixelFormat: VolumePixelFormat
    public let intensityRange: ClosedRange<Int32>
    public let orientation: VolumeOrientation
    public let recommendedWindow: ClosedRange<Int32>?
    public let cacheKey: String?

    public init(dimensions: VolumeDimensions,
                spacing: VolumeSpacing,
                sourcePixelFormat: VolumePixelFormat,
                intensityRange: ClosedRange<Int32>? = nil,
                orientation: VolumeOrientation = .canonical,
                recommendedWindow: ClosedRange<Int32>? = nil,
                cacheKey: String? = nil) {
        self.dimensions = dimensions
        self.spacing = spacing
        self.sourcePixelFormat = sourcePixelFormat
        self.intensityRange = intensityRange ?? Int32(Int16.min)...Int32(Int16.max)
        self.orientation = orientation
        self.recommendedWindow = recommendedWindow
        self.cacheKey = cacheKey
    }
}
