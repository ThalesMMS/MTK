//
//  VolumeStatisticsCalculator.swift
//  MTK
//
//  GPU-backed statistics calculator for percentile and Otsu computations.
//
//  Thales Matheus Mendonça Santos — February 2026

import Foundation
import Metal
import OSLog

/// GPU compute statistics calculator for percentile and Otsu computations.
///
/// This feature has no MPS dependency. GPU setup and execution failures are
/// surfaced explicitly to callers. CPU reference implementations live in the
/// test target and are not part of the runtime contract.
public final class VolumeStatisticsCalculator {
    public enum StatisticsError: Error, Equatable {
        case pipelineUnavailable
        case bufferAllocationFailed
        case commandQueueUnavailable
        case commandBufferCreationFailed
        case encoderCreationFailed
        case emptyHistogram
        case invalidPercentiles
    }

    @_spi(Testing)
    public enum ForcedFailure: Equatable {
        case bufferAllocationFailed
        case pipelineUnavailable
        case commandBufferCreationFailed
        case encoderCreationFailed
    }

    private let device: any MTLDevice
    private let featureFlags: FeatureFlags
    private let commandQueue: any MTLCommandQueue
    private let library: any MTLLibrary
    private let debugOptions: VolumeRenderingDebugOptions
    private let forcedFailure: ForcedFailure?
    private var pipelineCache: [String: MTLComputePipelineState] = [:]
    private let logger = Logger(subsystem: "com.mtk.volumerendering",
                                category: "VolumeStatistics")

    public convenience init(device: any MTLDevice,
                            commandQueue: any MTLCommandQueue,
                            library: any MTLLibrary,
                            featureFlags: FeatureFlags,
                            debugOptions: VolumeRenderingDebugOptions) {
        self.init(device: device,
                  commandQueue: commandQueue,
                  library: library,
                  featureFlags: featureFlags,
                  debugOptions: debugOptions,
                  forcedFailure: nil)
    }

    @_spi(Testing)
    public init(device: any MTLDevice,
                commandQueue: any MTLCommandQueue,
                library: any MTLLibrary,
                featureFlags: FeatureFlags,
                debugOptions: VolumeRenderingDebugOptions,
                forcedFailure: ForcedFailure?) {
        self.device = device
        self.featureFlags = featureFlags
        self.commandQueue = commandQueue
        self.library = library
        self.debugOptions = debugOptions
        self.forcedFailure = forcedFailure
    }

    /// Compute percentile bin indices from a histogram with GPU acceleration.
    ///
    /// - Parameters:
    ///   - histogram: Histogram array (single channel or multi-channel)
    ///   - percentiles: Array of percentiles to compute (0.0...1.0)
    ///   - completion: Completion handler with Result containing bin indices for each percentile
    public func computePercentiles(from histogram: [[UInt32]],
                                  percentiles: [Float],
                                  completion: @escaping (Result<[UInt32], Error>) -> Void) {
        // Validate input
        guard !histogram.isEmpty, !histogram[0].isEmpty else {
            completion(.failure(StatisticsError.emptyHistogram))
            return
        }

        guard !percentiles.isEmpty else {
            completion(.failure(StatisticsError.invalidPercentiles))
            return
        }

        // For multi-channel histograms, use first channel
        let channelHistogram = histogram[0]
        let binCount = channelHistogram.count

        // Calculate total count
        let totalCount = channelHistogram.reduce(0, +)
        guard totalCount > 0 else {
            completion(.failure(StatisticsError.emptyHistogram))
            return
        }

        // Allocate buffers
        let histogramBufferLength = binCount * MemoryLayout<UInt32>.stride
        let cumulativeSumBufferLength = binCount * MemoryLayout<UInt32>.stride
        let percentilesBufferLength = percentiles.count * MemoryLayout<Float>.stride
        let percentileBinsBufferLength = percentiles.count * MemoryLayout<UInt32>.stride

        // StorageModePolicy.md: statistics buffers are CPU-visible compute outputs.
        guard forcedFailure != .bufferAllocationFailed,
              let histogramBuffer = device.makeBuffer(length: histogramBufferLength, options: .storageModeShared),
              let cumulativeSumBuffer = device.makeBuffer(length: cumulativeSumBufferLength, options: .storageModeShared),
              let percentilesBuffer = device.makeBuffer(length: percentilesBufferLength, options: .storageModeShared),
              let percentileBinsBuffer = device.makeBuffer(length: percentileBinsBufferLength, options: .storageModeShared) else {
            completion(.failure(StatisticsError.bufferAllocationFailed))
            return
        }

        histogramBuffer.label = "buf.histogram.statistics"
        cumulativeSumBuffer.label = "buf.cumulativeSum"
        percentilesBuffer.label = "buf.percentiles"
        percentileBinsBuffer.label = "buf.percentileBins"

        // Copy data to buffers
        channelHistogram.withUnsafeBytes { source in
            if let baseAddress = source.baseAddress {
                histogramBuffer.contents().copyMemory(from: baseAddress, byteCount: histogramBufferLength)
            } else {
                assertionFailure("Histogram source buffer unexpectedly has nil baseAddress; zero-filling GPU histogram buffer")
                memset(histogramBuffer.contents(), 0, histogramBufferLength)
            }
        }
        percentiles.withUnsafeBytes { source in
            if let baseAddress = source.baseAddress {
                percentilesBuffer.contents().copyMemory(from: baseAddress, byteCount: percentilesBufferLength)
            } else {
                assertionFailure("Percentiles source buffer unexpectedly has nil baseAddress; zero-filling GPU percentiles buffer")
                memset(percentilesBuffer.contents(), 0, percentilesBufferLength)
            }
        }

        // Determine which cumulative sum kernel to use
        let threadgroupMemoryRequired = binCount * MemoryLayout<UInt32>.stride
        let cumulativeSumPipelineCandidate = pipelineState(named: "computeCumulativeSum")
        let maxCumulativeThreads = cumulativeSumPipelineCandidate?.maxTotalThreadsPerThreadgroup ?? 0
        let usesThreadgroupMemory = cumulativeSumPipelineCandidate != nil &&
            threadgroupMemoryRequired <= device.maxThreadgroupMemoryLength &&
            binCount <= maxCumulativeThreads
        let cumulativeSumKernelName = usesThreadgroupMemory ? "computeCumulativeSum" : "computeCumulativeSumSequential"
        let cumulativeSumPipeline = pipelineState(named: cumulativeSumKernelName)

        guard let resolvedCumulativeSumPipeline = cumulativeSumPipeline,
              let percentilesPipeline = pipelineState(named: "extractPercentiles") else {
            completion(.failure(StatisticsError.pipelineUnavailable))
            return
        }

        guard forcedFailure != .commandBufferCreationFailed,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            completion(.failure(StatisticsError.commandBufferCreationFailed))
            return
        }
        commandBuffer.label = "cmd.calculateStatistics"

        // Encode cumulative sum computation
        guard forcedFailure != .encoderCreationFailed,
              let cumulativeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            completion(.failure(StatisticsError.encoderCreationFailed))
            return
        }
        cumulativeEncoder.label = "enc.cumulativeSum"
        cumulativeEncoder.setComputePipelineState(resolvedCumulativeSumPipeline)

        var binCountParam = UInt32(binCount)

        if usesThreadgroupMemory {
            // Parallel cumulative sum using threadgroup memory
            cumulativeEncoder.setBuffer(histogramBuffer, offset: 0, index: 0)
            cumulativeEncoder.setBuffer(cumulativeSumBuffer, offset: 0, index: 1)
            cumulativeEncoder.setBytes(&binCountParam, length: MemoryLayout<UInt32>.stride, index: 2)
            cumulativeEncoder.setThreadgroupMemoryLength(threadgroupMemoryRequired, index: 0)

            let threadCount = max(1, min(binCount, resolvedCumulativeSumPipeline.maxTotalThreadsPerThreadgroup))
            let threadsPerThreadgroup = MTLSize(width: threadCount, height: 1, depth: 1)
            let threadsPerGrid = MTLSize(width: binCount, height: 1, depth: 1)

            if featureFlags.contains(.nonUniformThreadgroups) {
                cumulativeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
            } else {
                let groups = MTLSize(width: (threadsPerGrid.width + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width,
                                     height: 1,
                                     depth: 1)
                cumulativeEncoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerThreadgroup)
            }
        } else {
            // Sequential cumulative sum
            cumulativeEncoder.setBuffer(histogramBuffer, offset: 0, index: 0)
            cumulativeEncoder.setBuffer(cumulativeSumBuffer, offset: 0, index: 1)
            cumulativeEncoder.setBytes(&binCountParam, length: MemoryLayout<UInt32>.stride, index: 2)

            // Sequential kernel runs on single thread
            cumulativeEncoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                                  threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        }

        cumulativeEncoder.endEncoding()

        // Encode percentile extraction
        guard forcedFailure != .encoderCreationFailed,
              let percentilesEncoder = commandBuffer.makeComputeCommandEncoder() else {
            completion(.failure(StatisticsError.encoderCreationFailed))
            return
        }
        percentilesEncoder.label = "enc.extractPercentiles"
        percentilesEncoder.setComputePipelineState(percentilesPipeline)

        var totalCountParam = UInt32(totalCount)
        var percentileCountParam = UInt32(percentiles.count)

        percentilesEncoder.setBuffer(cumulativeSumBuffer, offset: 0, index: 0)
        percentilesEncoder.setBytes(&binCountParam, length: MemoryLayout<UInt32>.stride, index: 1)
        percentilesEncoder.setBytes(&totalCountParam, length: MemoryLayout<UInt32>.stride, index: 2)
        percentilesEncoder.setBuffer(percentilesBuffer, offset: 0, index: 3)
        percentilesEncoder.setBytes(&percentileCountParam, length: MemoryLayout<UInt32>.stride, index: 4)
        percentilesEncoder.setBuffer(percentileBinsBuffer, offset: 0, index: 5)

        let percentileThreadCount = max(1, min(percentiles.count, percentilesPipeline.maxTotalThreadsPerThreadgroup))
        let percentileThreadsPerThreadgroup = MTLSize(width: percentileThreadCount, height: 1, depth: 1)
        let percentileThreadsPerGrid = MTLSize(width: percentiles.count, height: 1, depth: 1)

        if featureFlags.contains(.nonUniformThreadgroups) {
            percentilesEncoder.dispatchThreads(percentileThreadsPerGrid, threadsPerThreadgroup: percentileThreadsPerThreadgroup)
        } else {
            let groups = MTLSize(width: (percentileThreadsPerGrid.width + percentileThreadsPerThreadgroup.width - 1) / percentileThreadsPerThreadgroup.width,
                                height: 1,
                                depth: 1)
            percentilesEncoder.dispatchThreadgroups(groups, threadsPerThreadgroup: percentileThreadsPerThreadgroup)
        }

        percentilesEncoder.endEncoding()

        commandBuffer.addCompletedHandler { buffer in
            if let error = buffer.error {
                completion(.failure(error))
                return
            }

            // Read results from buffer
            let pointer = percentileBinsBuffer.contents().assumingMemoryBound(to: UInt32.self)
            let results = Array(UnsafeBufferPointer(start: pointer, count: percentiles.count))
            completion(.success(results))
        }

        commandBuffer.commit()
    }

    /// Compute the Otsu threshold bin index from a histogram with GPU acceleration.
    ///
    /// Otsu's method finds the optimal threshold that maximizes the between-class variance
    /// between background and foreground voxels in the histogram.
    ///
    /// - Parameters:
    ///   - histogram: Histogram array (single channel or multi-channel)
    ///   - completion: Completion handler with Result containing the optimal threshold bin index
    public func computeOtsuThreshold(from histogram: [[UInt32]],
                                    completion: @escaping (Result<UInt32, Error>) -> Void) {
        // Validate input
        guard !histogram.isEmpty, !histogram[0].isEmpty else {
            completion(.failure(StatisticsError.emptyHistogram))
            return
        }

        // For multi-channel histograms, use first channel
        let channelHistogram = histogram[0]
        let binCount = channelHistogram.count

        // Calculate total count
        let totalCount = channelHistogram.reduce(0, +)
        guard totalCount > 0 else {
            completion(.failure(StatisticsError.emptyHistogram))
            return
        }

        // Allocate buffers
        let histogramBufferLength = binCount * MemoryLayout<UInt32>.stride
        let resultBufferLength = MemoryLayout<UInt32>.stride

        // StorageModePolicy.md: Otsu buffers are CPU-visible compute outputs.
        guard forcedFailure != .bufferAllocationFailed,
              let histogramBuffer = device.makeBuffer(length: histogramBufferLength, options: .storageModeShared),
              let resultBuffer = device.makeBuffer(length: resultBufferLength, options: .storageModeShared) else {
            completion(.failure(StatisticsError.bufferAllocationFailed))
            return
        }

        histogramBuffer.label = "buf.histogram.otsu"
        resultBuffer.label = "buf.otsuThreshold"

        // Copy histogram data to buffer
        channelHistogram.withUnsafeBytes { source in
            if let baseAddress = source.baseAddress {
                histogramBuffer.contents().copyMemory(from: baseAddress, byteCount: histogramBufferLength)
            } else {
                assertionFailure("Histogram source buffer unexpectedly has nil baseAddress; zero-filling GPU histogram buffer")
                memset(histogramBuffer.contents(), 0, histogramBufferLength)
            }
        }

        // Get pipeline state
        guard let otsuPipeline = pipelineState(named: "calculateOtsuThreshold") else {
            completion(.failure(StatisticsError.pipelineUnavailable))
            return
        }

        guard forcedFailure != .commandBufferCreationFailed,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            completion(.failure(StatisticsError.commandBufferCreationFailed))
            return
        }
        commandBuffer.label = "cmd.calculateOtsuThreshold"

        // Encode Otsu threshold computation
        guard forcedFailure != .encoderCreationFailed,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            completion(.failure(StatisticsError.encoderCreationFailed))
            return
        }
        encoder.label = "enc.otsuThreshold"
        encoder.setComputePipelineState(otsuPipeline)

        var binCountParam = UInt32(binCount)
        var totalCountParam = UInt32(totalCount)

        encoder.setBuffer(histogramBuffer, offset: 0, index: 0)
        encoder.setBytes(&binCountParam, length: MemoryLayout<UInt32>.stride, index: 1)
        encoder.setBytes(&totalCountParam, length: MemoryLayout<UInt32>.stride, index: 2)
        encoder.setBuffer(resultBuffer, offset: 0, index: 3)

        // Otsu kernel is a reduction operation, runs on single thread
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))

        encoder.endEncoding()

        commandBuffer.addCompletedHandler { buffer in
            if let error = buffer.error {
                completion(.failure(error))
                return
            }

            // Read result from buffer
            let pointer = resultBuffer.contents().assumingMemoryBound(to: UInt32.self)
            let thresholdBin = pointer.pointee
            completion(.success(thresholdBin))
        }

        commandBuffer.commit()
    }
}

private extension VolumeStatisticsCalculator {
    func pipelineState(named functionName: String) -> MTLComputePipelineState? {
        if forcedFailure == .pipelineUnavailable {
            return nil
        }

        if let cached = pipelineCache[functionName] {
            return cached
        }

        guard let function = library.makeFunction(name: functionName) else {
            logger.error("Metal function '\(functionName)' not found in library.")
            return nil
        }
        function.label = "func.\(functionName)"

        let descriptor = MTLComputePipelineDescriptor()
        descriptor.label = "pipeline.\(functionName)"
        descriptor.computeFunction = function

        do {
            let pipeline = try device.makeComputePipelineState(descriptor: descriptor, options: [], reflection: nil)
            pipelineCache[functionName] = pipeline
            return pipeline
        } catch {
            logger.error("Failed to create statistics pipeline: \(error.localizedDescription)")
            return nil
        }
    }
}
