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
        self.contentFingerprint = Self.makeContentFingerprint(for: dataset.data)
    }

    static func == (lhs: DatasetIdentity, rhs: DatasetIdentity) -> Bool {
        lhs.count == rhs.count &&
        lhs.dimensions == rhs.dimensions &&
        lhs.pixelFormat == rhs.pixelFormat &&
        lhs.contentFingerprint == rhs.contentFingerprint
    }

    private static func makeContentFingerprint(for data: Data) -> UInt64 {
        data.withUnsafeBytes { buffer in
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in buffer {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            return hash
        }
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
    private var pipelineCache: MTLComputePipelineState?
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

    /// Generate an MPR slab image from a volumetric dataset for a specified plane.
    /// - Parameters:
    ///   - dataset: The source volumetric dataset to sample from.
    ///   - plane: The plane geometry defining the slice origin and axes.
    ///   - thickness: Slab thickness in voxels (will be sanitized before use).
    ///   - steps: Number of sampling steps through the slab (will be sanitized before use).
    ///   - blend: The blending mode to apply across the slab.
    /// - Returns: An `MPRSlice` containing the computed pixel buffer, dimensions, bytes-per-row, pixel format, intensity range, and pixel spacing.
    /// - Throws: `ComputeError` or underlying Metal errors when pipeline creation, texture allocation, command encoding/dispatch, or readback fails.
    public func makeSlab(dataset: VolumeDataset,
                         plane: MPRPlaneGeometry,
                         thickness: Int,
                         steps: Int,
                         blend: MPRBlendMode) async throws -> MPRSlice {
        let effectiveBlend = overrides.blend ?? blend
        let effectiveThickness = VolumetricMath.sanitizeThickness(overrides.slabThickness ?? thickness)
        let effectiveSteps = VolumetricMath.sanitizeSteps(overrides.slabSteps ?? steps)

        // Get or create pipeline
        let pipeline = try await getPipelineState()

        // Reuse the dataset-scoped volume texture when the dataset layout and payload are unchanged.
        let volumeTexture = try provideVolumeTexture(for: dataset)

        // Calculate output dimensions
        let (width, height) = sliceDimensions(for: plane)

        // Reuse the output texture when the requested shape is unchanged and not already in flight.
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

        // Prepare uniforms
        var uniforms = try createUniforms(dataset: dataset,
                                          plane: plane,
                                          thickness: effectiveThickness,
                                          steps: effectiveSteps,
                                          blend: effectiveBlend)

        // Dispatch compute kernel
        try await dispatchCompute(pipeline: pipeline,
                                   volumeTexture: volumeTexture,
                                   outputTexture: outputTexture,
                                   uniforms: &uniforms,
                                   width: width,
                                   height: height)

        // Read back result
        let slice = try await readSlice(from: outputTexture,
                                        width: width,
                                        height: height,
                                        pixelFormat: dataset.pixelFormat,
                                        plane: plane,
                                        dataset: dataset)

        // Update snapshot
        let axis = dominantAxis(for: plane)
        lastSnapshot = SliceSnapshot(axis: axis,
                                     intensityRange: slice.intensityRange,
                                     blend: effectiveBlend,
                                     thickness: effectiveThickness,
                                     steps: effectiveSteps)

        // Clear overrides
        overrides.blend = nil
        overrides.slabThickness = nil
        overrides.slabSteps = nil

        return slice
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
    func getPipelineState() async throws -> MTLComputePipelineState {
        if let cached = pipelineCache {
            return cached
        }

        guard let function = library.makeFunction(name: "computeMPRSlab") else {
            logger.error("Metal function computeMPRSlab not found")
            throw ComputeError.pipelineUnavailable
        }
        function.label = "mpr_slab_compute"

        let descriptor = MTLComputePipelineDescriptor()
        descriptor.label = "mpr_slab_compute"
        descriptor.computeFunction = function

        do {
            let pipeline = try device.makeComputePipelineState(descriptor: descriptor,
                                                               options: [],
                                                               reflection: nil)
            pipelineCache = pipeline
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
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2D
        descriptor.pixelFormat = pixelFormat.metalPixelFormat
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.width = width
        descriptor.height = height

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
}

// MARK: - Uniforms

private extension MetalMPRComputeAdapter {
    struct MPRSlabUniforms {
        var voxelMinValue: Int32
        var voxelMaxValue: Int32
        var blendMode: Int32
        var numSteps: Int32
        var flipVertical: Int32
        var slabHalf: Float
        var _pad0: SIMD2<Float>

        var planeOrigin: SIMD3<Float>
        var _pad1: Float
        var planeX: SIMD3<Float>
        var _pad2: Float
        var planeY: SIMD3<Float>
        var _pad3: Float
    }

    func createUniforms(dataset: VolumeDataset,
                        plane: MPRPlaneGeometry,
                        thickness: Int,
                        steps: Int,
                        blend: MPRBlendMode) throws -> MPRSlabUniforms {
        // Convert thickness from voxels to normalized [0,1] space
        let spacing = dataset.spacing
        let dimensions = dataset.dimensions

        // Use average spacing for thickness normalization
        let avgSpacing = (spacing.x + spacing.y + spacing.z) / 3.0
        let avgDimension = (Double(dimensions.width) + Double(dimensions.height) + Double(dimensions.depth)) / 3.0
        let normalizedThickness = (Double(thickness) * avgSpacing) / (avgDimension * avgSpacing)
        let slabHalf = Float(normalizedThickness / 2.0)

        return MPRSlabUniforms(
            voxelMinValue: Int32(dataset.intensityRange.lowerBound),
            voxelMaxValue: Int32(dataset.intensityRange.upperBound),
            blendMode: Int32(blend.rawValue),
            numSteps: Int32(steps),
            flipVertical: 0,
            slabHalf: slabHalf,
            _pad0: SIMD2<Float>(0, 0),
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
                         height: Int) async throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw ComputeError.commandBufferCreationFailed
        }
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

        return try await withCheckedThrowingContinuation { continuation in
            commandBuffer.addCompletedHandler { buffer in
                if let error = buffer.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
            commandBuffer.commit()
        }
    }
}

// MARK: - Result Reading

private extension MetalMPRComputeAdapter {
    func readSlice(from texture: any MTLTexture,
                   width: Int,
                   height: Int,
                   pixelFormat: VolumePixelFormat,
                   plane: MPRPlaneGeometry,
                   dataset: VolumeDataset) async throws -> MPRSlice {
        let bytesPerPixel = pixelFormat.bytesPerVoxel
        let bytesPerRow = width * bytesPerPixel
        let bufferLength = height * bytesPerRow

        var pixels = Data(count: bufferLength)

        try pixels.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw ComputeError.outputBufferAllocationFailed
            }

            texture.getBytes(
                baseAddress,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }

        let pixelSpacing = calculatePixelSpacing(for: plane,
                                                  width: width,
                                                  height: height,
                                                  dataset: dataset)
        let intensityRange = calculateIntensityRange(in: pixels,
                                                      pixelFormat: pixelFormat)
            ?? dataset.intensityRange

        return MPRSlice(
            pixels: pixels,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixelFormat: pixelFormat,
            intensityRange: intensityRange,
            pixelSpacing: pixelSpacing
        )
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
        let width = max(1, Int(round(simd_length(plane.axisUVoxel))))
        let height = max(1, Int(round(simd_length(plane.axisVVoxel))))
        return (width, height)
    }

    func calculatePixelSpacing(for plane: MPRPlaneGeometry,
                                width: Int,
                                height: Int,
                                dataset: VolumeDataset) -> SIMD2<Float>? {
        let uLength = simd_length(plane.axisUWorld)
        let vLength = simd_length(plane.axisVWorld)
        let spacingU = width > 1 ? uLength / Float(width - 1) : Float(dataset.spacing.x)
        let spacingV = height > 1 ? vLength / Float(height - 1) : Float(dataset.spacing.y)
        return SIMD2<Float>(spacingU, spacingV)
    }

    func calculateIntensityRange(in pixels: Data,
                                  pixelFormat: VolumePixelFormat) -> ClosedRange<Int32>? {
        guard !pixels.isEmpty else { return nil }

        return pixels.withUnsafeBytes { buffer in
            switch pixelFormat {
            case .int16Signed:
                guard let pointer = buffer.baseAddress?.assumingMemoryBound(to: Int16.self) else {
                    return nil
                }
                let count = pixels.count / MemoryLayout<Int16>.stride
                var minValue: Int16 = .max
                var maxValue: Int16 = .min
                for i in 0..<count {
                    let value = pointer[i]
                    minValue = min(minValue, value)
                    maxValue = max(maxValue, value)
                }
                return Int32(minValue)...Int32(maxValue)

            case .int16Unsigned:
                guard let pointer = buffer.baseAddress?.assumingMemoryBound(to: UInt16.self) else {
                    return nil
                }
                let count = pixels.count / MemoryLayout<UInt16>.stride
                var minValue: UInt16 = .max
                var maxValue: UInt16 = .min
                for i in 0..<count {
                    let value = pointer[i]
                    minValue = min(minValue, value)
                    maxValue = max(maxValue, value)
                }
                return Int32(minValue)...Int32(maxValue)
            }
        }
    }
}

// MARK: - MPS Optimization Support

#if canImport(MetalPerformanceShaders)
private extension MetalMPRComputeAdapter {
    /// Performs optimized texture format conversion using MPS when available.
    /// Falls back to blit encoder for unsupported formats.
    /// - Parameters:
    ///   - commandBuffer: Command buffer to encode operations
    ///   - source: Source texture to convert
    ///   - destination: Destination texture (must have compatible dimensions)
    /// - Note: Currently not used in main pipeline but available for future optimizations
    func convertTexture(on commandBuffer: any MTLCommandBuffer,
                        source: any MTLTexture,
                        destination: any MTLTexture) {
        guard mpsAvailable else {
            // Fallback: Use blit encoder for direct copy when MPS unavailable
            fallbackConvertTexture(on: commandBuffer, source: source, destination: destination)
            return
        }

        // MPS operations require specific texture types and formats
        // Use blit encoder fallback for 3D textures or incompatible formats
        let requiresBlitFallback = source.textureType == .type3D ||
                                    destination.textureType == .type3D ||
                                    !source.pixelFormat.isMPSConvertible ||
                                    !destination.pixelFormat.isMPSConvertible

        if requiresBlitFallback {
            fallbackConvertTexture(on: commandBuffer, source: source, destination: destination)
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

    /// Fallback texture conversion using blit encoder
    private func fallbackConvertTexture(on commandBuffer: any MTLCommandBuffer,
                                         source: any MTLTexture,
                                         destination: any MTLTexture) {
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            logger.error("Failed to create blit encoder for texture conversion fallback")
            return
        }
        blitEncoder.label = "MPR.TextureConversionFallback"

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
        switch self {
        case .int16Signed:
            return .r16Sint
        case .int16Unsigned:
            return .r16Uint
        }
    }
}
