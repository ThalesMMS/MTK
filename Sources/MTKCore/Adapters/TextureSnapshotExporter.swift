//
//  TextureSnapshotExporter.swift
//  MTK
//
//  Explicit MTLTexture readback and image export implementation.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@preconcurrency import Metal

/// Converts completed render textures into export artifacts on demand.
///
/// This type is the production boundary for `MTLTexture.getBytes`. Interactive
/// renderers should return and present `MTLTexture` values without constructing
/// `CGImage` snapshots.
public final class TextureSnapshotExporter: SnapshotExporting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedLastMetrics: SnapshotMetrics?

    /// Duration of the most recent texture readback, in seconds.
    public var lastReadbackDuration: TimeInterval? {
        lastOperationMetrics()?.readbackDuration
    }

    /// Returns metrics for the most recent explicit snapshot/export operation.
    public func lastOperationMetrics() -> SnapshotMetrics? {
        lock.lock()
        defer { lock.unlock() }
        return storedLastMetrics
    }

    public init() {}

    public func makeCGImage(from frame: VolumeRenderFrame) async throws -> CGImage {
        try await withThrowingTaskGroup(of: CGImage.self) { group in
            group.addTask(priority: .utility) {
                try self.makeCGImageSynchronously(from: frame)
            }
            guard let image = try await group.next() else {
                throw CancellationError()
            }
            return image
        }
    }

    /// Synchronous compatibility hook used by legacy snapshot APIs.
    ///
    /// New export code should prefer the async ``makeCGImage(from:)`` method on
    /// ``SnapshotExporting`` so snapshot work remains explicit at call sites.
    public func makeCGImageSynchronously(from frame: VolumeRenderFrame) throws -> CGImage {
        try Task.checkCancellation()

        let texture = frame.texture
        let pixelFormat = frame.metadata.pixelFormat
        guard pixelFormat == texture.pixelFormat else {
            throw SnapshotExportError.readbackFailed(
                "Frame metadata pixel format \(pixelFormat) does not match texture pixel format \(texture.pixelFormat)."
            )
        }

        let bitmapInfo = try Self.bitmapInfo(for: pixelFormat)
        let width = texture.width
        let height = texture.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = Data(count: bytesPerRow * height)

        try Task.checkCancellation()

        let start = DispatchTime.now().uptimeNanoseconds
        let readbackTexture = try Self.makeCPUReadableTexture(from: texture)

        try data.withUnsafeMutableBytes { pointer in
            guard let baseAddress = pointer.baseAddress else {
                throw SnapshotExportError.readbackFailed("Could not allocate snapshot readback buffer.")
            }

            try Task.checkCancellation()

            let region = MTLRegionMake2D(0, 0, width, height)
            readbackTexture.getBytes(baseAddress,
                                     bytesPerRow: bytesPerRow,
                                     from: region,
                                     mipmapLevel: 0)
        }
        let end = DispatchTime.now().uptimeNanoseconds
        try Task.checkCancellation()

        let duration = TimeInterval(Double(end &- start) / 1_000_000_000.0)
        let metrics = SnapshotMetrics(label: "TextureSnapshotExporter.makeCGImage",
                                      readbackDuration: duration,
                                      byteCount: data.count,
                                      textureWidth: width,
                                      textureHeight: height,
                                      pixelFormat: pixelFormat)
        recordMetrics(metrics)
        CommandBufferProfiler.logSnapshotReadback(metrics)
        ClinicalProfiler.shared.recordSample(
            stage: .snapshotReadback,
            cpuTime: metrics.readbackMilliseconds,
            memory: metrics.byteCount,
            viewport: ProfilingViewportContext(
                resolutionWidth: width,
                resolutionHeight: height,
                viewportType: "snapshot",
                quality: frame.metadata.quality.profilingName,
                renderMode: frame.metadata.compositing.profilingName
            ),
            metadata: [
                "byteCount": String(metrics.byteCount),
                "width": String(metrics.textureWidth),
                "height": String(metrics.textureHeight),
                "label": metrics.label,
                "pixelFormat": Self.profilingLabel(for: pixelFormat)
            ],
            device: texture.device
        )

        guard let provider = CGDataProvider(data: data as CFData) else {
            throw SnapshotExportError.imageCreationFailed
        }

        guard let image = CGImage(width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo,
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: true,
                                  intent: .defaultIntent) else {
            throw SnapshotExportError.imageCreationFailed
        }

        return image
    }

    public func writePNG(from frame: VolumeRenderFrame, to url: URL) async throws {
        let image = try await makeCGImage(from: frame)
        try Self.writePNG(image, to: url)
    }

    private static func bitmapInfo(for pixelFormat: MTLPixelFormat) throws -> CGBitmapInfo {
        switch pixelFormat {
        case .bgra8Unorm:
            return CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                .union(.byteOrder32Little)
        case .rgba8Unorm:
            return CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                .union(.byteOrder32Big)
        default:
            throw SnapshotExportError.unsupportedPixelFormat(pixelFormat)
        }
    }

    private static func profilingLabel(for pixelFormat: MTLPixelFormat) -> String {
        switch pixelFormat {
        case .bgra8Unorm:
            return "bgra8Unorm"
        case .rgba8Unorm:
            return "rgba8Unorm"
        default:
            return "rawValue:\(pixelFormat.rawValue)"
        }
    }

    private static func makeCPUReadableTexture(from texture: any MTLTexture) throws -> any MTLTexture {
        try TextureReadbackHelper.makeCPUReadableTexture(from: texture,
                                                        stagingLabel: "TextureSnapshotExporter.ReadbackStaging")
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SnapshotExportError.fileWriteFailed(url, error.localizedDescription)
        }

        guard let destination = CGImageDestinationCreateWithURL(
            temporaryURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw SnapshotExportError.pngDestinationCreationFailed(url)
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? fileManager.removeItem(at: temporaryURL)
            throw SnapshotExportError.fileWriteFailed(url, "ImageIO could not finalize the PNG destination.")
        }

        do {
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw SnapshotExportError.fileWriteFailed(url, error.localizedDescription)
        }
    }

    private func recordMetrics(_ metrics: SnapshotMetrics) {
        lock.lock()
        storedLastMetrics = metrics
        lock.unlock()
    }
}

enum TextureReadbackHelper {
    static func makeCPUReadableTexture(from texture: any MTLTexture,
                                       stagingLabel: String) throws -> any MTLTexture {
        if texture.storageMode == .shared {
            return texture
        }

        guard let commandQueue = texture.device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeBlitCommandEncoder()
        else {
            throw SnapshotExportError.readbackFailed("Could not create texture readback blit resources.")
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat,
                                                                  width: texture.width,
                                                                  height: texture.height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
#if os(macOS)
        let useManagedReadback = !texture.device.hasUnifiedMemory
        descriptor.storageMode = useManagedReadback ? .managed : .shared
#else
        descriptor.storageMode = .shared
#endif

        guard let stagingTexture = texture.device.makeTexture(descriptor: descriptor) else {
            throw SnapshotExportError.readbackFailed("Could not create texture readback staging texture.")
        }
        stagingTexture.label = stagingLabel

        encoder.copy(from: texture,
                     sourceSlice: 0,
                     sourceLevel: 0,
                     sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                     sourceSize: MTLSize(width: texture.width,
                                         height: texture.height,
                                         depth: 1),
                     to: stagingTexture,
                     destinationSlice: 0,
                     destinationLevel: 0,
                     destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
#if os(macOS)
        if useManagedReadback {
            encoder.synchronize(resource: stagingTexture)
        }
#endif
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw SnapshotExportError.readbackFailed(error.localizedDescription)
        }

        return stagingTexture
    }
}
