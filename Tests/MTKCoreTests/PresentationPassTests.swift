import CoreGraphics
import Metal
import XCTest

@_spi(Testing) @testable import MTKCore

final class PresentationPassTests: MTKRenderingEngineTestCase {
    func testRejectsNilDrawableBeforeEncoding() throws {
        let device = try requireMetalDevice()
        let texture = try makeTexture(device: device,
                                      width: 4,
                                      height: 4,
                                      pixelFormat: .bgra8Unorm)
        guard let queue = texture.device.makeCommandQueue() else {
            throw XCTSkip("Metal command queue unavailable on this test runner")
        }
        let pass = PresentationPass()

        XCTAssertThrowsError(try pass.present(texture, to: nil, commandQueue: queue)) { error in
            XCTAssertEqual(error as? PresentationPassError, .drawableUnavailable)
        }
    }

    func testReleasesLeaseWhenDrawableUnavailable() async throws {
        _ = try requireMetalDevice()

        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D,
                               initialSize: CGSize(width: 8, height: 8))
        )
        try await engine.setVolume(testDataset, for: viewport)

        let frame = try await engine.render(viewport)
        let lease = try XCTUnwrap(frame.outputTextureLease)
        guard let queue = frame.texture.device.makeCommandQueue() else {
            throw XCTSkip("Metal command queue unavailable on this test runner")
        }

        do {
            _ = try PresentationPass().present(frame.texture,
                                               to: nil,
                                               commandQueue: queue,
                                               lease: lease)
            XCTFail("Expected drawableUnavailable")
        } catch {
            XCTAssertEqual(error as? PresentationPassError, .drawableUnavailable)
        }

        XCTAssertTrue(lease.isReleased)
        let poolInUseCount = await engine.debugOutputPoolInUseCount
        XCTAssertEqual(poolInUseCount, 0)
    }

    func testSourceDoesNotUseReadbackOrCGImage() throws {
        let source = try String(contentsOfFile: sourceFilePath("Sources/MTKCore/Rendering/PresentationPass.swift"))

        assertSourceDoesNotUseReadbackOrCGImage(source)
    }

    private func requireMetalDevice() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        return device
    }

    private func makeTexture(device: any MTLDevice,
                             width: Int,
                             height: Int,
                             pixelFormat: MTLPixelFormat) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("Unable to allocate Metal texture")
        }
        return texture
    }
}
