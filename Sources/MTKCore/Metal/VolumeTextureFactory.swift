//
//  VolumeTextureFactory.swift
//  MTK
//
//  Converts volumetric datasets into Metal textures and exposes built-in presets.
//
//  Thales Matheus Mendonça Santos — October 2025

import Foundation
@preconcurrency import Metal
import OSLog
import simd
import ZIPFoundation

/// Factory for converting volumetric datasets into Metal 3D textures.
///
/// `VolumeTextureFactory` handles the creation of GPU-compatible 3D textures from `VolumeDataset` instances,
/// supporting both synchronous CPU-based uploads and asynchronous GPU-accelerated transfers via blit encoders.
/// It also provides built-in presets for common medical imaging datasets (head, chest).
///
/// ## Usage
///
/// Create a factory from a custom dataset:
/// ```swift
/// let dataset = VolumeDataset(data: voxelData, dimensions: dims, spacing: spacing, ...)
/// let factory = VolumeTextureFactory(dataset: dataset)
/// if let texture = factory.generate(device: device) {
///     // Use texture in rendering pipeline
/// }
/// ```
///
/// Or use a built-in preset:
/// ```swift
/// let factory = try VolumeTextureFactory(preset: .head)
/// let texture = try await factory.generateAsync(device: device, commandQueue: queue)
/// ```
///
/// - Note: Preset datasets are loaded from bundled `.raw.zip` resources. Missing or invalid resources throw ``PresetLoadingError``.
/// - Important: Textures created by this factory use `.type3D` with pixel formats matching the dataset's `VolumePixelFormat`.
public final class VolumeTextureFactory {
    /// Errors that can occur during asynchronous texture upload.
    public enum TextureUploadError: Error {
        /// Failed to create the Metal 3D texture descriptor.
        case textureCreationFailed
        /// Failed to allocate the staging buffer for GPU transfer.
        case bufferAllocationFailed
        /// Failed to create the Metal command buffer.
        case commandBufferCreationFailed
        /// Failed to create the blit command encoder.
        case blitEncoderCreationFailed
    }

    /// Errors that can occur when loading preset-backed volume resources.
    public enum PresetLoadingError: Error, LocalizedError {
        /// The expected bundled `.raw.zip` resource was not found.
        case resourceNotBundled(preset: String)
        /// The bundled archive exists but cannot be opened for reading.
        case archiveUnreadable(preset: String)
        /// Archive extraction failed before a complete payload could be built.
        case extractionFailed(preset: String, underlying: Error?)
        /// The archive extracted successfully but produced no voxel data.
        case emptyPayload(preset: String)
        /// The selected preset does not define bundled voxel data.
        case noDataAvailable(preset: String)

        public var errorDescription: String? {
            switch self {
            case .resourceNotBundled(let preset):
                return "Preset resource '\(preset).raw.zip' was not found in Bundle.module."
            case .archiveUnreadable(let preset):
                return "Preset resource archive for '\(preset)' could not be opened."
            case .extractionFailed(let preset, let underlying):
                if let underlying {
                    return "Preset resource archive for '\(preset)' could not be extracted: \(underlying.localizedDescription)"
                }
                return "Preset resource archive for '\(preset)' could not be extracted."
            case .emptyPayload(let preset):
                return "Preset resource archive for '\(preset)' did not contain voxel data."
            case .noDataAvailable(let preset):
                return "Preset '\(preset)' does not provide bundled voxel data."
            }
        }
    }

    /// The volumetric dataset backing this factory.
    ///
    /// You can read this property to inspect the current dataset or call ``update(dataset:)`` to replace it.
    private(set) public var dataset: VolumeDataset
    private let logger = Logger(subsystem: "com.mtk.volumerendering",
                                category: "VolumeTextureFactory")
    private static let resourceLogger = Logger(subsystem: "com.mtk.volumerendering",
                                               category: "VolumeResources")

    /// Creates a factory from a custom volumetric dataset.
    ///
    /// - Parameter dataset: The `VolumeDataset` containing voxel data, dimensions, spacing, and pixel format.
    public init(dataset: VolumeDataset) {
        self.dataset = dataset
    }

    /// Creates a factory from a built-in preset.
    ///
    /// Preset datasets are loaded from bundled `.raw.zip` resources in `Bundle.module`.
    ///
    /// - Parameter preset: The preset to load (`.head`, `.chest`, `.none`, or `.dicom`).
    /// - Throws: ``PresetLoadingError`` when the preset has no bundled data or its resource cannot be loaded.
    public convenience init(preset: VolumeDatasetPreset) throws {
        self.init(dataset: try VolumeTextureFactory.dataset(for: preset))
    }

    /// The physical spacing of the volume in meters (x, y, z).
    ///
    /// Derived from `dataset.spacing` as a SIMD3 vector for shader uniform compatibility.
    public var resolution: SIMD3<Float> { dataset.spacing.simd3Value }

    /// The voxel dimensions of the volume (width, height, depth).
    ///
    /// Derived from `dataset.dimensions` as a SIMD3 vector for shader uniform compatibility.
    public var dimension: SIMD3<Int32> { dataset.dimensions.simd3Value }

    /// The world-space scale of the volume (normalized spacing vector).
    ///
    /// Derived from `dataset.scale` as a SIMD3 vector for shader uniform compatibility.
    public var scale: SIMD3<Float> { dataset.scale.simd3Value }

    /// Replaces the current dataset with a new one.
    ///
    /// Call this method to swap datasets without recreating the factory. The next call to
    /// ``generate(device:)`` or ``generateAsync(device:commandQueue:)`` will use the updated dataset.
    ///
    /// - Parameter dataset: The new `VolumeDataset` to use.
    public func update(dataset: VolumeDataset) {
        self.dataset = dataset
    }

    /// Returns a minimal 1x1x1 volume for tests and explicit debug fallback paths.
    ///
    /// This dataset is intentionally not used by preset loading. Production code should
    /// load real volume data or handle ``PresetLoadingError`` from ``init(preset:)``.
    public static func debugPlaceholderDataset() -> VolumeDataset {
        let data = Data(count: VolumePixelFormat.int16Signed.bytesPerVoxel)
        return VolumeDataset(
            data: data,
            dimensions: VolumeDimensions(width: 1, height: 1, depth: 1),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: (-1024)...3071
        )
    }

    /// Synchronously creates a 3D Metal texture from the current dataset using CPU-based upload.
    ///
    /// This method allocates a 3D texture matching the dataset's dimensions and pixel format, then uploads
    /// the voxel data directly via `MTLTexture.replace(region:...)`. Suitable for small datasets or
    /// environments where asynchronous uploads are not required.
    ///
    /// - Parameter device: The Metal device to allocate the texture on.
    /// - Returns: A configured `MTLTexture`, or `nil` if texture creation failed.
    ///
    /// - Note: Logs errors via OSLog when texture creation fails.
    public func generate(device: any MTLDevice) -> (any MTLTexture)? {
        let startedAt = CFAbsoluteTimeGetCurrent()
        // StorageModePolicy.md: the synchronous CPU reference path keeps `.shared`
        // storage so tests can validate raw voxel uploads without a readback pass.
        let descriptor = Self.makeVolumeTextureDescriptor(dimensions: dataset.dimensions,
                                                          pixelFormat: dataset.pixelFormat,
                                                          storageMode: .shared)

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            logger.error("Failed to create 3D texture (\(descriptor.width)x\(descriptor.height)x\(descriptor.depth))")
            return nil
        }
        ClinicalProfiler.shared.recordSample(
            stage: .texturePreparation,
            cpuTime: ClinicalProfiler.milliseconds(from: startedAt),
            memory: ResourceMemoryEstimator.estimate(for: texture),
            viewport: .unknown,
            metadata: [
                "path": "VolumeTextureFactory.generate.prepare",
                "dimensions": "\(descriptor.width)x\(descriptor.height)x\(descriptor.depth)",
                "pixelFormat": "\(texture.pixelFormat)"
            ],
            device: device
        )

        let uploadStartedAt = CFAbsoluteTimeGetCurrent()
        let bytesPerRow = dataset.pixelFormat.bytesPerVoxel * descriptor.width
        let bytesPerImage = bytesPerRow * descriptor.height

        dataset.data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, descriptor.width, descriptor.height, descriptor.depth),
                mipmapLevel: 0,
                slice: 0,
                withBytes: baseAddress,
                bytesPerRow: bytesPerRow,
                bytesPerImage: bytesPerImage
            )
        }

        ClinicalProfiler.shared.recordSample(
            stage: .textureUpload,
            cpuTime: ClinicalProfiler.milliseconds(from: uploadStartedAt),
            memory: ResourceMemoryEstimator.estimate(for: texture),
            viewport: .unknown,
            metadata: [
                "path": "VolumeTextureFactory.generate",
                "dimensions": "\(descriptor.width)x\(descriptor.height)x\(descriptor.depth)",
                "pixelFormat": "\(texture.pixelFormat)"
            ],
            device: device
        )
        return texture
    }

    /// Asynchronously creates a 3D Metal texture from the current dataset using GPU-accelerated blit transfer.
    ///
    /// This method allocates both a 3D texture and a staging buffer, copies voxel data to the staging buffer,
    /// then uses a blit command encoder to transfer data to the GPU. Returns when the command buffer completes.
    /// Recommended for large datasets (>64MB) or when pipeline stalls must be avoided.
    ///
    /// - Parameters:
    ///   - device: The Metal device to allocate resources on.
    ///   - commandQueue: The command queue to submit the blit operation.
    ///
    /// - Returns: A configured `MTLTexture` once the GPU transfer completes.
    ///
    /// - Throws: ``TextureUploadError`` if texture/buffer allocation or command encoding fails, or the underlying Metal error if the command buffer encounters an error.
    ///
    /// ## Example
    /// ```swift
    /// let factory = try VolumeTextureFactory(preset: .head)
    /// let texture = try await factory.generateAsync(device: device, commandQueue: queue)
    /// // Texture is ready for immediate shader use
    /// ```
    public func generateAsync(device: any MTLDevice,
                             commandQueue: any MTLCommandQueue) async throws -> any MTLTexture {
        let startedAt = CFAbsoluteTimeGetCurrent()
        // StorageModePolicy.md: async volume uploads write into a final private
        // texture through a transient CPU-visible staging buffer.
        let descriptor = Self.makeVolumeTextureDescriptor(dimensions: dataset.dimensions,
                                                          pixelFormat: dataset.pixelFormat,
                                                          storageMode: .private)

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            logger.error("Failed to create 3D texture (\(descriptor.width)x\(descriptor.height)x\(descriptor.depth))")
            throw TextureUploadError.textureCreationFailed
        }
        texture.label = "VolumeTexture3D"

        let bytesPerRow = dataset.pixelFormat.bytesPerVoxel * descriptor.width
        let bytesPerImage = bytesPerRow * descriptor.height
        let bufferLength = dataset.data.count

        // StorageModePolicy.md: staging is shared/write-combined for one-way CPU writes.
        guard let stagingBuffer = device.makeBuffer(length: bufferLength,
                                                    options: [.storageModeShared, .cpuCacheModeWriteCombined]) else {
            logger.error("Failed to allocate staging buffer (\(bufferLength) bytes)")
            throw TextureUploadError.bufferAllocationFailed
        }
        stagingBuffer.label = "VolumeStagingBuffer"
        ClinicalProfiler.shared.recordSample(
            stage: .texturePreparation,
            cpuTime: ClinicalProfiler.milliseconds(from: startedAt),
            memory: ResourceMemoryEstimator.estimate(for: texture) + stagingBuffer.length,
            viewport: .unknown,
            metadata: [
                "path": "VolumeTextureFactory.generateAsync.prepare",
                "dimensions": "\(descriptor.width)x\(descriptor.height)x\(descriptor.depth)",
                "pixelFormat": "\(texture.pixelFormat)"
            ],
            device: device
        )

        let uploadStartedAt = CFAbsoluteTimeGetCurrent()
        dataset.data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            memcpy(stagingBuffer.contents(), baseAddress, bufferLength)
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            logger.error("Failed to create command buffer for texture upload")
            throw TextureUploadError.commandBufferCreationFailed
        }
        commandBuffer.label = "VolumeTextureUpload"

        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            logger.error("Failed to create blit command encoder")
            throw TextureUploadError.blitEncoderCreationFailed
        }
        blitEncoder.label = "VolumeTextureUpload"

        blitEncoder.copy(
            from: stagingBuffer,
            sourceOffset: 0,
            sourceBytesPerRow: bytesPerRow,
            sourceBytesPerImage: bytesPerImage,
            sourceSize: MTLSize(width: descriptor.width, height: descriptor.height, depth: descriptor.depth),
            to: texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )

        blitEncoder.endEncoding()
        CommandBufferProfiler.captureTimes(for: commandBuffer,
                                           label: "upload",
                                           category: "Benchmark")
        let uploadCPUEnd = CFAbsoluteTimeGetCurrent()

        return try await withCheckedThrowingContinuation { continuation in
            commandBuffer.addCompletedHandler { buffer in
                if let error = buffer.error {
                    continuation.resume(throwing: error)
                } else {
                    let timing = buffer.timings(cpuStart: uploadStartedAt,
                                                cpuEnd: uploadCPUEnd)
                    ClinicalProfiler.shared.recordSample(
                        stage: .textureUpload,
                        cpuTime: timing.cpuTime,
                        gpuTime: timing.gpuTime > 0 ? timing.gpuTime : nil,
                        memory: ResourceMemoryEstimator.estimate(for: texture) + stagingBuffer.length,
                        viewport: .unknown,
                        metadata: [
                            "path": "VolumeTextureFactory.generateAsync",
                            "kernelTimeMilliseconds": String(format: "%.6f", timing.kernelTime),
                            "dimensions": "\(descriptor.width)x\(descriptor.height)x\(descriptor.depth)",
                            "pixelFormat": "\(texture.pixelFormat)"
                        ],
                        device: device
                    )
                    continuation.resume(returning: texture)
                }
            }
            commandBuffer.commit()
        }
    }
}

extension VolumeTextureFactory {
    static func makeVolumeTextureDescriptor(dimensions: VolumeDimensions,
                                            pixelFormat: VolumePixelFormat,
                                            storageMode: MTLStorageMode = .private) -> MTLTextureDescriptor {
        // StorageModePolicy.md: volume texture storage is always explicit at call sites.
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = pixelFormat.metalPixelFormat
        descriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
        descriptor.width = dimensions.width
        descriptor.height = dimensions.height
        descriptor.depth = dimensions.depth
        // Volume textures are GPU-only in the rendering path; async/chunked uploads
        // use private storage and stage CPU writes through shared buffers.
        descriptor.storageMode = storageMode
        return descriptor
    }
}

private extension VolumeTextureFactory {
    static func dataset(for preset: VolumeDatasetPreset) throws -> VolumeDataset {
        switch preset {
        case .head:
            return try loadZippedResource(
                named: "head",
                dimensions: VolumeDimensions(width: 512, height: 512, depth: 511),
                spacing: VolumeSpacing(x: 0.000449, y: 0.000449, z: 0.000501),
                pixelFormat: .int16Signed,
                intensity: (-1024)...3071
            )
        case .chest:
            return try loadZippedResource(
                named: "chest",
                dimensions: VolumeDimensions(width: 512, height: 512, depth: 179),
                spacing: VolumeSpacing(x: 0.000586, y: 0.000586, z: 0.002),
                pixelFormat: .int16Signed,
                intensity: (-1024)...3071
            )
        case .none, .dicom:
            resourceLogger.warning("Preset \(preset.rawValue) does not provide bundled voxel data")
            throw PresetLoadingError.noDataAvailable(preset: preset.rawValue)
        }
    }

    static func loadZippedResource(named name: String,
                                   dimensions: VolumeDimensions,
                                   spacing: VolumeSpacing,
                                   pixelFormat: VolumePixelFormat,
                                   intensity: ClosedRange<Int32>) throws -> VolumeDataset {
        guard let url = Bundle.module.url(forResource: name, withExtension: "raw.zip") else {
            resourceLogger.warning("Missing resource: \(name).raw.zip")
            throw PresetLoadingError.resourceNotBundled(preset: name)
        }

        return try loadDataset(
            fromArchiveAt: url,
            dimensions: dimensions,
            spacing: spacing,
            pixelFormat: pixelFormat,
            intensity: intensity
        )
    }

    static func loadDataset(fromArchiveAt url: URL,
                            dimensions: VolumeDimensions,
                            spacing: VolumeSpacing,
                            pixelFormat: VolumePixelFormat,
                            intensity: ClosedRange<Int32>) throws -> VolumeDataset {
        let presetName = presetName(fromArchiveURL: url)
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            resourceLogger.error("Unable to read archive at \(url.path): \(String(describing: error))")
            throw PresetLoadingError.archiveUnreadable(preset: presetName)
        }

        var data = Data(capacity: dimensions.voxelCount * pixelFormat.bytesPerVoxel)
        do {
            for entry in archive {
                _ = try archive.extract(entry) { buffer in
                    data.append(buffer)
                }
            }
        } catch {
            resourceLogger.error("Failed to extract archive \(url.lastPathComponent): \(String(describing: error))")
            throw PresetLoadingError.extractionFailed(preset: presetName, underlying: error)
        }

        if data.isEmpty {
            resourceLogger.warning("Archive \(url.lastPathComponent) extracted but returned empty data")
            throw PresetLoadingError.emptyPayload(preset: presetName)
        }

        return VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: spacing,
            pixelFormat: pixelFormat,
            intensityRange: intensity
        )
    }

    static func presetName(fromArchiveURL url: URL) -> String {
        let rawName = url.deletingPathExtension().deletingPathExtension().lastPathComponent
        return rawName.isEmpty ? url.lastPathComponent : rawName
    }
}

private extension VolumeSpacing {
    var simd3Value: SIMD3<Float> {
        SIMD3<Float>(Float(x), Float(y), Float(z))
    }
}

private extension VolumeDimensions {
    var simd3Value: SIMD3<Int32> {
        SIMD3<Int32>(Int32(width), Int32(height), Int32(depth))
    }
}

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
