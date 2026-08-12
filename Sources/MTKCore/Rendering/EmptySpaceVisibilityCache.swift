import Foundation
import Metal
import simd

final class EmptySpaceVisibilityCache {
    enum CacheError: Error {
        case functionUnavailable
        case pipelineUnavailable
        case invalidMinMaxTexture
        case textureUnavailable
        case commandBufferUnavailable
        case commandEncoderUnavailable
        case textureViewUnavailable
        case skippingFlagBufferUnavailable
        case commandExecutionFailed
    }

    private struct Signature: Equatable {
        let resourceGeneration: UInt64
        let channelWeights: SIMD4<Float>
        let opacityThreshold: Float
        let voxelMinValue: Int32
        let voxelMaxValue: Int32
        let datasetMinValue: Int32
        let datasetMaxValue: Int32
        let densityFloor: Float
        let densityCeil: Float
        let gateHuMin: Int32
        let gateHuMax: Int32
        let useHuGate: Int32
    }

    private let device: any MTLDevice
    private let pipeline: any MTLComputePipelineState
    private let skippingFlagBuffer: any MTLBuffer
    private var cachedSignature: Signature?
    private var cachedTexture: (any MTLTexture)?
    private var cachedMinMaxSource: (any MTLTexture)?
    private var cachedTransferSource: (any MTLTexture)?
    private var resourceGeneration: UInt64 = 0

    private(set) var visibilityBuildCount = 0
    private(set) var isSkippingUseful = true

    init(device: any MTLDevice, library: any MTLLibrary) throws {
        let function = library.makeFunction(name: "computeEmptySpaceVisibility")
            ?? Self.makeRuntimeLibrary(device: device)?.makeFunction(name: "computeEmptySpaceVisibility")
        guard let function else {
            throw CacheError.functionUnavailable
        }
        guard let pipeline = try? device.makeComputePipelineState(function: function) else {
            throw CacheError.pipelineUnavailable
        }
        guard let skippingFlagBuffer = device.makeBuffer(
            length: MemoryLayout<UInt32>.stride,
            options: [.storageModeShared]
        ) else {
            throw CacheError.skippingFlagBufferUnavailable
        }
        self.device = device
        self.pipeline = pipeline
        self.skippingFlagBuffer = skippingFlagBuffer
    }

    private static func makeRuntimeLibrary(device: any MTLDevice) -> (any MTLLibrary)? {
        let sourceURL = Bundle.module.url(forResource: "empty_space_compute", withExtension: "metal")
            ?? Bundle.module.url(forResource: "empty_space_compute",
                                 withExtension: "metal",
                                 subdirectory: "Shaders")
        guard let sourceURL,
              let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            return nil
        }
        let options = MTLCompileOptions()
        if #available(tvOS 16.0, *) {
            options.languageVersion = .version3_0
        }
        return try? device.makeLibrary(source: source, options: options)
    }

    func texture(minMaxTexture: any MTLTexture,
                 transferTexture: any MTLTexture,
                 parameters: RenderingParameters,
                 commandQueue: any MTLCommandQueue) async throws -> any MTLTexture {
        guard minMaxTexture.device === device,
              commandQueue.device === device,
              minMaxTexture.textureType == .type3D,
              minMaxTexture.pixelFormat == .rg16Float,
              minMaxTexture.mipmapLevelCount > 0 else {
            throw CacheError.invalidMinMaxTexture
        }

        if cachedMinMaxSource.map({ ($0 as AnyObject) !== (minMaxTexture as AnyObject) }) ?? true
            || cachedTransferSource.map({ ($0 as AnyObject) !== (transferTexture as AnyObject) }) ?? true {
            resourceGeneration &+= 1
            cachedSignature = nil
            cachedMinMaxSource = minMaxTexture
            cachedTransferSource = transferTexture
        }

        let signature = Signature(
            resourceGeneration: resourceGeneration,
            channelWeights: parameters.intensityRatio,
            opacityThreshold: 0.000_001,
            voxelMinValue: parameters.material.voxelMinValue,
            voxelMaxValue: parameters.material.voxelMaxValue,
            datasetMinValue: parameters.material.datasetMinValue,
            datasetMaxValue: parameters.material.datasetMaxValue,
            densityFloor: parameters.material.densityFloor,
            densityCeil: parameters.material.densityCeil,
            gateHuMin: parameters.material.gateHuMin,
            gateHuMax: parameters.material.gateHuMax,
            useHuGate: parameters.material.useHuGate
        )
        if cachedSignature == signature, let cachedTexture {
            return cachedTexture
        }

        let visibilityTexture = try reusableTexture(for: minMaxTexture)
        skippingFlagBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee = 0
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw CacheError.commandBufferUnavailable
        }
        commandBuffer.label = "EmptySpaceVisibilityCache.Build"

        var channelWeights = signature.channelWeights
        var opacityThreshold = signature.opacityThreshold
        let datasetRange = Float(parameters.material.datasetMaxValue - parameters.material.datasetMinValue)
        let windowRange = Float(parameters.material.voxelMaxValue - parameters.material.voxelMinValue)
        var intensityParameters = SIMD4<Float>(
            Float(parameters.material.datasetMinValue),
            max(datasetRange, 1),
            Float(parameters.material.voxelMinValue),
            windowRange > 0 ? 1 / windowRange : 0
        )
        var densityRange = SIMD2<Float>(parameters.material.densityFloor,
                                        parameters.material.densityCeil)
        var gateRange = SIMD2<Int32>(parameters.material.gateHuMin,
                                     parameters.material.gateHuMax)
        var useHuGate = parameters.material.useHuGate
        let skippingMipLevel = min(3, minMaxTexture.mipmapLevelCount - 1)
        for level in 0..<minMaxTexture.mipmapLevelCount {
            guard let sourceView = minMaxTexture.makeTextureView(
                pixelFormat: .rg16Float,
                textureType: .type3D,
                levels: level..<(level + 1),
                slices: 0..<1
            ), let destinationView = visibilityTexture.makeTextureView(
                pixelFormat: .r8Unorm,
                textureType: .type3D,
                levels: level..<(level + 1),
                slices: 0..<1
            ) else {
                throw CacheError.textureViewUnavailable
            }
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw CacheError.commandEncoderUnavailable
            }
            encoder.label = "EmptySpaceVisibilityCache.MipLevel\(level)"
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(sourceView, index: 0)
            encoder.setTexture(destinationView, index: 1)
            encoder.setTexture(transferTexture, index: 2)
            encoder.setTexture(transferTexture, index: 3)
            encoder.setTexture(transferTexture, index: 4)
            encoder.setTexture(transferTexture, index: 5)
            encoder.setBytes(&channelWeights,
                             length: MemoryLayout<SIMD4<Float>>.stride,
                             index: 0)
            encoder.setBytes(&opacityThreshold,
                             length: MemoryLayout<Float>.stride,
                             index: 1)
            encoder.setBytes(&intensityParameters,
                             length: MemoryLayout<SIMD4<Float>>.stride,
                             index: 2)
            encoder.setBytes(&densityRange,
                             length: MemoryLayout<SIMD2<Float>>.stride,
                             index: 3)
            encoder.setBytes(&gateRange,
                             length: MemoryLayout<SIMD2<Int32>>.stride,
                             index: 4)
            encoder.setBytes(&useHuGate,
                             length: MemoryLayout<Int32>.stride,
                             index: 5)
            encoder.setBuffer(skippingFlagBuffer, offset: 0, index: 6)
            var collectSkippingFlag: UInt32 = level == skippingMipLevel ? 1 : 0
            encoder.setBytes(&collectSkippingFlag,
                             length: MemoryLayout<UInt32>.stride,
                             index: 7)

            let side = max(1, min(4, Int(cbrt(Double(pipeline.maxTotalThreadsPerThreadgroup)))))
            let threadsPerThreadgroup = MTLSize(width: side, height: side, depth: side)
            let threadgroups = MTLSize(
                width: (destinationView.width + side - 1) / side,
                height: (destinationView.height + side - 1) / side,
                depth: (destinationView.depth + side - 1) / side
            )
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
            encoder.endEncoding()
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            commandBuffer.addCompletedHandler { buffer in
                guard buffer.status == .completed, buffer.error == nil else {
                    continuation.resume(throwing: CacheError.commandExecutionFailed)
                    return
                }
                continuation.resume()
            }
            commandBuffer.commit()
        }

        cachedSignature = signature
        isSkippingUseful = skippingFlagBuffer.contents()
            .bindMemory(to: UInt32.self, capacity: 1).pointee != 0
        visibilityBuildCount += 1
        return visibilityTexture
    }

    private func reusableTexture(for minMaxTexture: any MTLTexture) throws -> any MTLTexture {
        if let cachedTexture,
           cachedTexture.width == minMaxTexture.width,
           cachedTexture.height == minMaxTexture.height,
           cachedTexture.depth == minMaxTexture.depth,
           cachedTexture.mipmapLevelCount == minMaxTexture.mipmapLevelCount {
            return cachedTexture
        }

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r8Unorm
        descriptor.width = minMaxTexture.width
        descriptor.height = minMaxTexture.height
        descriptor.depth = minMaxTexture.depth
        descriptor.mipmapLevelCount = minMaxTexture.mipmapLevelCount
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw CacheError.textureUnavailable
        }
        texture.label = "EmptySpaceVisibilityCache.VisibilityPyramid"
        cachedTexture = texture
        return texture
    }
}
