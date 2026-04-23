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

private struct DatasetIdentity: Equatable, Sendable {
    let pointer: UInt
    let count: Int
    let dimensions: VolumeDimensions
    let pixelFormat: VolumePixelFormat
    let contentFingerprint: UInt64

    init(dataset: VolumeDataset) {
        self.count = dataset.data.count
        self.dimensions = dataset.dimensions
        self.pixelFormat = dataset.pixelFormat
        self.pointer = dataset.data.withUnsafeBytes { buffer in
            buffer.baseAddress.map { UInt(bitPattern: $0) } ?? 0
        }
        self.contentFingerprint = DatasetContentFingerprint.make(for: dataset.data)
    }

    static func == (lhs: DatasetIdentity, rhs: DatasetIdentity) -> Bool {
        lhs.count == rhs.count &&
        lhs.dimensions == rhs.dimensions &&
        lhs.pixelFormat == rhs.pixelFormat &&
        lhs.contentFingerprint == rhs.contentFingerprint
    }

}

private struct OutputTextureShape: Equatable, Sendable {
    let width: Int
    let height: Int
    let pixelFormat: VolumePixelFormat
}

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
    private var pipelineCache: [String: MTLComputePipelineState] = [:]
    private var cachedVolumeTexture: (any MTLTexture)?
    private var cachedDatasetIdentity: DatasetIdentity?
    private(set) var textureUploadCount: Int = 0
    private var cachedOutputTexture: (any MTLTexture)?
    private var cachedOutputShape: OutputTextureShape?
    private var outputTextureInFlight = false
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
        self.device = device
        self.featureFlags = featureFlags
        self.commandQueue = commandQueue
        self.library = library
        self.debugOptions = debugOptions

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
        let outputTexture = try provideOutputTexture(width: width,
                                                     height: height,
                                                     pixelFormat: dataset.pixelFormat)
        let outputTextureUsesCache = isCachedOutputTexture(outputTexture)
        if outputTextureUsesCache {
            outputTextureInFlight = true
        }
        defer {
            if outputTextureUsesCache {
                outputTextureInFlight = false
            }
        }

        var uniforms = try createUniforms(dataset: dataset,
                                          plane: plane,
                                          thickness: effectiveThickness,
                                          steps: effectiveSteps,
                                          blend: effectiveBlend)

        let timings = try await dispatchCompute(pipeline: pipeline,
                                                volumeTexture: volumeTexture,
                                                outputTexture: outputTexture,
                                                uniforms: &uniforms,
                                                width: width,
                                                height: height)
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

        let resultTexture = outputTextureUsesCache
            ? try await makeOutputTextureCopy(of: outputTexture,
                                              width: width,
                                              height: height,
                                              pixelFormat: dataset.pixelFormat)
            : outputTexture

        let axis = dominantAxis(for: plane)
        lastSnapshot = SliceSnapshot(axis: axis,
                                     intensityRange: dataset.intensityRange,
                                     blend: effectiveBlend,
                                     thickness: effectiveThickness,
                                     steps: effectiveSteps)

        return MPRTextureFrame(texture: resultTexture,
                               intensityRange: dataset.intensityRange,
                               pixelFormat: dataset.pixelFormat,
                               viewportID: viewportID,
                               planeGeometry: plane)
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
    public var debugCachedOutputTextureShape: (
        width: Int,
        height: Int,
        pixelFormat: VolumePixelFormat
    )? {
        guard let cachedOutputShape else { return nil }
        return (
            width: cachedOutputShape.width,
            height: cachedOutputShape.height,
            pixelFormat: cachedOutputShape.pixelFormat
        )
    }

    @_spi(Testing)
    public var debugCachedDatasetIdentity: (
        pointer: UInt,
        count: Int,
        dimensions: VolumeDimensions,
        pixelFormat: VolumePixelFormat,
        contentFingerprint: UInt64
    )? {
        guard let cachedDatasetIdentity else { return nil }
        return (
            pointer: cachedDatasetIdentity.pointer,
            count: cachedDatasetIdentity.count,
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

        guard let function = library.makeFunction(name: functionName) else {
            logger.error("Metal function \(functionName) not found")
            throw ComputeError.pipelineUnavailable
        }
        function.label = functionName

        let descriptor = MTLComputePipelineDescriptor()
        descriptor.label = "mpr_slab_compute.\(functionName)"
        descriptor.computeFunction = function

        do {
            let pipeline = try device.makeComputePipelineState(descriptor: descriptor,
                                                               options: [],
                                                               reflection: nil)
            pipelineCache[functionName] = pipeline
            return pipeline
        } catch {
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
        let identity = DatasetIdentity(dataset: dataset)
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

    func provideOutputTexture(width: Int,
                              height: Int,
                              pixelFormat: VolumePixelFormat) throws -> any MTLTexture {
        let shape = OutputTextureShape(width: width,
                                       height: height,
                                       pixelFormat: pixelFormat)

        if let cachedOutputTexture,
           cachedOutputShape == shape,
           !outputTextureInFlight {
            return cachedOutputTexture
        }

        // Do not replace the cached texture while a command buffer may still be writing to it.
        if outputTextureInFlight {
            return try createOutputTexture(width: width,
                                           height: height,
                                           pixelFormat: pixelFormat)
        }

        let texture = try createOutputTexture(width: width,
                                              height: height,
                                              pixelFormat: pixelFormat)
        cachedOutputTexture = texture
        cachedOutputShape = shape

        return texture
    }

    func createOutputTexture(width: Int,
                             height: Int,
                             pixelFormat: VolumePixelFormat) throws -> any MTLTexture {
        // StorageModePolicy.md: MPR compute output textures are GPU-only intermediates.
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2D
        descriptor.pixelFormat = pixelFormat.metalPixelFormat
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.width = width
        descriptor.height = height
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            logger.error("Failed to create output texture (\(width)x\(height))")
            throw ComputeError.outputTextureCreationFailed
        }
        outputTextureAllocationCount += 1
        texture.label = "MPR.outputTexture"

        return texture
    }

    func isCachedOutputTexture(_ texture: any MTLTexture) -> Bool {
        guard let cachedOutputTexture else { return false }
        return (texture as AnyObject) === (cachedOutputTexture as AnyObject)
    }

    func makeOutputTextureCopy(of source: any MTLTexture,
                               width: Int,
                               height: Int,
                               pixelFormat: VolumePixelFormat) async throws -> any MTLTexture {
        let destination = try createOutputTexture(width: width,
                                                  height: height,
                                                  pixelFormat: pixelFormat)
        destination.label = "MPR.outputTexture.copy"

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw ComputeError.commandBufferCreationFailed
        }
        commandBuffer.label = "mpr_output_texture_copy"

        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw ComputeError.encoderCreationFailed
        }
        blitEncoder.label = "mpr_output_texture_copy"
        blitEncoder.copy(
            from: source,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: destination,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            commandBuffer.addCompletedHandler { buffer in
                if let error = buffer.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
            commandBuffer.commit()
        }

        return destination
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

        if featureFlags.contains(.nonUniformThreadgroups) {
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        } else {
            let groups = MTLSize(
                width: (threadsPerGrid.width + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width,
                height: (threadsPerGrid.height + threadsPerThreadgroup.height - 1) / threadsPerThreadgroup.height,
                depth: 1
            )
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerThreadgroup)
        }

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
        let width = max(1, Int(round(simd_length(plane.axisUVoxel))) + 1)
        let height = max(1, Int(round(simd_length(plane.axisVVoxel))) + 1)
        return (width, height)
    }

}

// MARK: - MPS Optimization Support

#if canImport(MetalPerformanceShaders)
private extension MetalMPRComputeAdapter {
    /// Metal blit baseline with optional MPS optimization.
    ///
    /// The blit encoder path is first-class and fully supported. MPS provides
    /// optimized conversion for compatible 2D normalized/float formats when available.
    /// 3D textures and signed integer formats use the Metal blit baseline by design
    /// because MPS image conversion does not cover those texture cases.
    ///
    /// - Parameters:
    ///   - commandBuffer: Command buffer to encode operations
    ///   - source: Source texture to convert
    ///   - destination: Destination texture (must have compatible dimensions)
    /// - Note: Currently not used in main pipeline but available for future optimizations
    func convertTexture(on commandBuffer: any MTLCommandBuffer,
                        source: any MTLTexture,
                        destination: any MTLTexture) {
        guard mpsAvailable else {
            // Use Metal blit encoder (baseline path) when MPS is unavailable.
            blitConvertTexture(on: commandBuffer, source: source, destination: destination)
            return
        }

        // MPS operations require specific texture types and formats. 3D textures
        // and signed integer formats use the Metal blit baseline by design.
        let requiresBlitBaseline = source.textureType == .type3D ||
                                    destination.textureType == .type3D ||
                                    !source.pixelFormat.isMPSConvertible ||
                                    !destination.pixelFormat.isMPSConvertible

        if requiresBlitBaseline {
            blitConvertTexture(on: commandBuffer, source: source, destination: destination)
            return
        }

        // For 2D textures with normalized/float formats, MPS can optimize conversions
        let conversion = MPSImageConversion(
            device: device,
            srcAlpha: .nonPremultiplied,
            destAlpha: .nonPremultiplied,
            backgroundColor: nil,
            conversionInfo: nil
        )
        conversion.encode(commandBuffer: commandBuffer,
                          sourceTexture: source,
                          destinationTexture: destination)
    }

    /// Baseline texture conversion using Metal blit encoder.
    private func blitConvertTexture(on commandBuffer: any MTLCommandBuffer,
                                    source: any MTLTexture,
                                    destination: any MTLTexture) {
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            logger.error("Failed to create blit encoder for baseline texture conversion")
            return
        }
        blitEncoder.label = "MPR.TextureConversionBlitBaseline"

        // Handle different texture types
        switch (source.textureType, destination.textureType) {
        case (.type2D, .type2D):
            blitEncoder.copy(from: source,
                             sourceSlice: 0,
                             sourceLevel: 0,
                             sourceOrigin: MTLOriginMake(0, 0, 0),
                             sourceSize: MTLSizeMake(source.width, source.height, 1),
                             to: destination,
                             destinationSlice: 0,
                             destinationLevel: 0,
                             destinationOrigin: MTLOriginMake(0, 0, 0))

        case (.type3D, .type3D):
            blitEncoder.copy(from: source,
                             sourceSlice: 0,
                             sourceLevel: 0,
                             sourceOrigin: MTLOriginMake(0, 0, 0),
                             sourceSize: MTLSizeMake(source.width, source.height, source.depth),
                             to: destination,
                             destinationSlice: 0,
                             destinationLevel: 0,
                             destinationOrigin: MTLOriginMake(0, 0, 0))

        default:
            logger.warning("Unsupported texture type combination for conversion: \(source.textureType) -> \(destination.textureType)")
        }

        blitEncoder.endEncoding()
    }
}

private extension MTLPixelFormat {
    /// Checks if pixel format is compatible with MPS image operations
    var isMPSConvertible: Bool {
        switch self {
        case .r8Unorm, .r8Snorm, .r16Float, .r32Float,
             .rg8Unorm, .rg8Snorm, .rg16Float, .rg32Float,
             .rgba8Unorm, .rgba8Snorm, .rgba16Float, .rgba32Float,
             .bgra8Unorm:
            return true
        default:
            return false
        }
    }
}
#endif

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
