//
//  ThreadgroupPipelineLimits.swift
//  MTK
//
//  Describes compute-pipeline limits used to derive dispatch configurations.
//

import Metal

@_spi(Testing) public struct ThreadgroupPipelineLimits {
    public let threadExecutionWidth: Int
    public let maxTotalThreadsPerThreadgroup: Int

    public init(threadExecutionWidth: Int, maxTotalThreadsPerThreadgroup: Int) {
        self.threadExecutionWidth = threadExecutionWidth
        self.maxTotalThreadsPerThreadgroup = maxTotalThreadsPerThreadgroup
    }

    public init(pipeline: MTLComputePipelineState) {
        self.init(threadExecutionWidth: pipeline.threadExecutionWidth,
                  maxTotalThreadsPerThreadgroup: pipeline.maxTotalThreadsPerThreadgroup)
    }
}
