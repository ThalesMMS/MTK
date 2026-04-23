//
//  ProfilingSample.swift
//  MTK
//
//  Clinical profiling data model.
//

import Foundation

public enum ProfilingStage: String, CaseIterable, Codable, Sendable {
    case dicomParse
    case huConversion
    case renderGraphRoute
    case textureUpload
    case texturePreparation
    case mprReslice
    case volumeRaycast
    case presentationPass
    case snapshotReadback
    case memorySnapshot
}

public struct ProfilingViewportContext: Codable, Equatable, Sendable {
    public var resolutionWidth: Int
    public var resolutionHeight: Int
    public var viewportType: String
    public var quality: String
    public var renderMode: String

    public init(resolutionWidth: Int,
                resolutionHeight: Int,
                viewportType: String,
                quality: String,
                renderMode: String) {
        self.resolutionWidth = max(0, resolutionWidth)
        self.resolutionHeight = max(0, resolutionHeight)
        self.viewportType = viewportType
        self.quality = quality
        self.renderMode = renderMode
    }

    public static let unknown = ProfilingViewportContext(
        resolutionWidth: 0,
        resolutionHeight: 0,
        viewportType: "unknown",
        quality: "unknown",
        renderMode: "unknown"
    )
}

public struct ProfilingSample: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var stageType: ProfilingStage
    public var cpuTimeMilliseconds: Double
    public var gpuTimeMilliseconds: Double?
    public var memoryEstimateBytes: Int?
    public var viewportContext: ProfilingViewportContext
    public var metadata: [String: String]?

    public init(timestamp: Date = Date(),
                stageType: ProfilingStage,
                cpuTimeMilliseconds: Double,
                gpuTimeMilliseconds: Double? = nil,
                memoryEstimateBytes: Int? = nil,
                viewportContext: ProfilingViewportContext = .unknown,
                metadata: [String: String]? = nil) {
        self.timestamp = timestamp
        self.stageType = stageType
        self.cpuTimeMilliseconds = max(0, cpuTimeMilliseconds)
        self.gpuTimeMilliseconds = gpuTimeMilliseconds.map { max(0, $0) }
        self.memoryEstimateBytes = memoryEstimateBytes
        self.viewportContext = viewportContext
        self.metadata = metadata?.isEmpty == true ? nil : metadata
    }
}
