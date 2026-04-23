//
//  GradientHistogramCalculator.swift
//  MTK
//
//  GPU-backed 2D gradient-intensity histogram calculator for 2D transfer functions.
//
//  Thales Matheus Mendonça Santos — February 2026

import Foundation
import Metal
import OSLog

@_spi(Testing) public struct GradientHistogramDispatchPlan {
    public let intensityBins: Int
    public let gradientBins: Int
    public let bufferLength: Int
    public let usesThreadgroupMemory: Bool
    public let kernelName: String
}

@_spi(Testing) public enum GradientHistogramKernelPlanner {
    public static func makePlan(intensityBins requestedIntensityBins: Int,
                                gradientBins requestedGradientBins: Int,
                                defaultIntensityBinCount: Int,
                                defaultGradientBinCount: Int,
                                maxThreadgroupMemoryLength: Int) -> GradientHistogramDispatchPlan {
        let intensityBins = clampGradientHistogramBinCount(requestedIntensityBins > 0 ? requestedIntensityBins : defaultIntensityBinCount)
        let gradientBins = clampGradientHistogramBinCount(requestedGradientBins > 0 ? requestedGradientBins : defaultGradientBinCount)
        let totalBins = intensityBins * gradientBins
        let bufferLength = totalBins * MemoryLayout<UInt32>.stride
        let usesThreadgroupMemory = bufferLength <= max(0, maxThreadgroupMemoryLength)
        let kernelName = usesThreadgroupMemory ? "computeGradientHistogramThreadgroup" : "computeGradientHistogramLegacy"

        return GradientHistogramDispatchPlan(intensityBins: intensityBins,
                                            gradientBins: gradientBins,
                                            bufferLength: bufferLength,
                                            usesThreadgroupMemory: usesThreadgroupMemory,
                                            kernelName: kernelName)
    }

    private static func clampGradientHistogramBinCount(_ value: Int) -> Int {
        max(1, min(value, 4096))
    }
}

public final class GradientHistogramCalculator {
    public enum HistogramError: Error {
        case pipelineUnavailable
        case commandQueueUnavailable
        case commandBufferCreationFailed
        case encoderCreationFailed
        case bufferAllocationFailed
    }

    private let device: any MTLDevice
    private let featureFlags: FeatureFlags
    private let commandQueue: any MTLCommandQueue
    private let library: any MTLLibrary
    private let debugOptions: VolumeRenderingDebugOptions
    private var pipelineCache: [String: MTLComputePipelineState] = [:]
    private let logger = Logger(subsystem: "com.mtk.volumerendering",
                                category: "GradientHistogram")

    public init(device: any MTLDevice,
                commandQueue: any MTLCommandQueue,
                library: any MTLLibrary,
                featureFlags: FeatureFlags,
                debugOptions: VolumeRenderingDebugOptions) {
        self.device = device
        self.featureFlags = featureFlags
        self.commandQueue = commandQueue
        self.library = library
        self.debugOptions = debugOptions
    }

    public func computeGradientHistogram(for texture: any MTLTexture,
                                         voxelMin: Int32,
                                         voxelMax: Int32,
                                         gradientMin: Float,
                                         gradientMax: Float,
                                         intensityBins requestedIntensityBins: Int = 0,
                                         gradientBins requestedGradientBins: Int = 0,
                                         completion: @escaping (Result<[[UInt32]], Error>) -> Void) {
        var plan = GradientHistogramKernelPlanner.makePlan(intensityBins: requestedIntensityBins,
                                                           gradientBins: requestedGradientBins,
                                                           defaultIntensityBinCount: debugOptions.histogramBinCount,
                                                           defaultGradientBinCount: debugOptions.histogramBinCount,
                                                           maxThreadgroupMemoryLength: device.maxThreadgroupMemoryLength)

        var pipeline = pipelineState(named: plan.kernelName)

        if pipeline == nil, plan.usesThreadgroupMemory {
            plan = GradientHistogramKernelPlanner.makePlan(intensityBins: requestedIntensityBins,
                                                           gradientBins: requestedGradientBins,
                                                           defaultIntensityBinCount: debugOptions.histogramBinCount,
                                                           defaultGradientBinCount: debugOptions.histogramBinCount,
                                                           maxThreadgroupMemoryLength: -1)
            pipeline = pipelineState(named: plan.kernelName)
        }

        guard let resolvedPipeline = pipeline else {
            completion(.failure(HistogramError.pipelineUnavailable))
            return
        }

        // StorageModePolicy.md: gradient histogram buffers are CPU-visible compute outputs.
        guard let histogramBuffer = device.makeBuffer(length: plan.bufferLength, options: .storageModeShared) else {
            completion(.failure(HistogramError.bufferAllocationFailed))
            return
        }
        histogramBuffer.label = MTL_label.gradientHistogramBuffer
        memset(histogramBuffer.contents(), 0, plan.bufferLength)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            completion(.failure(HistogramError.commandBufferCreationFailed))
            return
        }
        commandBuffer.label = MTL_label.calculate_gradient_histogram

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            completion(.failure(HistogramError.encoderCreationFailed))
            return
        }
        encoder.label = MTL_label.calculate_gradient_histogram

        encoder.setComputePipelineState(resolvedPipeline)
        encoder.setTexture(texture, index: 0)

        var encodedIntensityBins = UInt32(plan.intensityBins)
        var encodedGradientBins = UInt32(plan.gradientBins)
        var encodedVoxelMin = Int16(voxelMin)
        var encodedVoxelMax = Int16(voxelMax)
        var encodedGradientMin = gradientMin
        var encodedGradientMax = gradientMax

        encoder.setBytes(&encodedIntensityBins, length: MemoryLayout<UInt32>.stride, index: 0)
        encoder.setBytes(&encodedGradientBins, length: MemoryLayout<UInt32>.stride, index: 1)
        encoder.setBytes(&encodedVoxelMin, length: MemoryLayout<Int16>.stride, index: 2)
        encoder.setBytes(&encodedVoxelMax, length: MemoryLayout<Int16>.stride, index: 3)
        encoder.setBytes(&encodedGradientMin, length: MemoryLayout<Float>.stride, index: 4)
        encoder.setBytes(&encodedGradientMax, length: MemoryLayout<Float>.stride, index: 5)
        encoder.setBuffer(histogramBuffer, offset: 0, index: 6)

        if plan.usesThreadgroupMemory {
            encoder.setThreadgroupMemoryLength(plan.bufferLength, index: 0)
        }

        let configuration = ThreadgroupDispatchConfiguration.default(for: ThreadgroupPipelineLimits(pipeline: resolvedPipeline))
        let threadsPerThreadgroup = configuration.threadsPerThreadgroup
        let threadsPerGrid = MTLSize(width: texture.width,
                                     height: texture.height,
                                     depth: max(texture.depth, 1))

        if featureFlags.contains(.nonUniformThreadgroups) {
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        } else {
            let groups = MTLSize(width: (threadsPerGrid.width + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width,
                                 height: (threadsPerGrid.height + threadsPerThreadgroup.height - 1) / threadsPerThreadgroup.height,
                                 depth: (threadsPerGrid.depth + threadsPerThreadgroup.depth - 1) / threadsPerThreadgroup.depth)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerThreadgroup)
        }

        encoder.endEncoding()

        commandBuffer.addCompletedHandler { buffer in
            if let error = buffer.error {
                completion(.failure(error))
                return
            }

            // Build 2D array: results[intensityBin][gradientBin] = count
            var results: [[UInt32]] = []
            results.reserveCapacity(plan.intensityBins)

            for intensityBin in 0..<plan.intensityBins {
                var gradientRow: [UInt32] = []
                gradientRow.reserveCapacity(plan.gradientBins)

                for gradientBin in 0..<plan.gradientBins {
                    let binIndex = intensityBin * plan.gradientBins + gradientBin
                    let offset = binIndex * MemoryLayout<UInt32>.stride
                    let pointer = histogramBuffer.contents().advanced(by: offset).assumingMemoryBound(to: UInt32.self)
                    let count = pointer.pointee
                    gradientRow.append(count)
                }
                results.append(gradientRow)
            }
            completion(.success(results))
        }

        commandBuffer.commit()
    }
}

private extension GradientHistogramCalculator {
    func pipelineState(named functionName: String) -> MTLComputePipelineState? {
        if let cached = pipelineCache[functionName] {
            return cached
        }

        guard let function = library.makeFunction(name: functionName) else {
            logger.error("Função Metal \(functionName) não encontrada.")
            return nil
        }
        function.label = MTL_label.calculate_gradient_histogram

        let descriptor = MTLComputePipelineDescriptor()
        descriptor.label = MTL_label.calculate_gradient_histogram
        descriptor.computeFunction = function

        do {
            let pipeline = try device.makeComputePipelineState(descriptor: descriptor, options: [], reflection: nil)
            pipelineCache[functionName] = pipeline
            return pipeline
        } catch {
            logger.error("Falha ao criar pipeline de histograma de gradiente: \(error.localizedDescription)")
            return nil
        }
    }
}
