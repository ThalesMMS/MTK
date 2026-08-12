import CoreGraphics
import Foundation
import Metal
import XCTest

@testable import MTKCore

final class TextureSnapshotExporterTests: XCTestCase {
    func testMakeCGImageReadsSupportedBGRAFrameOnDemand() async throws {
        let device = try requireMetalDevice()
        let expectedBytes: [UInt8] = [
            0, 0, 255, 255,
            0, 255, 0, 255,
            255, 0, 0, 255,
            255, 255, 255, 255
        ]
        let frame = try makeFrame(device: device,
                                  pixelFormat: .bgra8Unorm,
                                  bytes: expectedBytes)
        let exporter = TextureSnapshotExporter()

        let image = try await exporter.makeCGImage(from: frame)

        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.bytesPerRow, 8)
        XCTAssertEqual(try bgraBytes(from: image), expectedBytes)
        let metrics = try XCTUnwrap(exporter.lastOperationMetrics())
        XCTAssertEqual(metrics.textureWidth, 2)
        XCTAssertEqual(metrics.textureHeight, 2)
        XCTAssertEqual(metrics.pixelFormat, .bgra8Unorm)
        XCTAssertEqual(metrics.byteCount, 16)
        XCTAssertEqual(exporter.lastReadbackDuration, metrics.readbackDuration)
    }

    func testWritePNGCreatesFileExplicitly() async throws {
        let device = try requireMetalDevice()
        let frame = try makeFrame(device: device,
                                  pixelFormat: .rgba8Unorm,
                                  bytes: [
                                      255, 0, 0, 255,
                                      0, 255, 0, 255,
                                      0, 0, 255, 255,
                                      255, 255, 255, 255
                                  ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: url) }

        try await TextureSnapshotExporter().writePNG(from: frame, to: url)

        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 8)
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    func testUnsupportedPixelFormatFailsBeforeReadback() async throws {
        let device = try requireMetalDevice()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var byte: UInt8 = 1
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                        mipmapLevel: 0,
                        withBytes: &byte,
                        bytesPerRow: 1)
        let frame = VolumeRenderFrame(
            texture: texture,
            metadata: VolumeRenderFrame.Metadata(
                viewportSize: CGSize(width: 1, height: 1),
                samplingDistance: 1,
                compositing: .frontToBack,
                quality: .interactive,
                pixelFormat: .r8Unorm
            )
        )

        do {
            _ = try await TextureSnapshotExporter().makeCGImage(from: frame)
            XCTFail("Expected unsupported pixel format")
        } catch SnapshotExportError.unsupportedPixelFormat(let format) {
            XCTAssertEqual(format, .r8Unorm)
        }
    }

    /// A discarded blit leaves the staging texture exactly as allocated — all zeroes — and
    /// the command buffer carries no error, so the readback would otherwise report a black
    /// frame as a snapshot.
    func testReadbackFailsWhenTheBlitNeverRan() throws {
        let device = try requireMetalDevice()
        let source = try makePrivateSource(device: device)

        XCTAssertThrowsError(
            try TextureReadbackHelper.makeCPUReadableTexture(from: source,
                                                             stagingLabel: "Test.Staging",
                                                             discardedCopiesForTesting: 2)
        ) { error in
            guard case SnapshotExportError.readbackFailed(let description)? = error as? SnapshotExportError else {
                XCTFail("Expected readbackFailed, got \(error)")
                return
            }
            XCTAssertTrue(description.contains("did not run"), description)
        }
    }

    func testReadbackRecoversWhenOnlyTheFirstBlitIsDiscarded() throws {
        let device = try requireMetalDevice()
        let source = try makePrivateSource(device: device)

        let staging = try TextureReadbackHelper.makeCPUReadableTexture(from: source,
                                                                       stagingLabel: "Test.Staging",
                                                                       discardedCopiesForTesting: 1)

        let bytes = MPRTextureReadbackHelper.readBytes(from: staging, bytesPerRow: 8, byteCount: 16)
        XCTAssertEqual(bytes, Self.privateSourceBytes,
                       "the retry should read the real pixels, not the untouched staging texture")
    }

    private static let privateSourceBytes: [UInt8] = [
        1, 2, 3, 255,
        4, 5, 6, 255,
        7, 8, 9, 255,
        10, 11, 12, 255
    ]

    /// A `.private` source, because a `.shared` one is returned without any blit at all.
    private func makePrivateSource(device: any MTLDevice) throws -> any MTLTexture {
        let upload = try makeFrame(device: device,
                                   pixelFormat: .bgra8Unorm,
                                   bytes: Self.privateSourceBytes).texture

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                   width: 2,
                                                                   height: 2,
                                                                   mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead]
        let source = try XCTUnwrap(device.makeTexture(descriptor: descriptor))

        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: upload,
                  sourceSlice: 0,
                  sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: 2, height: 2, depth: 1),
                  to: source,
                  destinationSlice: 0,
                  destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        try XCTSkipUnless(commandBuffer.status == .completed,
                          "Could not stage the private source texture on this runner")
        return source
    }

    private func makeFrame(device: any MTLDevice,
                           pixelFormat: MTLPixelFormat,
                           bytes: [UInt8]) throws -> VolumeRenderFrame {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: 2,
            height: 2,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]

        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        bytes.withUnsafeBytes { buffer in
            texture.replace(region: MTLRegionMake2D(0, 0, 2, 2),
                            mipmapLevel: 0,
                            withBytes: buffer.baseAddress!,
                            bytesPerRow: 8)
        }

        return VolumeRenderFrame(
            texture: texture,
            metadata: VolumeRenderFrame.Metadata(
                viewportSize: CGSize(width: 2, height: 2),
                samplingDistance: 1,
                compositing: .frontToBack,
                quality: .interactive,
                pixelFormat: pixelFormat
            )
        )
    }

    private func requireMetalDevice() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        return device
    }

    private func bgraBytes(from image: CGImage) throws -> [UInt8] {
        let bytesPerPixel = 4
        let bytesPerRow = image.width * bytesPerPixel
        var data = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)

        try data.withUnsafeMutableBytes { pointer in
            let context = try XCTUnwrap(
                CGContext(data: pointer.baseAddress,
                          width: image.width,
                          height: image.height,
                          bitsPerComponent: 8,
                          bytesPerRow: bytesPerRow,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: bitmapInfo.rawValue)
            )
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }

        return data
    }
}
