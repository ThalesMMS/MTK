//
//  ThreadgroupDispatchConfiguration.swift
//  MTK
//
//  Defines threadgroup configurations derived from compute pipeline limits.
//
//  Thales Matheus Mendonça Santos — October 2025

import Metal

@_spi(Testing) public struct ThreadgroupDispatchConfiguration: Hashable, CustomStringConvertible {
    public let width: Int
    public let height: Int

    public var description: String { "\(width)x\(height)" }

    public var threadCount: Int { width * height }

    public var threadsPerThreadgroup: MTLSize {
        MTLSize(width: width, height: height, depth: 1)
    }

    public func threadgroupsPerGrid(forWidth width: Int, height: Int) -> MTLSize {
        let groupsX = max(1, (width + self.width - 1) / self.width)
        let groupsY = max(1, (height + self.height - 1) / self.height)
        return MTLSize(width: groupsX, height: groupsY, depth: 1)
    }

    public func clamped(to pipeline: MTLComputePipelineState) -> ThreadgroupDispatchConfiguration? {
        clamped(to: ThreadgroupPipelineLimits(pipeline: pipeline))
    }

    public func clamped(to limits: ThreadgroupPipelineLimits) -> ThreadgroupDispatchConfiguration? {
        let maxThreads = max(1, limits.maxTotalThreadsPerThreadgroup)
        let clampedWidth = max(1, min(width, min(maxThreads, 1024)))
        let maxHeight = maxThreads / clampedWidth
        guard maxHeight > 0 else { return nil }
        let clampedHeight = max(1, min(height, min(maxHeight, 1024)))
        return ThreadgroupDispatchConfiguration(width: clampedWidth, height: clampedHeight)
    }

    public static func `default`(for pipeline: MTLComputePipelineState) -> ThreadgroupDispatchConfiguration {
        self.default(for: ThreadgroupPipelineLimits(pipeline: pipeline))
    }

    public static func `default`(for limits: ThreadgroupPipelineLimits) -> ThreadgroupDispatchConfiguration {
        let width = max(1, min(limits.threadExecutionWidth, 1024))
        let maxThreads = max(1, limits.maxTotalThreadsPerThreadgroup)
        let height = max(1, min(maxThreads / width, 1024))
        return ThreadgroupDispatchConfiguration(width: width, height: height)
    }

    public static func candidates(for pipeline: MTLComputePipelineState) -> [ThreadgroupDispatchConfiguration] {
        candidates(for: ThreadgroupPipelineLimits(pipeline: pipeline))
    }

    public static func candidates(for limits: ThreadgroupPipelineLimits) -> [ThreadgroupDispatchConfiguration] {
        let presets: [ThreadgroupDispatchConfiguration] = [
            .default(for: limits),
            ThreadgroupDispatchConfiguration(width: 8, height: 8),
            ThreadgroupDispatchConfiguration(width: 16, height: 8),
            ThreadgroupDispatchConfiguration(width: 16, height: 16),
            ThreadgroupDispatchConfiguration(width: 32, height: 4)
        ]

        var unique = Set<ThreadgroupDispatchConfiguration>()
        var results: [ThreadgroupDispatchConfiguration] = []

        for preset in presets {
            guard let adjusted = preset.clamped(to: limits) else {
                continue
            }

            if unique.insert(adjusted).inserted {
                results.append(adjusted)
            }
        }

        return results
    }
}
