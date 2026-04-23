//
//  ClinicalProfiler.swift
//  MTK
//
//  Session-based clinical performance profiler.
//

import Foundation
@preconcurrency import Metal

public final class ClinicalProfiler: @unchecked Sendable {
    public static let shared = ClinicalProfiler()

    private let lock = NSLock()
    private var activeSession: ProfilingSession?

    private init() {}

    @discardableResult
    public func startSession(device: any MTLDevice) -> UUID {
        startSession(environment: ProfilingEnvironment.current(device: device))
    }

    @discardableResult
    public func startSession(environment: ProfilingEnvironment) -> UUID {
        lock.lock()
        defer { lock.unlock() }

        let session = ProfilingSession(environment: environment)
        activeSession = session
        return session.sessionID
    }

    public func recordSample(stage: ProfilingStage,
                             cpuTime: Double,
                             gpuTime: Double? = nil,
                             memory: Int? = nil,
                             viewport: ProfilingViewportContext = .unknown,
                             routeName: String? = nil,
                             metadata: [String: String]? = nil,
                             device: (any MTLDevice)? = nil) {
        let mergedMetadata = Self.mergedMetadata(metadata, routeName: routeName)
        recordSample(
            ProfilingSample(stageType: stage,
                            cpuTimeMilliseconds: cpuTime,
                            gpuTimeMilliseconds: gpuTime,
                            memoryEstimateBytes: memory,
                            viewportContext: viewport,
                            metadata: mergedMetadata),
            environment: device.map { ProfilingEnvironment.current(device: $0) }
        )
    }

    public func recordSample(_ sample: ProfilingSample,
                             environment: ProfilingEnvironment? = nil) {
        lock.lock()
        defer { lock.unlock() }

        ensureSessionLocked(environment: environment)
        activeSession?.addSample(sample)
    }

    public func endSession() -> ProfilingSession {
        lock.lock()
        defer { lock.unlock() }

        guard var session = activeSession else {
            var empty = ProfilingSession(environment: .unknown)
            empty.finalize()
            return empty
        }

        session.finalize()
        activeSession = nil
        return session
    }

    public func sessionSnapshot() -> ProfilingSession? {
        lock.lock()
        defer { lock.unlock() }
        return activeSession
    }

    public func reset(environment: ProfilingEnvironment = .unknown) {
        lock.lock()
        defer { lock.unlock() }

        activeSession = ProfilingSession(environment: environment)
    }

    public func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let session = sessionSnapshot() ?? ProfilingSession(environment: .unknown)
        return try session.jsonData(prettyPrinted: prettyPrinted)
    }

    public func csvData() -> Data {
        let session = sessionSnapshot() ?? ProfilingSession(environment: .unknown)
        return session.csvData()
    }

    func recordMemorySnapshot(from resourceManager: VolumeResourceManager,
                              viewport: ProfilingViewportContext = .unknown,
                              metadata: [String: String] = [:]) {
        // VolumeResourceManager.resourceMetrics() is a best-effort diagnostic snapshot.
        // It may observe slightly inconsistent counts during concurrent rendering; adding
        // synchronization here would put profiler reads on the render hot path.
        let metrics = resourceManager.resourceMetrics()
        var mergedMetadata = metadata
        mergedMetadata["volumeTextureCount"] = String(metrics.volumeTextureCount)
        mergedMetadata["transferTextureCount"] = String(metrics.transferTextureCount)
        mergedMetadata["outputTexturePoolSize"] = String(metrics.outputTexturePoolSize)
        mergedMetadata["volumeTextureBytes"] = String(metrics.breakdown.volumeTextures)
        mergedMetadata["transferTextureBytes"] = String(metrics.breakdown.transferTextures)
        mergedMetadata["outputTextureBytes"] = String(metrics.breakdown.outputTextures)
        mergedMetadata["totalBytes"] = String(metrics.breakdown.total)
        if let uploadPeakMemoryBytes = metrics.uploadPeakMemoryBytes {
            mergedMetadata["uploadPeakMemoryBytes"] = String(uploadPeakMemoryBytes)
        }

        recordSample(stage: .memorySnapshot,
                     cpuTime: 0,
                     memory: metrics.estimatedMemoryBytes,
                     viewport: viewport,
                     metadata: mergedMetadata)
    }

    public static func milliseconds(from start: CFAbsoluteTime,
                                    to end: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Double {
        max(0, (end - start) * 1000.0)
    }

    private func ensureSessionLocked(environment: ProfilingEnvironment?) {
        if activeSession == nil {
            activeSession = ProfilingSession(environment: environment ?? .unknown)
        }
    }

    private static func mergedMetadata(_ metadata: [String: String]?,
                                       routeName: String?) -> [String: String]? {
        guard routeName != nil || metadata != nil else {
            return nil
        }
        var merged = metadata ?? [:]
        if let routeName {
            merged["routeName"] = routeName
        }
        return merged
    }
}
