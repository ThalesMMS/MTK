//
//  VolumeTextureFactory.swift
//  MTK
//
//  Converts volumetric datasets into Metal textures.
//
//  Thales Matheus Mendonça Santos — October 2025

import Foundation
@preconcurrency import Metal
import OSLog
import simd

/// Factory for converting volumetric datasets into Metal 3D textures.
///
/// `VolumeTextureFactory` handles the creation of GPU-compatible 3D textures from `VolumeDataset` instances,
/// supporting both synchronous CPU-based uploads and asynchronous GPU-accelerated transfers via blit encoders.
/// Synthetic fixture loading lives in the `MTKFixtures` target.
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
/// Or load a synthetic fixture dataset, then create a factory:
/// ```swift
/// let fixture = ClinicalSyntheticFixtures.makeFusion()
/// let dataset = fixture.baseDataset
/// let factory = VolumeTextureFactory(dataset: dataset)
/// let texture = try await factory.generateAsync(device: device, commandQueue: queue)
/// ```
///
/// - Note: `MTKCore` does not parse ZIP resources and the public package does not ship `.raw.zip` volume presets.
/// - Important: Textures created by this factory use `.type3D` with pixel formats matching the dataset's `VolumePixelFormat`.
public final class VolumeTextureFactory {
    /// Errors that can occur during asynchronous texture upload.
    public enum TextureUploadError: Error, Equatable {
        /// Dataset voxel data is shorter than the byte count required by its dimensions and pixel format.
        case malformedData(expectedByteCount: Int, actualByteCount: Int)
        /// Dimensions Metal will not accept for a 3D texture.
        ///
        /// This is the one failure that has to be caught *before* Metal sees it:
        /// an out-of-range extent makes `MTLTextureDescriptor` validation call
        /// `abort()`, so `makeTexture` never returns nil to be guarded against —
        /// the process is already gone (issue #1682).
        case invalidDimensions(width: Int, height: Int, depth: Int)
        /// Failed to create the Metal 3D texture descriptor.
        case textureCreationFailed
        /// Failed to allocate the staging buffer for GPU transfer.
        case bufferAllocationFailed
        /// Failed to create the Metal command buffer.
        case commandBufferCreationFailed
        /// Failed to create the blit command encoder.
        case blitEncoderCreationFailed
        /// The command buffer reached a terminal state other than `.completed`, so the
        /// copy into the volume texture never ran and the texture holds nothing.
        case uploadDidNotRun(String)
    }

    /// One retry after a copy that never ran; a real failure fails both attempts.
    ///
    /// A GPU error/recovery event discards command buffers that were merely in flight
    /// when it happened — the driver calls them innocent victims, and a discarded copy
    /// never runs. Everything needed to encode it again is still alive here: the staging
    /// buffer still holds the voxels and the destination texture is still ours, so the
    /// second attempt is the same copy, not a different one.
    private static let retriesAfterADiscardedUpload = 1

    /// Errors that can occur when loading preset-backed volume resources.
    public enum PresetLoadingError: Error, LocalizedError {
        /// The selected preset does not define bundled voxel data.
        case noDataAvailable(preset: String)

        public var errorDescription: String? {
            switch self {
            case .noDataAvailable(let preset):
                return "Preset '\(preset)' does not provide bundled voxel data."
            }
        }
    }

    /// The volumetric dataset backing this factory.
    ///
    /// You can read this property to inspect the current dataset or call ``update(dataset:)`` to replace it.
    private(set) public var dataset: VolumeDataset

    /// Number of leading upload attempts that skip the commit, standing in for a driver
    /// that discarded them. Tests only; zero everywhere else.
    @_spi(Testing)
    public var discardedUploadsForTesting = 0

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
    /// Public RAW preset resources have been removed from the package.
    ///
    /// - Parameter preset: The preset to load.
    /// - Throws: ``PresetLoadingError/noDataAvailable(preset:)`` because public presets no longer bundle volume data.
    @available(*, deprecated, message: "Use ClinicalSyntheticFixtures from MTKFixtures or provide a VolumeDataset directly.")
    public convenience init(preset: VolumeDatasetPreset) throws {
        self.init(dataset: try VolumeTextureFactory.dataset(for: preset))
    }

    /// The physical spacing of the volume in millimeters (x, y, z).
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
    /// ``generate(device:usage:)`` or ``generateAsync(device:commandQueue:usage:)`` will use the updated dataset.
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
    /// - Parameters:
    ///   - device: The Metal device to allocate the texture on.
    ///   - usage: The final texture capabilities. Read-only shader access is the default.
    /// - Returns: A configured `MTLTexture`, or `nil` if texture creation failed.
    ///
    /// - Note: Logs errors via OSLog when texture creation fails.
    public func generate(device: any MTLDevice,
                         usage: MTLTextureUsage = .shaderRead) -> (any MTLTexture)? {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let expectedByteCount: Int
        do {
            // Before the byte count, because an extent Metal rejects aborts the
            // process rather than failing this call (issue #1682).
            try Self.validateVolumeTextureDimensions(dataset.dimensions)
            expectedByteCount = try Self.validatedUploadByteCount(for: dataset)
        } catch {
            logger.error("""
                Invalid volume voxel data for texture upload \
                (\(dataset.dimensions.width)x\(dataset.dimensions.height)x\(dataset.dimensions.depth))
                """)
            return nil
        }

        // StorageModePolicy.md: the synchronous CPU reference path keeps `.shared`
        // storage so tests can validate raw voxel uploads without a readback pass.
        let descriptor = Self.makeVolumeTextureDescriptor(dimensions: dataset.dimensions,
                                                          pixelFormat: dataset.pixelFormat,
                                                          storageMode: .shared,
                                                          usage: usage)

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
            guard dataset.data.count >= expectedByteCount else { return }
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
    ///   - usage: The final texture capabilities. Read-only shader access is the default.
    ///
    /// - Returns: A configured `MTLTexture` once the GPU transfer completes.
    ///
    /// - Throws: ``TextureUploadError`` if texture/buffer allocation or command encoding fails, or the underlying Metal error if the command buffer encounters an error.
    ///
    /// ## Example
    /// ```swift
    /// let factory = VolumeTextureFactory(dataset: dataset)
    /// let texture = try await factory.generateAsync(device: device, commandQueue: queue)
    /// // Texture is ready for immediate shader use
    /// ```
    public func generateAsync(device: any MTLDevice,
                              commandQueue: any MTLCommandQueue,
                              usage: MTLTextureUsage = .shaderRead) async throws -> any MTLTexture {
        try Task.checkCancellation()
        let startedAt = CFAbsoluteTimeGetCurrent()
        do {
            try Self.validateVolumeTextureDimensions(dataset.dimensions)
        } catch {
            logger.error("""
                Refusing a 3D texture Metal would abort on \
                (\(dataset.dimensions.width)x\(dataset.dimensions.height)x\(dataset.dimensions.depth))
                """)
            throw error
        }
        let expectedByteCount = try Self.validatedUploadByteCount(for: dataset)

        // StorageModePolicy.md: async volume uploads write into a final private
        // texture through a transient CPU-visible staging buffer.
        let descriptor = Self.makeVolumeTextureDescriptor(dimensions: dataset.dimensions,
                                                          pixelFormat: dataset.pixelFormat,
                                                          storageMode: .private,
                                                          usage: usage)

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            logger.error("Failed to create 3D texture (\(descriptor.width)x\(descriptor.height)x\(descriptor.depth))")
            throw TextureUploadError.textureCreationFailed
        }
        texture.label = "VolumeTexture3D"

        let bytesPerRow = dataset.pixelFormat.bytesPerVoxel * descriptor.width
        let bytesPerImage = bytesPerRow * descriptor.height

        // StorageModePolicy.md: staging is shared/write-combined for one-way CPU writes.
        guard let stagingBuffer = device.makeBuffer(length: expectedByteCount,
                                                    options: [.storageModeShared, .cpuCacheModeWriteCombined]) else {
            logger.error("Failed to allocate staging buffer (\(expectedByteCount) bytes)")
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
            memcpy(stagingBuffer.contents(), baseAddress, expectedByteCount)
        }
        try Task.checkCancellation()

        var attemptsLeft = Self.retriesAfterADiscardedUpload
        while true {
            let attemptsMade = Self.retriesAfterADiscardedUpload - attemptsLeft
            do {
                try await copyStagingBufferIntoTexture(
                    stagingBuffer: stagingBuffer,
                    texture: texture,
                    descriptor: descriptor,
                    bytesPerRow: bytesPerRow,
                    bytesPerImage: bytesPerImage,
                    device: device,
                    commandQueue: commandQueue,
                    uploadStartedAt: uploadStartedAt,
                    simulatesDiscard: attemptsMade < discardedUploadsForTesting
                )
                break
            } catch let error as TextureUploadError {
                guard case .uploadDidNotRun(let reason) = error, attemptsLeft > 0 else {
                    throw error
                }
                logger.error("Volume texture upload \(reason); retrying once.")
                attemptsLeft -= 1
            }
        }
        try Task.checkCancellation()
        return texture
    }

    /// Encodes and runs the one blit that fills the volume texture.
    ///
    /// A copy has no invariant of its own — every byte it can produce is a legal voxel,
    /// and the destination is `.private`, so nothing in it says whether the copy
    /// happened. The command buffer's terminal state is the only thing that does, and
    /// only `.completed` means it ran: a buffer the driver discarded as the innocent
    /// victim of another process's GPU error lands on `.error` — status raw value 5 —
    /// and can carry no error object at all. Asking `buffer.error` alone therefore
    /// returned a 3D texture the voxels never reached, and every caller downstream
    /// renders it as if it were the study.
    ///
    /// - Parameter simulatesDiscard: Skips the commit, standing in for a driver that
    ///   discarded the buffer. Tests only.
    private func copyStagingBufferIntoTexture(stagingBuffer: any MTLBuffer,
                                              texture: any MTLTexture,
                                              descriptor: MTLTextureDescriptor,
                                              bytesPerRow: Int,
                                              bytesPerImage: Int,
                                              device: any MTLDevice,
                                              commandQueue: any MTLCommandQueue,
                                              uploadStartedAt: CFAbsoluteTime,
                                              simulatesDiscard: Bool) async throws {
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

        // The test seam leaves the buffer uncommitted and asks it the same question, so a
        // check that stopped telling a copy that ran from one that did not would hand the
        // unfilled texture back here as well — which is the bug, and what the test sees.
        if simulatesDiscard {
            if let reason = CommandBufferCompletion.reasonItDidNotRun(commandBuffer) {
                throw TextureUploadError.uploadDidNotRun(reason)
            }
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            commandBuffer.addCompletedHandler { buffer in
                if let reason = CommandBufferCompletion.reasonItDidNotRun(buffer) {
                    continuation.resume(throwing: TextureUploadError.uploadDidNotRun(reason))
                    return
                }
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
                continuation.resume()
            }
            commandBuffer.commit()
        }
    }
}

extension VolumeTextureFactory {
    static func makeVolumeTextureDescriptor(dimensions: VolumeDimensions,
                                            pixelFormat: VolumePixelFormat,
                                            storageMode: MTLStorageMode = .private,
                                            usage: MTLTextureUsage = .shaderRead) -> MTLTextureDescriptor {
        // StorageModePolicy.md: volume texture storage is always explicit at call sites.
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = pixelFormat.metalPixelFormat
        descriptor.usage = usage
        descriptor.width = dimensions.width
        descriptor.height = dimensions.height
        descriptor.depth = dimensions.depth
        // Volume textures are GPU-only in the rendering path; async/chunked uploads
        // use private storage and stage CPU writes through shared buffers.
        descriptor.storageMode = storageMode
        return descriptor
    }
}

extension VolumeTextureFactory {
    /// Largest extent Metal accepts for a `type3D` texture, on every family this
    /// app runs on. There is no device query for it — `MTLDevice` exposes limits
    /// for 1D and 2D and not for 3D — so it is stated here rather than guessed
    /// at the call site.
    ///
    /// Public because callers upstream have to decide *not to build a volume*
    /// before they hand one over (issue #1684). A 2D texture of the same width
    /// is fine — the ceiling belongs to `type3D` alone — so a series past it is
    /// still perfectly displayable, just not as a volume.
    public static let maximumVolumeTextureExtent = 2048

    /// Rejects an extent Metal would refuse, **before** Metal sees it.
    ///
    /// `MTLTextureDescriptor` validation does not fail softly. A zero or
    /// oversized extent reaches `-[MTLTextureDescriptorInternal
    /// validateWithDevice:]`, which calls `MTLReportFailure` and then `abort()`
    /// — so `device.makeTexture(descriptor:)` never gets to return nil, and the
    /// `guard let` written to catch that never runs. The process is simply gone.
    ///
    /// That is issue #1682: opening a series in the macOS database browser took
    /// the whole app down with `SIGABRT` inside `generateAsync`, and from the
    /// outside it read as "double-clicking a series does not open the viewer".
    static func validateVolumeTextureDimensions(_ dimensions: VolumeDimensions) throws {
        let extents = [dimensions.width, dimensions.height, dimensions.depth]
        guard extents.allSatisfy({ $0 >= 1 && $0 <= maximumVolumeTextureExtent }) else {
            throw TextureUploadError.invalidDimensions(width: dimensions.width,
                                                       height: dimensions.height,
                                                       depth: dimensions.depth)
        }
    }
}

private extension VolumeTextureFactory {
    static func validatedUploadByteCount(for dataset: VolumeDataset) throws -> Int {
        let dimensions = dataset.dimensions
        let (area, areaOverflow) = dimensions.width.multipliedReportingOverflow(by: dimensions.height)
        let (voxelCount, voxelOverflow) = area.multipliedReportingOverflow(by: dimensions.depth)
        let (expectedByteCount, byteCountOverflow) = voxelCount.multipliedReportingOverflow(
            by: dataset.pixelFormat.bytesPerVoxel
        )

        guard !areaOverflow, !voxelOverflow, !byteCountOverflow else {
            throw TextureUploadError.malformedData(expectedByteCount: Int.max,
                                                   actualByteCount: dataset.data.count)
        }

        guard dataset.data.count >= expectedByteCount else {
            throw TextureUploadError.malformedData(expectedByteCount: expectedByteCount,
                                                   actualByteCount: dataset.data.count)
        }

        return expectedByteCount
    }

    static func dataset(for preset: VolumeDatasetPreset) throws -> VolumeDataset {
        switch preset {
        case .none, .dicom:
            resourceLogger.warning("Preset \(preset.rawValue) does not provide bundled voxel data")
            throw PresetLoadingError.noDataAvailable(preset: preset.rawValue)
        }
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
