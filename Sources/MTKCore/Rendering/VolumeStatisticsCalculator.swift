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

/// GPU-accelerated volume statistics calculator supporting percentile and Otsu threshold computation
public final class VolumeStatisticsCalculator {
    public enum StatisticsError: Error {
        case pipelineUnavailable
        case commandQueueUnavailable
        case commandBufferCreationFailed
        case encoderCreationFailed
        case bufferAllocationFailed
        case emptyHistogram
        case invalidPercentiles
    }

    private let device: any MTLDevice
    private let featureFlags: FeatureFlags
    private let commandQueue: any MTLCommandQueue
    private let library: any MTLLibrary
    private let debugOptions: VolumeRenderingDebugOptions
    private var pipelineCache: [String: MTLComputePipelineState] = [:]
    private let logger = Logger(subsystem: "com.mtk.volumerendering",
                                category: "VolumeStatistics")

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

    /// Compute percentile bin indices from histogram with GPU acceleration and CPU fallback
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

        guard let histogramBuffer = device.makeBuffer(length: histogramBufferLength, options: .storageModeShared),
              let cumulativeSumBuffer = device.makeBuffer(length: cumulativeSumBufferLength, options: .storageModeShared),
              let percentilesBuffer = device.makeBuffer(length: percentilesBufferLength, options: .storageModeShared),
              let percentileBinsBuffer = device.makeBuffer(length: percentileBinsBufferLength, options: .storageModeShared) else {
            // Fall back to CPU if buffer allocation fails
            logger.warning("Buffer allocation failed, falling back to CPU percentile computation")
            do {
                let result = try computePercentilesCPU(from: channelHistogram, percentiles: percentiles)
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
            return
        }

        histogramBuffer.label = "buf.histogram.statistics"
        cumulativeSumBuffer.label = "buf.cumulativeSum"
        percentilesBuffer.label = "buf.percentiles"
        percentileBinsBuffer.label = "buf.percentileBins"

        // Copy data to buffers
        histogramBuffer.contents().copyMemory(from: channelHistogram, byteCount: histogramBufferLength)
        percentilesBuffer.contents().copyMemory(from: percentiles, byteCount: percentilesBufferLength)

        // Determine which cumulative sum kernel to use
        let threadgroupMemoryRequired = binCount * MemoryLayout<UInt32>.stride
        let usesThreadgroupMemory = threadgroupMemoryRequired <= device.maxThreadgroupMemoryLength
        let cumulativeSumKernelName = usesThreadgroupMemory ? "computeCumulativeSum" : "computeCumulativeSumSequential"

        guard let cumulativeSumPipeline = pipelineState(named: cumulativeSumKernelName),
              let percentilesPipeline = pipelineState(named: "extractPercentiles") else {
            // Fall back to CPU if pipeline is unavailable
            logger.warning("Pipeline unavailable, falling back to CPU percentile computation")
            do {
                let result = try computePercentilesCPU(from: channelHistogram, percentiles: percentiles)
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            // Fall back to CPU if command buffer creation fails
            logger.warning("Command buffer creation failed, falling back to CPU percentile computation")
            do {
                let result = try computePercentilesCPU(from: channelHistogram, percentiles: percentiles)
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
            return
        }
        commandBuffer.label = "cmd.calculateStatistics"

        // Encode cumulative sum computation
        guard let cumulativeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            // Fall back to CPU if encoder creation fails
            logger.warning("Encoder creation failed, falling back to CPU percentile computation")
            do {
                let result = try computePercentilesCPU(from: channelHistogram, percentiles: percentiles)
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
            return
        }
        cumulativeEncoder.label = "enc.cumulativeSum"
        cumulativeEncoder.setComputePipelineState(cumulativeSumPipeline)

        var binCountParam = UInt32(binCount)

        if usesThreadgroupMemory {
            // Parallel cumulative sum using threadgroup memory
            cumulativeEncoder.setBuffer(histogramBuffer, offset: 0, index: 0)
            cumulativeEncoder.setBuffer(cumulativeSumBuffer, offset: 0, index: 1)
            cumulativeEncoder.setBytes(&binCountParam, length: MemoryLayout<UInt32>.stride, index: 2)
            cumulativeEncoder.setThreadgroupMemoryLength(threadgroupMemoryRequired, index: 0)

            let configuration = ThreadgroupDispatchConfiguration.default(for: ThreadgroupPipelineLimits(pipeline: cumulativeSumPipeline))
            let threadsPerThreadgroup = configuration.threadsPerThreadgroup
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
        guard let percentilesEncoder = commandBuffer.makeComputeCommandEncoder() else {
            // Fall back to CPU if encoder creation fails
            logger.warning("Encoder creation failed, falling back to CPU percentile computation")
            do {
                let result = try computePercentilesCPU(from: channelHistogram, percentiles: percentiles)
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
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

        let percentileConfiguration = ThreadgroupDispatchConfiguration.default(for: ThreadgroupPipelineLimits(pipeline: percentilesPipeline))
        let percentileThreadsPerThreadgroup = percentileConfiguration.threadsPerThreadgroup
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

        commandBuffer.addCompletedHandler { [weak self] buffer in
            if let error = buffer.error {
                // Fall back to CPU if GPU execution fails
                guard let self else {
                    completion(.failure(error))
                    return
                }
                self.logger.warning("GPU percentile computation failed, falling back to CPU: \(error.localizedDescription)")
                do {
                    let result = try self.computePercentilesCPU(from: channelHistogram, percentiles: percentiles)
                    completion(.success(result))
                } catch let cpuError {
                    completion(.failure(cpuError))
                }
                return
            }

            // Read results from buffer
            let pointer = percentileBinsBuffer.contents().assumingMemoryBound(to: UInt32.self)
            let results = Array(UnsafeBufferPointer(start: pointer, count: percentiles.count))
            completion(.success(results))
        }

        commandBuffer.commit()
    }

    /// Compute Otsu threshold bin index from histogram with GPU acceleration and CPU fallback
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

        guard let histogramBuffer = device.makeBuffer(length: histogramBufferLength, options: .storageModeShared),
              let resultBuffer = device.makeBuffer(length: resultBufferLength, options: .storageModeShared) else {
            // Fall back to CPU if buffer allocation fails
            logger.warning("Buffer allocation failed, falling back to CPU Otsu threshold computation")
            do {
                let result = try computeOtsuThresholdCPU(from: channelHistogram)
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
            return
        }

        histogramBuffer.label = "buf.histogram.otsu"
        resultBuffer.label = "buf.otsuThreshold"

        // Copy histogram data to buffer
        histogramBuffer.contents().copyMemory(from: channelHistogram, byteCount: histogramBufferLength)

        // Get pipeline state
        guard let otsuPipeline = pipelineState(named: "calculateOtsuThreshold") else {
            // Fall back to CPU if pipeline is unavailable
            logger.warning("Pipeline unavailable, falling back to CPU Otsu threshold computation")
            do {
                let result = try computeOtsuThresholdCPU(from: channelHistogram)
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            // Fall back to CPU if command buffer creation fails
            logger.warning("Command buffer creation failed, falling back to CPU Otsu threshold computation")
            do {
                let result = try computeOtsuThresholdCPU(from: channelHistogram)
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
            return
        }
        commandBuffer.label = "cmd.calculateOtsuThreshold"

        // Encode Otsu threshold computation
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            // Fall back to CPU if encoder creation fails
            logger.warning("Encoder creation failed, falling back to CPU Otsu threshold computation")
            do {
                let result = try computeOtsuThresholdCPU(from: channelHistogram)
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
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

        commandBuffer.addCompletedHandler { [weak self] buffer in
            if let error = buffer.error {
                // Fall back to CPU if GPU execution fails
                guard let self else {
                    completion(.failure(error))
                    return
                }
                self.logger.warning("GPU Otsu threshold computation failed, falling back to CPU: \(error.localizedDescription)")
                do {
                    let result = try self.computeOtsuThresholdCPU(from: channelHistogram)
                    completion(.success(result))
                } catch let cpuError {
                    completion(.failure(cpuError))
                }
                return
            }

            // Read result from buffer
            let pointer = resultBuffer.contents().assumingMemoryBound(to: UInt32.self)
            let thresholdBin = pointer.pointee
            completion(.success(thresholdBin))
        }

        commandBuffer.commit()
    }

    // MARK: - CPU Fallback Implementations

    /// CPU-based percentile computation (fallback when GPU is unavailable)
    ///
    /// - Parameters:
    ///   - histogram: Histogram array (single channel)
    ///   - percentiles: Array of percentiles to compute (0.0...1.0)
    /// - Returns: Array of bin indices for each percentile
    /// - Throws: StatisticsError if input is invalid
    private func computePercentilesCPU(from histogram: [UInt32],
                                      percentiles: [Float]) throws -> [UInt32] {
        guard !histogram.isEmpty else {
            throw StatisticsError.emptyHistogram
        }

        guard !percentiles.isEmpty else {
            throw StatisticsError.invalidPercentiles
        }

        // Calculate total count
        let totalCount = histogram.reduce(0, +)
        guard totalCount > 0 else {
            throw StatisticsError.emptyHistogram
        }

        // Compute cumulative sum
        var cumulativeSum: [UInt32] = []
        cumulativeSum.reserveCapacity(histogram.count)
        var runningSum: UInt32 = 0
        for count in histogram {
            runningSum += count
            cumulativeSum.append(runningSum)
        }

        // Extract percentile bins
        var percentileBins: [UInt32] = []
        percentileBins.reserveCapacity(percentiles.count)

        for percentile in percentiles {
            let threshold = UInt32(Float(totalCount) * percentile)

            // Binary search for the first bin where cumulative sum >= threshold
            var left = 0
            var right = cumulativeSum.count - 1
            var result = UInt32(right)

            while left <= right {
                let mid = (left + right) / 2
                if cumulativeSum[mid] >= threshold {
                    result = UInt32(mid)
                    right = mid - 1
                } else {
                    left = mid + 1
                }
            }

            percentileBins.append(result)
        }

        return percentileBins
    }

    /// CPU-based Otsu threshold computation (fallback when GPU is unavailable)
    ///
    /// Otsu's method finds the optimal threshold that maximizes the between-class variance
    /// between background and foreground voxels in the histogram.
    ///
    /// - Parameter histogram: Histogram array (single channel)
    /// - Returns: Optimal threshold bin index
    /// - Throws: StatisticsError if input is invalid
    private func computeOtsuThresholdCPU(from histogram: [UInt32]) throws -> UInt32 {
        guard !histogram.isEmpty else {
            throw StatisticsError.emptyHistogram
        }

        // Calculate total count and mean intensity
        let totalCount = histogram.reduce(0, +)
        guard totalCount > 0 else {
            throw StatisticsError.emptyHistogram
        }

        var totalMean: Double = 0.0
        for (bin, count) in histogram.enumerated() {
            totalMean += Double(bin) * Double(count)
        }
        totalMean /= Double(totalCount)

        // Find threshold that maximizes between-class variance
        var maxVariance: Double = 0.0
        var optimalThreshold: UInt32 = 0

        var backgroundWeight: Double = 0.0
        var backgroundMean: Double = 0.0

        for threshold in 0..<histogram.count {
            backgroundWeight += Double(histogram[threshold])

            if backgroundWeight == 0 {
                continue
            }

            let foregroundWeight = Double(totalCount) - backgroundWeight

            if foregroundWeight == 0 {
                break
            }

            backgroundMean += Double(threshold) * Double(histogram[threshold])
            let currentBackgroundMean = backgroundMean / backgroundWeight
            let currentForegroundMean = (Double(totalCount) * totalMean - backgroundMean) / foregroundWeight

            // Calculate between-class variance
            let variance = backgroundWeight * foregroundWeight *
                          (currentBackgroundMean - currentForegroundMean) *
                          (currentBackgroundMean - currentForegroundMean)

            if variance > maxVariance {
                maxVariance = variance
                optimalThreshold = UInt32(threshold)
            }
        }

        return optimalThreshold
    }
}

private extension VolumeStatisticsCalculator {
    func pipelineState(named functionName: String) -> MTLComputePipelineState? {
        if let cached = pipelineCache[functionName] {
            return cached
        }

        guard let function = library.makeFunction(name: functionName) else {
            logger.error("Função Metal \(functionName) não encontrada.")
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
            logger.error("Falha ao criar pipeline de estatísticas: \(error.localizedDescription)")
            return nil
        }
    }
}
