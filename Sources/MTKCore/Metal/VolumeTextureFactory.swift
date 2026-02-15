//
//  VolumeTextureFactory.swift
//  MTK
//
//  Converts volumetric datasets into Metal textures and exposes built-in presets.
//
//  Thales Matheus Mendonça Santos — October 2025

import Foundation
import Metal
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
/// let factory = VolumeTextureFactory(preset: .head)
/// let texture = try await factory.generateAsync(device: device, commandQueue: queue)
/// ```
///
/// - Note: Preset datasets are loaded from bundled `.raw.zip` resources. Missing resources fall back to a 1³ placeholder.
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
    /// If the resource is missing, falls back to a 1³ placeholder dataset.
    ///
    /// - Parameter preset: The preset to load (`.head`, `.chest`, `.none`, or `.dicom`).
    public convenience init(preset: VolumeDatasetPreset) {
        self.init(dataset: VolumeTextureFactory.dataset(for: preset))
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
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = dataset.pixelFormat.metalPixelFormat
        descriptor.usage = [.shaderRead, .pixelFormatView]
        descriptor.width = dataset.dimensions.width
        descriptor.height = dataset.dimensions.height
        descriptor.depth = dataset.dimensions.depth

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            logger.error("Failed to create 3D texture (\(descriptor.width)x\(descriptor.height)x\(descriptor.depth))")
            return nil
        }

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
    /// let factory = VolumeTextureFactory(preset: .head)
    /// let texture = try await factory.generateAsync(device: device, commandQueue: queue)
    /// // Texture is ready for immediate shader use
    /// ```
    public func generateAsync(device: any MTLDevice,
                             commandQueue: any MTLCommandQueue) async throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = dataset.pixelFormat.metalPixelFormat
        descriptor.usage = [.shaderRead, .pixelFormatView]
        descriptor.width = dataset.dimensions.width
        descriptor.height = dataset.dimensions.height
        descriptor.depth = dataset.dimensions.depth

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            logger.error("Failed to create 3D texture (\(descriptor.width)x\(descriptor.height)x\(descriptor.depth))")
            throw TextureUploadError.textureCreationFailed
        }
        texture.label = "VolumeTexture3D"

        let bytesPerRow = dataset.pixelFormat.bytesPerVoxel * descriptor.width
        let bytesPerImage = bytesPerRow * descriptor.height
        let bufferLength = dataset.data.count

        guard let stagingBuffer = device.makeBuffer(length: bufferLength, options: .storageModeShared) else {
            logger.error("Failed to allocate staging buffer (\(bufferLength) bytes)")
            throw TextureUploadError.bufferAllocationFailed
        }
        stagingBuffer.label = "VolumeStagingBuffer"

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

        return try await withCheckedThrowingContinuation { continuation in
            commandBuffer.addCompletedHandler { buffer in
                if let error = buffer.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: texture)
                }
            }
            commandBuffer.commit()
        }
    }
}

private extension VolumeTextureFactory {
    static func dataset(for preset: VolumeDatasetPreset) -> VolumeDataset {
        switch preset {
        case .head:
            return loadZippedResource(
                named: "head",
                dimensions: VolumeDimensions(width: 512, height: 512, depth: 511),
                spacing: VolumeSpacing(x: 0.000449, y: 0.000449, z: 0.000501),
                pixelFormat: .int16Signed,
                intensity: (-1024)...3071
            )
        case .chest:
            return loadZippedResource(
                named: "chest",
                dimensions: VolumeDimensions(width: 512, height: 512, depth: 179),
                spacing: VolumeSpacing(x: 0.000586, y: 0.000586, z: 0.002),
                pixelFormat: .int16Signed,
                intensity: (-1024)...3071
            )
        case .none, .dicom:
            return placeholderDataset()
        }
    }

    static func placeholderDataset() -> VolumeDataset {
        let data = Data(count: VolumePixelFormat.int16Signed.bytesPerVoxel)
        return VolumeDataset(
            data: data,
            dimensions: VolumeDimensions(width: 1, height: 1, depth: 1),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: (-1024)...3071
        )
    }

    static func loadZippedResource(named name: String,
                                   dimensions: VolumeDimensions,
                                   spacing: VolumeSpacing,
                                   pixelFormat: VolumePixelFormat,
                                   intensity: ClosedRange<Int32>) -> VolumeDataset {
        guard let url = Bundle.module.url(forResource: name, withExtension: "raw.zip") else {
            resourceLogger.warning("Missing resource: \(name).raw.zip")
            return placeholderDataset()
        }

        return loadDataset(
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
                            intensity: ClosedRange<Int32>) -> VolumeDataset {
        let archive: Archive
        do {
            guard let archive_ = try Archive(url: url, accessMode: .read) else {
                resourceLogger.error("Unable to create archive at \(url.path)")
                return placeholderDataset()
            }
            archive = archive_
        } catch {
            resourceLogger.error("Unable to read archive at \(url.path): \(String(describing: error))")
            return placeholderDataset()
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
            return placeholderDataset()
        }

        if data.isEmpty {
            resourceLogger.warning("Archive \(url.lastPathComponent) extracted but returned empty data")
            return placeholderDataset()
        }

        return VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: spacing,
            pixelFormat: pixelFormat,
            intensityRange: intensity
        )
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
