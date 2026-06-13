//
//  MetalMPRComputeAdapter.swift
//  MTK
//
//  GPU-accelerated implementation of the multi-planar reconstruction adapter.
//  Leverages Metal compute shaders for high-performance slab generation with
//  support for MIP, MinIP, and average blend modes.
//
//  Thales Matheus Mendonça Santos — February 2026

import Foundation
import Metal
#if canImport(MetalPerformanceShaders)
import MetalPerformanceShaders
#endif
import OSLog
import simd

typealias MPRPipelineStateFactory = (MTLComputePipelineDescriptor) throws -> MTLComputePipelineState

@preconcurrency
public actor MetalMPRComputeAdapter: MPRReslicePort {
    public enum ComputeError: Error {
        case pipelineUnavailable
        case commandQueueUnavailable
        case commandBufferCreationFailed
        case encoderCreationFailed
        case volumeTextureCreationFailed
        case outputTextureCreationFailed
        case outputBufferAllocationFailed
        case invalidComputeConfiguration(String)
    }

    public struct Overrides: Equatable {
        var blend: MPRBlendMode?
        var slabThickness: Int?
        var slabSteps: Int?
    }

    public struct SliceSnapshot: Equatable {
        var axis: MPRPlaneAxis
        var intensityRange: ClosedRange<Int32>
        var blend: MPRBlendMode
        var thickness: Int
        var steps: Int
    }

    private let device: any MTLDevice
    private let featureFlags: FeatureFlags
    private let commandQueue: any MTLCommandQueue
    private let library: any MTLLibrary
    private let debugOptions: VolumeRenderingDebugOptions
    private let pipelineStateFactory: MPRPipelineStateFactory
    private var pipelineCache: [String: MTLComputePipelineState] = [:]
    private var unavailablePipelineNames: Set<String> = []
    private var cachedVolumeTexture: (any MTLTexture)?
    private var cachedDatasetIdentity: DatasetIdentity.Content?
    private(set) var textureUploadCount: Int = 0
    private let outputTexturePool: OutputTexturePool
    private var outputTextureAllocationCount = 0
    private var overrides = Overrides()
    private var lastSnapshot: SliceSnapshot?
    private let mpsAvailable: Bool
    private let logger = Logger(subsystem: "com.mtk.volumerendering",
                                category: "MetalMPRCompute")

    public init(device: any MTLDevice,
                commandQueue: any MTLCommandQueue,
                library: any MTLLibrary,
                featureFlags: FeatureFlags,
                debugOptions: VolumeRenderingDebugOptions) {
        self.init(device: device,
                  commandQueue: commandQueue,
                  library: library,
                  featureFlags: featureFlags,
                  debugOptions: debugOptions,
                  pipelineStateFactory: nil)
    }

    init(device: any MTLDevice,
         commandQueue: any MTLCommandQueue,
         library: any MTLLibrary,
         featureFlags: FeatureFlags,
         debugOptions: VolumeRenderingDebugOptions,
         pipelineStateFactory: MPRPipelineStateFactory?) {
        self.device = device
        self.featureFlags = featureFlags
        self.commandQueue = commandQueue
        self.library = library
        self.debugOptions = debugOptions
        self.outputTexturePool = OutputTexturePool(featureFlags: featureFlags)
        self.pipelineStateFactory = pipelineStateFactory ?? { descriptor in
            try device.makeComputePipelineState(descriptor: descriptor,
                                                options: [],
                                                reflection: nil)
        }

        // Check MPS availability for potential texture operation optimizations
        #if canImport(MetalPerformanceShaders)
        self.mpsAvailable = MPSSupportsMTLDevice(device)
        #else
        self.mpsAvailable = false
        #endif
    }

    public func makeTextureFrame(dataset: VolumeDataset,
                                 plane: MPRPlaneGeometry,
                                 thickness: Int,
                                 steps: Int,
                                 blend: MPRBlendMode) async throws -> MPRTextureFrame {
        let volumeTexture = try provideVolumeTexture(for: dataset)
        return try await makeSlabTexture(dataset: dataset,
                                         volumeTexture: volumeTexture,
                                         plane: plane,
                                         thickness: thickness,
                                         steps: steps,
                                         blend: blend)
    }

    public func makeSlabTexture(dataset: VolumeDataset,
                                volumeTexture: any MTLTexture,
                                plane: MPRPlaneGeometry,
                                thickness: Int,
                                steps: Int,
                                blend: MPRBlendMode) async throws -> MPRTextureFrame {
        try await makeSlabTexture(dataset: dataset,
                                  volumeTexture: volumeTexture,
                                  plane: plane,
                                  thickness: thickness,
                                  steps: steps,
                                  blend: blend,
                                  viewportID: nil)
    }

    func makeSlabTexture(dataset: VolumeDataset,
                         volumeTexture: any MTLTexture,
                         plane: MPRPlaneGeometry,
                         thickness: Int,
                         steps: Int,
                         blend: MPRBlendMode,
                         viewportID: ViewportID?) async throws -> MPRTextureFrame {
        let effectiveBlend = overrides.blend ?? blend
        let effectiveThickness = VolumetricMath.sanitizeThickness(overrides.slabThickness ?? thickness)
        let effectiveSteps = VolumetricMath.sanitizeSteps(overrides.slabSteps ?? steps)
        overrides = Overrides()

        let pipeline = try await getPipelineState(for: dataset.pixelFormat)
        let (width, height) = sliceDimensions(for: plane)
        let outputTextureLease = try provideOutputTextureLease(width: width,
                                                               height: height,
                                                               pixelFormat: dataset.pixelFormat)
        let outputTexture = outputTextureLease.texture

        var uniforms = try createUniforms(dataset: dataset,
                                          plane: plane,
                                          thickness: effectiveThickness,
                                          steps: effectiveSteps,
                                          blend: effectiveBlend)

        let timings: CommandBufferTimings
        do {
            timings = try await dispatchCompute(pipeline: pipeline,
                                                volumeTexture: volumeTexture,
                                                outputTexture: outputTexture,
                                                uniforms: &uniforms,
                                                width: width,
                                                height: height)
        } catch {
            outputTextureLease.release()
            throw error
        }
        ClinicalProfiler.shared.recordSample(
            stage: .mprReslice,
            cpuTime: timings.cpuTime,
            gpuTime: timings.gpuTime > 0 ? timings.gpuTime : nil,
            memory: ResourceMemoryEstimator.estimate(for: outputTexture),
            viewport: ProfilingViewportContext(width: width,
                                                       height: height,
                                                       viewportType: "mpr",
                                                       quality: "unknown",
                                                       renderMode: effectiveBlend),
            metadata: [
                "path": "MetalMPRComputeAdapter.makeSlabTexture",
                "kernelTimeMilliseconds": String(format: "%.6f", timings.kernelTime),
                "thickness": String(effectiveThickness),
                "steps": String(effectiveSteps)
            ],
            device: device
        )

        let axis = dominantAxis(for: plane)
        lastSnapshot = SliceSnapshot(axis: axis,
                                     intensityRange: dataset.intensityRange,
                                     blend: effectiveBlend,
                                     thickness: effectiveThickness,
                                     steps: effectiveSteps)

        return MPRTextureFrame(texture: outputTexture,
                               intensityRange: dataset.intensityRange,
                               pixelFormat: dataset.pixelFormat,
                               viewportID: viewportID,
                               planeGeometry: plane,
                               outputTextureLease: outputTextureLease)
    }

    public func send(_ command: MPRResliceCommand) async throws {
        switch command {
        case .setBlend(let mode):
            overrides.blend = mode
        case .setSlab(let thickness, let steps):
            overrides.slabThickness = VolumetricMath.sanitizeThickness(thickness)
            overrides.slabSteps = VolumetricMath.sanitizeSteps(steps)
        }
    }
}

// MARK: - Testing SPI

extension MetalMPRComputeAdapter {
    @_spi(Testing)
    public var debugOverrides: Overrides { overrides }

    @_spi(Testing)
    public var debugLastSnapshot: SliceSnapshot? { lastSnapshot }

    @_spi(Testing)
    public var debugMPSAvailable: Bool { mpsAvailable }

    @_spi(Testing)
    public var debugTextureUploadCount: Int { textureUploadCount }

    @_spi(Testing)
    public var debugOutputTextureAllocationCount: Int { outputTextureAllocationCount }

    @_spi(Testing)
    public var debugUnavailablePipelineNames: Set<String> { unavailablePipelineNames }

    @_spi(Testing)
    public var debugCachedDatasetIdentity: (
        count: Int,
        dimensions: VolumeDimensions,
        pixelFormat: VolumePixelFormat,
        contentFingerprint: UInt64
    )? {
        guard let cachedDatasetIdentity else { return nil }
        return (
            count: cachedDatasetIdentity.byteCount,
            dimensions: cachedDatasetIdentity.dimensions,
            pixelFormat: cachedDatasetIdentity.pixelFormat,
            contentFingerprint: cachedDatasetIdentity.contentFingerprint
        )
    }
}

// MARK: - Pipeline Management

private extension MetalMPRComputeAdapter {
    func getPipelineState(for pixelFormat: VolumePixelFormat) async throws -> MTLComputePipelineState {
        let functionName = pixelFormat.mprSlabKernelName
        if let cached = pipelineCache[functionName] {
            return cached
        }
        if unavailablePipelineNames.contains(functionName) {
            throw ComputeError.pipelineUnavailable
        }

        guard let function = library.makeFunction(name: functionName) else {
            unavailablePipelineNames.insert(functionName)
            logger.error("Metal function \(functionName) not found")
            throw ComputeError.pipelineUnavailable
        }
        function.label = functionName

        let descriptor = MTLComputePipelineDescriptor()
        descriptor.label = "mpr_slab_compute.\(functionName)"
        descriptor.computeFunction = function

        do {
            let pipeline = try pipelineStateFactory(descriptor)
            pipelineCache[functionName] = pipeline
            return pipeline
        } catch {
            unavailablePipelineNames.insert(functionName)
            logger.error("Failed to create MPR compute pipeline: \(error.localizedDescription)")
            throw ComputeError.pipelineUnavailable
        }
    }
}

// MARK: - Texture Creation

private extension MetalMPRComputeAdapter {
    /// Provide a 3D Metal texture for the given dataset, reusing a cached texture when the dataset identity is unchanged.
    /// - Parameters:
    ///   - dataset: The volume dataset to produce a Metal 3D texture for; its identity is used to decide cache reuse.
    /// - Returns: A Metal texture representing the dataset volume.
    /// - Throws: `ComputeError.volumeTextureCreationFailed` if a new volume texture cannot be created.
    func provideVolumeTexture(for dataset: VolumeDataset) throws -> any MTLTexture {
        let identity = DatasetIdentity.Content(dataset: dataset)
        if let cachedVolumeTexture, cachedDatasetIdentity == identity {
            return cachedVolumeTexture
        }

        let factory = VolumeTextureFactory(dataset: dataset)
        guard let texture = factory.generate(device: device) else {
            logger.error("Failed to create volume texture")
            throw ComputeError.volumeTextureCreationFailed
        }
        texture.label = "MPR.volumeTexture"

        cachedVolumeTexture = texture
        cachedDatasetIdentity = identity
        textureUploadCount += 1

        return texture
    }

    func provideOutputTextureLease(width: Int,
                                   height: Int,
                                   pixelFormat: VolumePixelFormat) throws -> OutputTextureLease {
        let textureCountBeforeAcquire = outputTexturePool.debugTextureCount
        do {
            let lease = try outputTexturePool.acquireWithLease(width: width,
                                                               height: height,
                                                               pixelFormat: pixelFormat.metalPixelFormat,
                                                               device: device)
            let textureCountAfterAcquire = outputTexturePool.debugTextureCount
            outputTextureAllocationCount += max(0, textureCountAfterAcquire - textureCountBeforeAcquire)
            lease.texture.label = "MPR.outputTexture"
            return lease
        } catch let error as OutputTexturePool.PoolError {
            switch error {
            case .invalidDimensions(let width, let height):
                throw ComputeError.invalidComputeConfiguration(
                    "MPR output texture dimensions must be positive, got \(width)x\(height)."
                )
            case .textureCreationFailed:
                logger.error("Failed to create output texture (\(width)x\(height))")
                throw ComputeError.outputTextureCreationFailed
            }
        }
    }
}

// MARK: - Uniforms

private extension MetalMPRComputeAdapter {
    struct MPRSlabUniforms {
        var voxelMinValue: Int32
        var voxelMaxValue: Int32
        var blendMode: Int32
        var numSteps: Int32
        var slabHalf: Float
        var _pad0: SIMD3<Float>

        var planeOrigin: SIMD3<Float>
        var _pad1: Float
        var planeX: SIMD3<Float>
        var _pad2: Float
        var planeY: SIMD3<Float>
        var _pad3: Float
    }

    static func assertMPRSlabUniformLayout() {
        assert(MemoryLayout<MPRSlabUniforms>.size == 132)
        assert(MemoryLayout<MPRSlabUniforms>.stride == 144)
        assert(MemoryLayout<MPRSlabUniforms>.offset(of: \.voxelMinValue) == 0)
        assert(MemoryLayout<MPRSlabUniforms>.offset(of: \.voxelMaxValue) == 4)
        assert(MemoryLayout<MPRSlabUniforms>.offset(of: \.blendMode) == 8)
        assert(MemoryLayout<MPRSlabUniforms>.offset(of: \.numSteps) == 12)
        assert(MemoryLayout<MPRSlabUniforms>.offset(of: \.slabHalf) == 16)
        assert(MemoryLayout<MPRSlabUniforms>.offset(of: \._pad0) == 32)
        assert(MemoryLayout<MPRSlabUniforms>.offset(of: \.planeOrigin) == 48)
        assert(MemoryLayout<MPRSlabUniforms>.offset(of: \.planeX) == 80)
        assert(MemoryLayout<MPRSlabUniforms>.offset(of: \.planeY) == 112)
    }

    func createUniforms(dataset: VolumeDataset,
                        plane: MPRPlaneGeometry,
                        thickness: Int,
                        steps: Int,
                        blend: MPRBlendMode) throws -> MPRSlabUniforms {
#if DEBUG
        Self.assertMPRSlabUniformLayout()
#endif
        let slabHalf = MPRPlaneGeometryFactory.normalizedTextureThickness(
            for: Float(thickness),
            dataset: dataset,
            plane: plane
        ) / 2

        return MPRSlabUniforms(
            voxelMinValue: Int32(dataset.intensityRange.lowerBound),
            voxelMaxValue: Int32(dataset.intensityRange.upperBound),
            blendMode: Int32(blend.rawValue),
            numSteps: Int32(steps),
            slabHalf: slabHalf,
            _pad0: SIMD3<Float>(0, 0, 0),
            planeOrigin: plane.originTexture,
            _pad1: 0,
            planeX: plane.axisUTexture,
            _pad2: 0,
            planeY: plane.axisVTexture,
            _pad3: 0
        )
    }
}

// MARK: - Compute Dispatch

private extension MetalMPRComputeAdapter {
    func dispatchCompute(pipeline: MTLComputePipelineState,
                         volumeTexture: any MTLTexture,
                         outputTexture: any MTLTexture,
                         uniforms: inout MPRSlabUniforms,
                         width: Int,
                         height: Int) async throws -> CommandBufferTimings {
        guard width > 0, height > 0 else {
            throw ComputeError.invalidComputeConfiguration("MPR compute dimensions must be positive, got \(width)x\(height).")
        }
        guard pipeline.device.registryID == commandQueue.device.registryID,
              volumeTexture.device.registryID == commandQueue.device.registryID,
              outputTexture.device.registryID == commandQueue.device.registryID else {
            throw ComputeError.invalidComputeConfiguration("MPR compute resources must belong to the command queue device.")
        }
        guard outputTexture.width >= width,
              outputTexture.height >= height else {
            throw ComputeError.invalidComputeConfiguration("MPR output texture \(outputTexture.width)x\(outputTexture.height) is smaller than dispatch \(width)x\(height).")
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw ComputeError.commandBufferCreationFailed
        }
        let cpuStart = CFAbsoluteTimeGetCurrent()
        commandBuffer.label = "mpr_slab_compute"

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw ComputeError.encoderCreationFailed
        }
        encoder.label = "mpr_slab_compute"

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(volumeTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<MPRSlabUniforms>.stride, index: 0)

        // Calculate threadgroup configuration
        let configuration = ThreadgroupDispatchConfiguration.default(for: pipeline)
        let threadsPerThreadgroup = configuration.threadsPerThreadgroup
        let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)

        MetalDispatch.dispatch(encoder: encoder,
                               threadsPerGrid: threadsPerGrid,
                               threadsPerThreadgroup: threadsPerThreadgroup,
                               featureFlags: featureFlags)

        encoder.endEncoding()

        let cpuEnd = CFAbsoluteTimeGetCurrent()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            commandBuffer.addCompletedHandler { buffer in
                if let error = buffer.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
            commandBuffer.commit()
        }
        return commandBuffer.timings(cpuStart: cpuStart,
                                     cpuEnd: cpuEnd)
    }
}

// MARK: - Helpers

private extension MetalMPRComputeAdapter {
    func dominantAxis(for plane: MPRPlaneGeometry) -> MPRPlaneAxis {
        let normal = plane.normalWorld
        let components = [abs(normal.x), abs(normal.y), abs(normal.z)]
        let index = components.enumerated().max(by: { $0.element < $1.element })?.offset ?? 2
        return MPRPlaneAxis(rawValue: index) ?? .z
    }

    func sliceDimensions(for plane: MPRPlaneGeometry) -> (width: Int, height: Int) {
        if let outputWidth = plane.outputWidth,
           let outputHeight = plane.outputHeight {
            return (max(1, outputWidth), max(1, outputHeight))
        }
        let width = max(1, Int(round(simd_length(plane.axisUVoxel))) + 1)
        let height = max(1, Int(round(simd_length(plane.axisVVoxel))) + 1)
        return (width, height)
    }

}
// MARK: - VolumePixelFormat Extension

private extension VolumePixelFormat {
    var metalPixelFormat: MTLPixelFormat {
        rawIntensityMetalPixelFormat
    }

    var mprSlabKernelName: String {
        switch self {
        case .int16Signed:
            return "computeMPRSlab"
        case .int16Unsigned:
            return "computeMPRSlabUnsigned"
        }
    }
}
