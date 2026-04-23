//
//  HUConversionPipeline.swift
//  MTK
//
//  Metal compute pipeline for per-slice HU conversion during chunked upload.
//

import Foundation
@preconcurrency import Metal

public enum HUConversionPipelineError: Error, Equatable {
    case functionUnavailable(String)
    case commandEncoderCreationFailed
}

public struct HUConversionParameters: Sendable, Equatable {
    public var slope: Float
    public var intercept: Float
    public var minClamp: Int32
    public var maxClamp: Int32
    public var sliceIndex: UInt32
    public var sliceWidth: UInt32
    public var sliceHeight: UInt32
    public var padding: UInt32

    public init(slope: Float,
                intercept: Float,
                minClamp: Int32,
                maxClamp: Int32,
                sliceIndex: UInt32,
                sliceWidth: UInt32,
                sliceHeight: UInt32) {
        self.slope = slope
        self.intercept = intercept
        self.minClamp = minClamp
        self.maxClamp = maxClamp
        self.sliceIndex = sliceIndex
        self.sliceWidth = sliceWidth
        self.sliceHeight = sliceHeight
        self.padding = 0
    }
}

public final class HUConversionPipeline {
    private let signedPipeline: any MTLComputePipelineState
    private let unsignedPipeline: any MTLComputePipelineState

    public init(device: any MTLDevice,
                library: (any MTLLibrary)? = nil) throws {
        let resolvedLibrary = try library ?? ShaderLibraryLoader.loadLibrary(for: device)

        guard let signedFunction = resolvedLibrary.makeFunction(name: "convertHUSlice") else {
            throw HUConversionPipelineError.functionUnavailable("convertHUSlice")
        }
        guard let unsignedFunction = resolvedLibrary.makeFunction(name: "convertHUSliceUnsigned") else {
            throw HUConversionPipelineError.functionUnavailable("convertHUSliceUnsigned")
        }

        signedPipeline = try device.makeComputePipelineState(function: signedFunction)
        unsignedPipeline = try device.makeComputePipelineState(function: unsignedFunction)
    }

    public func optimalThreadgroupSize(for pipeline: any MTLComputePipelineState) -> MTLSize {
        let maxThreads = max(1, pipeline.maxTotalThreadsPerThreadgroup)
        let width = min(4, maxThreads)
        let height = min(4, max(1, maxThreads / width))
        return MTLSize(width: width, height: height, depth: 1)
    }

    public func encode(stagingBuffer: any MTLBuffer,
                       to destination: any MTLTexture,
                       sourcePixelFormat: VolumePixelFormat,
                       params: HUConversionParameters,
                       commandBuffer: any MTLCommandBuffer) throws {
        let pipeline: any MTLComputePipelineState
        switch sourcePixelFormat {
        case .int16Signed:
            pipeline = signedPipeline
        case .int16Unsigned:
            pipeline = unsignedPipeline
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw HUConversionPipelineError.commandEncoderCreationFailed
        }
        encoder.label = "HUConversionPipeline.convertSlice"
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(stagingBuffer, offset: 0, index: 0)
        encoder.setTexture(destination, index: 0)

        var mutableParams = params
        encoder.setBytes(&mutableParams,
                         length: MemoryLayout<HUConversionParameters>.stride,
                         index: 1)

        let threadsPerThreadgroup = optimalThreadgroupSize(for: pipeline)
        let threadgroups = MTLSize(
            width: Int((params.sliceWidth + UInt32(threadsPerThreadgroup.width) - 1) / UInt32(threadsPerThreadgroup.width)),
            height: Int((params.sliceHeight + UInt32(threadsPerThreadgroup.height) - 1) / UInt32(threadsPerThreadgroup.height)),
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups,
                                     threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
    }
}
