//
//  MetalVolumeRenderingAdapter.swift
//  MTK
//
//  Volume rendering adapter backed exclusively by Metal compute. Metal resource
//  setup failures are surfaced explicitly during initialization.
//
//  Thales Matheus Mendonça Santos — October 2025

import Foundation
import Metal
import OSLog

/// Metal ray marching renderer backed exclusively by Metal compute.
///
/// `MetalVolumeRenderingAdapter` is the primary interface for volumetric rendering in MTK.
/// This adapter has no MPS dependency and is guaranteed to work on any Metal-capable
/// device that satisfies the package's Metal feature requirements. Metal device,
/// command queue, shader library, compute pipeline, and buffer allocation failures
/// are reported as explicit errors instead of being hidden behind another backend.
///
/// Acceleration structures are intentionally unsupported here: argument index 19
/// (`accelerationTexture`) is never populated by this adapter. That preserves this
/// type as the Metal-only rendering contract.
///
/// ## Overview
///
/// The adapter implements the ``VolumeRenderingPort`` protocol, providing:
/// - Direct Volume Rendering (DVR) with multiple compositing modes
/// - CPU histogram helper for windowing workflows
/// - Advanced tone curve and transfer function support
/// - Diagnostic logging for debugging rendering issues
///
/// ## Usage
///
/// ```swift
/// let adapter = try MetalVolumeRenderingAdapter()
/// adapter.enableDiagnosticLogging(true)
///
/// let request = VolumeRenderRequest(
///     dataset: dataset,
///     camera: camera,
///     viewportSize: (width: 512, height: 512),
///     compositing: .frontToBack,
///     transferFunction: transferFunction
/// )
///
/// let result = try await adapter.renderImage(using: request)
/// ```
///
/// ## Topics
///
/// ### Creating an Adapter
/// - ``init(debugOptions:)``
/// - ``init(device:commandQueue:library:debugOptions:)``
///
/// ### Rendering
/// - ``renderImage(using:)``
/// - ``updatePreset(_:for:)``
///
/// ### Configuration
/// - ``send(_:)``
/// - ``enableDiagnosticLogging(_:)``
///
/// ### Histogram
/// - ``refreshHistogram(for:descriptor:transferFunction:)``
///
/// ### Error Types
/// - ``AdapterError``
/// - ``InitializationError``
/// - ``RenderingError``
///
/// ### Supporting Types
/// - ``Overrides``
/// - ``RenderSnapshot``
public actor MetalVolumeRenderingAdapter: VolumeRenderingPort {
    private typealias ArgumentIndex = ArgumentEncoderManager.ArgumentIndex

    let logger = Logger(subsystem: "com.mtk.volumerendering",
                        category: "MetalVolumeRenderingAdapter")
    var overrides = Overrides()
    internal var extendedState = ExtendedRenderingState()
    var currentPreset: VolumeRenderingPreset?
    var lastSnapshot: RenderSnapshot?
    private let metalState: MetalState
    var diagnosticLoggingEnabled: Bool = false
    var clipPlaneApproximationLogged = false

    struct DatasetIdentity: Equatable, Sendable {
        let count: Int
        let dimensions: VolumeDimensions
        let pixelFormat: VolumePixelFormat
        let contentFingerprint: UInt64

        init(dataset: VolumeDataset) {
            self.count = dataset.data.count
            self.dimensions = dataset.dimensions
            self.pixelFormat = dataset.pixelFormat
            self.contentFingerprint = dataset.data.withUnsafeBytes { buffer in
                var hash: UInt64 = 14_695_981_039_346_656_037
                for byte in buffer.bindMemory(to: UInt8.self) {
                    hash ^= UInt64(byte)
                    hash = hash &* 1_099_511_628_211
                }
                return hash
            }
        }
    }

    final class MetalState: @unchecked Sendable {
        struct TransferCache {
            var transfer: VolumeTransferFunction
            var intensityRange: ClosedRange<Int32>
            var texture: any MTLTexture
        }

        let device: any MTLDevice
        let commandQueue: any MTLCommandQueue
        let pipeline: any MTLComputePipelineState
        let argumentManager: ArgumentEncoderManager
        let dispatchOptimizer: ThreadgroupDispatchOptimizer
        let cameraBuffer: any MTLBuffer
        var datasetIdentity: DatasetIdentity?
        var volumeTexture: (any MTLTexture)?
        var transferCache: TransferCache?
        var frameIndex: UInt32 = 0

        init(device: any MTLDevice,
             commandQueue: any MTLCommandQueue,
             pipeline: any MTLComputePipelineState,
             argumentManager: ArgumentEncoderManager,
             dispatchOptimizer: ThreadgroupDispatchOptimizer,
             cameraBuffer: any MTLBuffer) {
            self.device = device
            self.commandQueue = commandQueue
            self.pipeline = pipeline
            self.argumentManager = argumentManager
            self.dispatchOptimizer = dispatchOptimizer
            self.cameraBuffer = cameraBuffer
        }
    }

    /// Creates a new Metal-backed volume rendering adapter using the system default device.
    ///
    /// Use this convenience initializer when the caller does not need to inject a specific
    /// `MTLDevice`, command queue, or shader library. If the system cannot provide a Metal
    /// device, the initializer throws ``InitializationError/metalDeviceUnavailable``.
    ///
    /// - Parameter debugOptions: Debug configuration options for logging and validation.
    /// - Throws: ``InitializationError/metalDeviceUnavailable`` when `MTLCreateSystemDefaultDevice()`
    ///   returns `nil`, or any error thrown by ``init(device:commandQueue:library:debugOptions:)``.
    public init(debugOptions: VolumeRenderingDebugOptions = VolumeRenderingDebugOptions()) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw InitializationError.metalDeviceUnavailable
        }
        try self.init(device: device, debugOptions: debugOptions)
    }

    /// Creates a new Metal-backed volume rendering adapter.
    ///
    /// This initializer configures the adapter to use Metal compute shaders for
    /// high-performance volume rendering. If the required Metal resources cannot be
    /// initialized, the initializer throws explicit initialization errors.
    ///
    /// - Parameters:
    ///   - device: Metal device for GPU compute operations.
    ///   - commandQueue: Optional command queue. If `nil`, a new queue is created from the device.
    ///   - library: Optional Metal shader library. If `nil`, loads `MTK.metallib` from `Bundle.module`.
    ///   - debugOptions: Debug configuration options for logging and validation.
    ///
    /// - Throws: ``InitializationError/commandQueueCreationFailed`` when a command queue cannot be
    ///   created, ``InitializationError/commandQueueDeviceMismatch`` when an injected command queue
    ///   belongs to another device, ``InitializationError/shaderLibraryUnavailable`` when no shader
    ///   library is available, ``InitializationError/shaderLibraryDeviceMismatch`` when a resolved
    ///   shader library belongs to another device, ``InitializationError/computeFunctionNotFound`` when
    ///   the shader library does not contain `volume_compute`, ``InitializationError/pipelineCreationFailed``
    ///   when the compute pipeline cannot be compiled, or ``InitializationError/cameraBufferAllocationFailed``
    ///   when the camera uniforms buffer cannot be allocated.
    public init(device: any MTLDevice,
                commandQueue: (any MTLCommandQueue)? = nil,
                library: (any MTLLibrary)? = nil,
                debugOptions: VolumeRenderingDebugOptions = VolumeRenderingDebugOptions()) throws {
        let queue: any MTLCommandQueue
        if let commandQueue {
            guard commandQueue.device === device else {
                throw InitializationError.commandQueueDeviceMismatch
            }
            queue = commandQueue
        } else if let createdQueue = device.makeCommandQueue() {
            queue = createdQueue
        } else {
            throw InitializationError.commandQueueCreationFailed
        }

        let lib: any MTLLibrary
        if let library {
            lib = library
        } else {
            do {
                lib = try ShaderLibraryLoader.loadLibrary(for: device)
            } catch let error as ShaderLibraryLoader.LoaderError {
                if debugOptions.isDebugMode {
                    Logger(subsystem: "com.mtk.volumerendering", category: "ShaderLoader")
                        .error("Failed to load MTK.metallib from Bundle.module: \(error.localizedDescription)")
                }
                throw InitializationError.shaderLibraryUnavailable
            } catch {
                throw InitializationError.shaderLibraryUnavailable
            }
        }

        guard lib.device === device else {
            throw InitializationError.shaderLibraryDeviceMismatch
        }

        guard let function = lib.makeFunction(name: "volume_compute") else {
            throw InitializationError.computeFunctionNotFound
        }

        let pipeline: any MTLComputePipelineState
        do {
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw InitializationError.pipelineCreationFailed
        }

        let argumentManager = ArgumentEncoderManager(
            device: device,
            mtlFunction: function,
            debugOptions: debugOptions
        )
        let dispatchOptimizer = ThreadgroupDispatchOptimizer(debugOptions: debugOptions)
        guard let cameraBuffer = device.makeBuffer(length: CameraUniforms.stride,
                                                   options: [.storageModeShared])
        else {
            throw InitializationError.cameraBufferAllocationFailed
        }
        cameraBuffer.label = "VolumeCompute.CameraUniforms"

        self.metalState = MetalState(device: device,
                                     commandQueue: queue,
                                     pipeline: pipeline,
                                     argumentManager: argumentManager,
                                     dispatchOptimizer: dispatchOptimizer,
                                     cameraBuffer: cameraBuffer)
    }

    /// Enables or disables diagnostic logging for debugging rendering issues.
    ///
    /// When enabled, the adapter logs detailed information about:
    /// - Render requests (viewport, compositing mode, quality)
    /// - Applied overrides (compositing, sampling distance, window)
    /// - Camera matrices (view, projection, inverse view-projection)
    ///
    /// - Parameter enabled: Whether to enable diagnostic logging.
    ///
    /// - Note: Diagnostic logs use `os_log` with the `com.mtk.volumerendering` subsystem.
    public func enableDiagnosticLogging(_ enabled: Bool) {
        diagnosticLoggingEnabled = enabled
        if enabled {
            logger.info("Diagnostic logging enabled on MetalVolumeRenderingAdapter.")
        } else {
            logger.info("Diagnostic logging disabled on MetalVolumeRenderingAdapter.")
        }
    }

    /// Renders a volumetric image from the provided request.
    ///
    /// This is the primary rendering method. It renders via Metal compute shaders and
    /// propagates Metal operation errors to the caller.
    ///
    /// - Parameter request: A ``VolumeRenderRequest`` specifying the dataset, camera,
    ///   viewport, compositing mode, and transfer function.
    ///
    /// - Returns: A ``VolumeRenderResult`` containing the rendered image and metadata.
    ///
    /// - Throws: ``AdapterError/windowNotSpecified`` when no explicit or recommended window is
    ///   available, ``AdapterError/emptyColorPoints`` or ``AdapterError/emptyAlphaPoints`` when
    ///   the transfer function is incomplete, ``AdapterError/degenerateCameraMatrix`` when the
    ///   camera basis is invalid, or Metal operation errors such as texture creation, command
    ///   buffer creation, command encoding, or command buffer execution failure.
    ///
    /// ## GPU Acceleration
    ///
    /// Metal resources are initialized eagerly by ``init(device:commandQueue:library:debugOptions:)``.
    ///
    /// ## Parameter Overrides
    ///
    /// The adapter applies overrides set via ``send(_:)`` in this order:
    /// 1. Compositing mode (if override set)
    /// 2. Sampling distance (if override set)
    /// 3. Intensity window (extended state → override → recommended; throws if absent)
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let request = VolumeRenderRequest(
    ///     dataset: dataset,
    ///     camera: VolumeRenderRequest.Camera(
    ///         position: SIMD3<Float>(0.5, 0.5, 2),
    ///         target: SIMD3<Float>(0.5, 0.5, 0.5),
    ///         up: SIMD3<Float>(0, 1, 0),
    ///         fieldOfView: 45,
    ///         projectionType: .perspective
    ///     ),
    ///     viewportSize: (width: 512, height: 512),
    ///     samplingDistance: 0.002,
    ///     compositing: .frontToBack,
    ///     quality: .balanced,
    ///     transferFunction: transferFunction
    /// )
    ///
    /// let result = try await adapter.renderImage(using: request)
    /// let image = result.cgImage
    /// ```
    public func renderImage(using request: VolumeRenderRequest) async throws -> VolumeRenderResult {
        if diagnosticLoggingEnabled {
            logger.info("[DIAG] renderImage called - viewport: \(request.viewportSize.width)x\(request.viewportSize.height), compositing: \(String(describing: request.compositing)), quality: \(String(describing: request.quality))")
        }

        var effectiveRequest = request

        if let compositing = overrides.compositing {
            effectiveRequest.compositing = compositing
            if diagnosticLoggingEnabled {
                logger.info("[DIAG] Applied compositing override: \(String(describing: compositing))")
            }
        }
        if let samplingDistance = overrides.samplingDistance {
            effectiveRequest.samplingDistance = samplingDistance
            if diagnosticLoggingEnabled {
                logger.info("[DIAG] Applied sampling distance override: \(samplingDistance)")
            }
        }

        let window = try resolveWindow(for: effectiveRequest.dataset)

        if diagnosticLoggingEnabled {
            logger.info("[DIAG] Using window: \(window.lowerBound)...\(window.upperBound)")
        }

        let result = try await renderWithMetal(state: metalState, request: effectiveRequest)
        lastSnapshot = RenderSnapshot(dataset: request.dataset,
                                      metadata: result.metadata,
                                      window: window)
        return result
    }

    /// Updates the active rendering preset for a dataset.
    ///
    /// Presets define common rendering configurations (e.g., CT Bone, CT Soft Tissue, MR Angio)
    /// that combine transfer functions, windowing, and other parameters.
    ///
    /// - Parameters:
    ///   - preset: The rendering preset to apply.
    ///   - dataset: The dataset for which the preset should be applied.
    ///
    /// - Returns: An array containing the applied preset (for compatibility with batch operations).
    ///
    /// - Note: The preset is stored internally but currently does not automatically modify
    ///   rendering parameters. Future implementations may apply preset-specific settings
    ///   to transfer functions, windowing, and quality.
    public func updatePreset(_ preset: VolumeRenderingPreset,
                             for dataset: VolumeDataset) async throws -> [VolumeRenderingPreset] {
        if diagnosticLoggingEnabled {
            logger.info("[DIAG] updatePreset called - preset: \(preset.name)")
        }
        currentPreset = preset
        return [preset]
    }

    /// Calculates an intensity histogram for the given dataset.
    ///
    /// The histogram is computed on the CPU using a detached task to avoid blocking
    /// the main actor. This method scans all voxels in the dataset and bins them
    /// according to the descriptor's intensity range and bin count.
    ///
    /// - Parameters:
    ///   - dataset: The volume dataset to analyze.
    ///   - descriptor: Configuration specifying bin count, intensity range, and normalization.
    ///   - transferFunction: Transfer function for context (currently unused).
    ///
    /// - Returns: A ``VolumeHistogram`` containing the binned intensity distribution.
    ///
    /// - Throws: ``AdapterError/invalidHistogramBinCount`` if `descriptor.binCount` is 0, or
    ///   ``AdapterError/datasetReadFailed`` if a voxel reader cannot be created for the dataset.
    ///
    /// ## Performance
    ///
    /// CPU histogram calculation time scales linearly with voxel count:
    /// - 256×256×256 volume: ~10-20ms
    /// - 512×512×512 volume: ~80-120ms
    ///
    /// For GPU-accelerated histogram calculation, use the pure Metal compute
    /// ``VolumeHistogramCalculator``.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let descriptor = VolumeHistogramDescriptor(
    ///     binCount: 256,
    ///     intensityRange: -1024...3071,
    ///     normalize: true
    /// )
    ///
    /// let histogram = try await adapter.refreshHistogram(
    ///     for: dataset,
    ///     descriptor: descriptor,
    ///     transferFunction: transferFunction
    /// )
    ///
    /// // Histogram bins sum to 1.0 if normalize = true
    /// print("Total: \(histogram.bins.reduce(0, +))")
    /// ```
    public func refreshHistogram(for dataset: VolumeDataset,
                                 descriptor: VolumeHistogramDescriptor,
                                 transferFunction: VolumeTransferFunction) async throws -> VolumeHistogram {
        guard descriptor.binCount > 0 else {
            throw AdapterError.invalidHistogramBinCount
        }

        let bins = try await Task.detached(priority: .userInitiated) {
            try dataset.data.withUnsafeBytes { buffer throws -> [Float] in
                guard let reader = VolumeDataReader(dataset: dataset, buffer: buffer) else {
                    throw AdapterError.datasetReadFailed
                }

                let binCount = descriptor.binCount
                var histogram = [Float](repeating: 0, count: binCount)

                let lowerBound = descriptor.intensityRange.lowerBound
                let upperBound = descriptor.intensityRange.upperBound
                let span = max(upperBound - lowerBound, Float.leastNonzeroMagnitude)
                let binWidth = span / Float(binCount)

                reader.forEachIntensity { sample in
                    let clamped = VolumetricMath.clampFloat(sample, lower: lowerBound, upper: upperBound)
                    var index = Int((clamped - lowerBound) / binWidth)
                    if index >= binCount {
                        index = binCount - 1
                    }
                    histogram[index] += 1
                }

                if descriptor.normalize {
                    let total = histogram.reduce(0, +)
                    if total > 0 {
                        for index in histogram.indices {
                            histogram[index] /= total
                        }
                    }
                }

                return histogram
            }
        }.value

        return VolumeHistogram(descriptor: descriptor, bins: bins)
    }

    /// Sends a rendering command to update render parameters.
    ///
    /// Commands set persistent overrides that apply to all subsequent ``renderImage(using:)`` calls
    /// until changed or cleared.
    ///
    /// - Parameter command: The command to execute.
    ///
    /// - Throws: Commands are processed synchronously and do not currently throw errors.
    ///
    /// ## Available Commands
    ///
    /// - ``VolumeRenderingCommand/setCompositing(_:)`` - Override compositing mode (DVR, MIP, MinIP, AIP)
    /// - ``VolumeRenderingCommand/setWindow(_:_:)`` - Override intensity window (HU min/max)
    /// - ``VolumeRenderingCommand/setSamplingStep(_:)`` - Override ray marching step size
    /// - ``VolumeRenderingCommand/setLighting(_:)`` - Enable/disable lighting calculations
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Change to Maximum Intensity Projection
    /// try await adapter.send(.setCompositing(.maximumIntensity))
    ///
    /// // Adjust CT window for bone visualization
    /// try await adapter.send(.setWindow(-500, 1300))
    ///
    /// // Reduce sampling distance for higher quality
    /// try await adapter.send(.setSamplingStep(0.001))
    ///
    /// // Disable lighting for pure intensity visualization
    /// try await adapter.send(.setLighting(false))
    /// ```
    public func send(_ command: VolumeRenderingCommand) async throws {
        if diagnosticLoggingEnabled {
            logger.info("[DIAG] send command: \(String(describing: command))")
        }
        switch command {
        case .setCompositing(let compositing):
            overrides.compositing = compositing
            if diagnosticLoggingEnabled {
                logger.info("[DIAG] Set compositing: \(String(describing: compositing))")
            }
        case .setWindow(let minValue, let maxValue):
            overrides.window = minValue...maxValue
            if diagnosticLoggingEnabled {
                logger.info("[DIAG] Set window: \(minValue)...\(maxValue)")
            }
        case .setSamplingStep(let samplingDistance):
            overrides.samplingDistance = samplingDistance
            if diagnosticLoggingEnabled {
                logger.info("[DIAG] Set sampling distance: \(samplingDistance)")
            }
        case .setLighting(let enabled):
            overrides.lightingEnabled = enabled
            if diagnosticLoggingEnabled {
                logger.info("[DIAG] Set lighting: \(enabled)")
            }
        }
    }
}

extension MetalVolumeRenderingAdapter {
    @_spi(Testing)
    public var debugTransferCacheTexture: (any MTLTexture)? {
        metalState.transferCache?.texture
    }
}
