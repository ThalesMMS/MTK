//
//  VolumeHistogramCalculator.swift
//  MTK
//
//  GPU-backed histogram calculator used for auto-windowing workflows.
//
//  Thales Matheus Mendonça Santos — October 2025

import Foundation
import Metal
import OSLog

/// Encapsulates a Metal compute histogram dispatch configuration including kernel selection
/// and threadgroup memory strategy.
///
/// This plan determines which Metal kernel to use (`computeHistogramThreadgroup` for fast
/// shared memory path, or `computeHistogramLegacy` for devices with limited threadgroup memory)
/// and pre-allocates buffer size based on channel count and bin requirements.
@_spi(Testing) public struct HistogramDispatchPlan {
    /// Number of histogram bins (intensity buckets) to allocate.
    public let bins: Int

    /// Number of channels to compute histograms for (1-4, typically 1 for grayscale volumes).
    public let channelCount: Int

    /// Total buffer size in bytes required to store all histogram data.
    public let bufferLength: Int

    /// Whether the selected kernel uses threadgroup memory for atomic operations (faster)
    /// or the device-memory kernel (slower but more broadly compatible).
    public let usesThreadgroupMemory: Bool

    /// Name of the Metal compute kernel to dispatch (`computeHistogramThreadgroup` or `computeHistogramLegacy`).
    public let kernelName: String
}

/// Device capability adaptation for selecting the histogram compute kernel based on
/// Metal limits and histogram requirements.
///
/// Selects the threadgroup-memory kernel when supported, otherwise uses the
/// device-memory kernel for broader compatibility.
@_spi(Testing) public enum HistogramKernelPlanner {
    /// Creates a histogram dispatch plan by selecting the optimal Metal compute kernel
    /// and memory strategy for the given device constraints.
    ///
    /// The planner uses the fast `computeHistogramThreadgroup` kernel (atomic operations
    /// in shared memory) when the required buffer fits within the device's threadgroup
    /// memory limit. Otherwise, it selects `computeHistogramLegacy`, the alternative
    /// device-memory kernel for limited threadgroup memory.
    ///
    /// - Parameters:
    ///   - channelCount: Number of histogram channels to compute (1-4, will be clamped).
    ///   - requestedBins: Desired bin count, or 0 to use `defaultBinCount`.
    ///   - defaultBinCount: Default bin count when `requestedBins` is zero or invalid.
    ///   - maxThreadgroupMemoryLength: Device's maximum threadgroup memory size in bytes.
    ///                                 Pass -1 to force device-memory kernel selection.
    ///
    /// - Returns: A ``HistogramDispatchPlan`` with kernel name, buffer size, and memory strategy.
    public static func makePlan(channelCount: Int,
                                requestedBins: Int,
                                defaultBinCount: Int,
                                maxThreadgroupMemoryLength: Int) -> HistogramDispatchPlan {
        let bins = VolumetricMath.clampBinCount(requestedBins > 0 ? requestedBins : defaultBinCount)
        let clampedChannels = max(1, min(channelCount, 4))
        let bufferLength = clampedChannels * bins * MemoryLayout<UInt32>.stride
        let usesThreadgroupMemory = bufferLength <= max(0, maxThreadgroupMemoryLength)
        let kernelName = usesThreadgroupMemory ? "computeHistogramThreadgroup" : "computeHistogramLegacy"

        return HistogramDispatchPlan(bins: bins,
                                     channelCount: clampedChannels,
                                     bufferLength: bufferLength,
                                     usesThreadgroupMemory: usesThreadgroupMemory,
                                     kernelName: kernelName)
    }
}

/// Pure Metal compute histogram calculator for 3D volume textures.
///
/// This feature has no MPS dependency.
///
/// Computes intensity distribution histograms using Metal compute shaders, enabling
/// efficient auto-windowing, contrast analysis, and transfer function optimization
/// for medical imaging workflows.
///
/// The calculator supports both fast threadgroup-memory kernels (for small histograms)
/// and alternative device-memory kernels (for large histograms or limited devices),
/// with kernel selection based on Metal device capabilities.
///
/// ## Features
///
/// - Multi-channel histogram support (1-4 channels)
/// - Configurable bin count (validated and clamped to safe ranges)
/// - Automatic kernel selection based on device threadgroup memory limits
/// - Asynchronous computation with completion callbacks
/// - Pipeline state caching for efficient reuse
///
/// ## Example
///
/// ```swift
/// let calculator = VolumeHistogramCalculator(
///     device: device,
///     commandQueue: queue,
///     library: library,
///     featureFlags: flags,
///     debugOptions: options
/// )
///
/// calculator.computeHistogram(
///     for: volumeTexture,
///     channelCount: 1,
///     voxelMin: -1024,
///     voxelMax: 3071,
///     bins: 256
/// ) { result in
///     switch result {
///     case .success(let histograms):
///         print("Channel 0 histogram: \(histograms[0])")
///     case .failure(let error):
///         print("Histogram computation failed: \(error)")
///     }
/// }
/// ```
///
/// ## Topics
///
/// ### Initialization
/// - ``init(device:commandQueue:library:featureFlags:debugOptions:)``
///
/// ### Computing Histograms
/// - ``computeHistogram(for:channelCount:voxelMin:voxelMax:bins:completion:)``
///
/// ### Error Handling
/// - ``HistogramError``
public final class VolumeHistogramCalculator {
    /// Errors that can occur during histogram computation.
    public enum HistogramError: Error {
        /// The required Metal compute pipeline could not be created or loaded.
        case pipelineUnavailable

        /// The Metal command queue is unavailable for submitting GPU work.
        case commandQueueUnavailable

        /// Failed to create a command buffer for encoding GPU commands.
        case commandBufferCreationFailed

        /// Failed to create a compute command encoder.
        case encoderCreationFailed

        /// Failed to allocate a Metal buffer for histogram storage.
        case bufferAllocationFailed
    }

    private let device: any MTLDevice
    private let featureFlags: FeatureFlags
    private let commandQueue: any MTLCommandQueue
    private let library: any MTLLibrary
    private let debugOptions: VolumeRenderingDebugOptions
    private var pipelineCache: [String: MTLComputePipelineState] = [:]
    private let logger = Logger(subsystem: "com.mtk.volumerendering",
                                category: "VolumeHistogram")

    /// Creates a histogram calculator for GPU-accelerated volume intensity analysis.
    ///
    /// - Parameters:
    ///   - device: Metal device for buffer allocation and pipeline creation.
    ///   - commandQueue: Command queue for submitting GPU compute work.
    ///   - library: Metal library containing histogram compute kernels
    ///              (`computeHistogramThreadgroup` and `computeHistogramLegacy`).
    ///   - featureFlags: Feature detection flags (used for non-uniform threadgroup dispatch).
    ///   - debugOptions: Debug configuration including default bin count for histograms.
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

    /// Computes an intensity histogram for a 3D volume texture using Metal compute shaders.
    ///
    /// Dispatches a GPU compute kernel that counts voxel intensities across configurable bins,
    /// producing a histogram array for each channel. The calculation runs asynchronously on
    /// the GPU with results delivered via a completion callback.
    ///
    /// The method automatically selects the optimal compute kernel based on device capabilities:
    /// - **Fast path:** `computeHistogramThreadgroup` uses shared memory atomics when buffer size
    ///   fits within device threadgroup memory limits (typical for ≤256 bins).
    /// - **Device-memory path:** `computeHistogramLegacy` uses device memory atomics for larger
    ///   histograms or devices with limited threadgroup memory.
    ///
    /// - Parameters:
    ///   - texture: Source 3D Metal texture containing voxel intensity data.
    ///   - channelCount: Number of histogram channels to compute (1-4, will be clamped).
    ///                   Use 1 for grayscale medical volumes.
    ///   - voxelMin: Minimum intensity value in the volume (for histogram range mapping).
    ///   - voxelMax: Maximum intensity value in the volume (for histogram range mapping).
    ///   - requestedBins: Desired histogram bin count. Pass 0 to use debug options default.
    ///                    Actual bin count will be clamped to safe ranges.
    ///   - completion: Callback invoked on command buffer completion queue with
    ///                 `.success([[UInt32]])` containing histogram arrays (one per channel),
    ///                 or `.failure(Error)` if GPU computation fails.
    ///
    /// ## Example
    ///
    /// ```swift
    /// calculator.computeHistogram(
    ///     for: volumeTexture,
    ///     channelCount: 1,
    ///     voxelMin: -1024,  // CT air
    ///     voxelMax: 3071,   // CT bone
    ///     bins: 256
    /// ) { result in
    ///     if case .success(let histograms) = result {
    ///         // histograms[0] contains 256 bins of UInt32 counts
    ///         let peakBin = histograms[0].enumerated().max(by: { $0.element < $1.element })?.offset
    ///         print("Peak intensity bin: \(peakBin ?? 0)")
    ///     }
    /// }
    /// ```
    public func computeHistogram(for texture: any MTLTexture,
                                 channelCount: Int,
                                 voxelMin: Int32,
                                 voxelMax: Int32,
                                 bins requestedBins: Int = 0,
                                 completion: @escaping (Result<[[UInt32]], Error>) -> Void) {
        var plan = HistogramKernelPlanner.makePlan(channelCount: channelCount,
                                                   requestedBins: requestedBins,
                                                   defaultBinCount: debugOptions.histogramBinCount,
                                                   maxThreadgroupMemoryLength: device.maxThreadgroupMemoryLength)

        var pipeline = pipelineState(named: plan.kernelName)

        if pipeline == nil, plan.usesThreadgroupMemory {
            plan = HistogramKernelPlanner.makePlan(channelCount: channelCount,
                                                   requestedBins: requestedBins,
                                                   defaultBinCount: debugOptions.histogramBinCount,
                                                   maxThreadgroupMemoryLength: -1)
            pipeline = pipelineState(named: plan.kernelName)
        }

        guard let resolvedPipeline = pipeline else {
            completion(.failure(HistogramError.pipelineUnavailable))
            return
        }

        // StorageModePolicy.md: histogram buffers are CPU-visible compute outputs.
        guard let histogramBuffer = device.makeBuffer(length: plan.bufferLength, options: .storageModeShared) else {
            completion(.failure(HistogramError.bufferAllocationFailed))
            return
        }
        histogramBuffer.label = MTL_label.histogramBuffer
        memset(histogramBuffer.contents(), 0, plan.bufferLength)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            completion(.failure(HistogramError.commandBufferCreationFailed))
            return
        }
        commandBuffer.label = MTL_label.calculate_histogram

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            completion(.failure(HistogramError.encoderCreationFailed))
            return
        }
        encoder.label = MTL_label.calculate_histogram

        encoder.setComputePipelineState(resolvedPipeline)
        encoder.setTexture(texture, index: 0)

        var encodedChannelCount = UInt8(plan.channelCount)
        var encodedBins = UInt32(plan.bins)
        var encodedVoxelMin = Int16(voxelMin)
        var encodedVoxelMax = Int16(voxelMax)

        encoder.setBytes(&encodedChannelCount, length: MemoryLayout<UInt8>.stride, index: 0)
        encoder.setBytes(&encodedBins, length: MemoryLayout<UInt32>.stride, index: 1)
        encoder.setBytes(&encodedVoxelMin, length: MemoryLayout<Int16>.stride, index: 2)
        encoder.setBytes(&encodedVoxelMax, length: MemoryLayout<Int16>.stride, index: 3)
        encoder.setBuffer(histogramBuffer, offset: 0, index: 4)

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

            var results: [[UInt32]] = []
            results.reserveCapacity(plan.channelCount)

            for channel in 0..<plan.channelCount {
                let offset = channel * plan.bins * MemoryLayout<UInt32>.stride
                let pointer = histogramBuffer.contents().advanced(by: offset).assumingMemoryBound(to: UInt32.self)
                let channelHistogram = Array(UnsafeBufferPointer(start: pointer, count: plan.bins))
                results.append(channelHistogram)
            }
            completion(.success(results))
        }

        commandBuffer.commit()
    }
}

private extension VolumeHistogramCalculator {
    /// Retrieves or creates a cached Metal compute pipeline for the named histogram kernel.
    ///
    /// Implements lazy pipeline state creation with caching to avoid redundant compilation.
    /// On first access for a given kernel name, creates the pipeline from the Metal library
    /// and caches it for subsequent calls.
    ///
    /// - Parameter functionName: Name of the Metal compute function
    ///                           (`computeHistogramThreadgroup` or `computeHistogramLegacy`).
    ///
    /// - Returns: Cached or newly created compute pipeline state, or `nil` if kernel
    ///            function is missing or pipeline creation fails.
    func pipelineState(named functionName: String) -> MTLComputePipelineState? {
        if let cached = pipelineCache[functionName] {
            return cached
        }

        guard let function = library.makeFunction(name: functionName) else {
            logger.error("Função Metal \(functionName) não encontrada.")
            return nil
        }
        function.label = MTL_label.calculate_histogram

        let descriptor = MTLComputePipelineDescriptor()
        descriptor.label = MTL_label.calculate_histogram
        descriptor.computeFunction = function

        do {
            let pipeline = try device.makeComputePipelineState(descriptor: descriptor, options: [], reflection: nil)
            pipelineCache[functionName] = pipeline
            return pipeline
        } catch {
            logger.error("Falha ao criar pipeline de histograma: \(error.localizedDescription)")
            return nil
        }
    }
}
