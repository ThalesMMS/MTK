import Metal
import XCTest

@testable import MTKCore

final class ArgumentEncoderManagerOutputTextureTests: XCTestCase {
    func test_setOutputTextureBindsExternalTextureAndUpdatesOutputState() throws {
        let device = try makeDevice()
        let manager = try makeArgumentEncoderManager(device: device)
        let texture = try makeTexture(device: device, width: 40, height: 24, pixelFormat: .bgra8Unorm)

        manager.setOutputTexture(texture)

        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(manager.outputTexture) as AnyObject),
                       ObjectIdentifier(texture as AnyObject))
        XCTAssertEqual(manager.currentOutputWidth, 40)
        XCTAssertEqual(manager.currentOutputHeight, 24)
        XCTAssertEqual(manager.currentPxByteSize, ResourceMemoryEstimator.estimate(for: texture))
        XCTAssertEqual(manager.debugNeedsUpdateState(for: .outputTexture), false)
        XCTAssertNotNil(manager.debugBoundBuffer(for: .legacyOutputBuffer))
    }

    func test_encodeOutputTextureStillCreatesInternalTexture() throws {
        let device = try makeDevice()
        let manager = try makeArgumentEncoderManager(device: device)

        manager.encodeOutputTexture(width: 16, height: 12)

        let texture = try XCTUnwrap(manager.outputTexture)
        XCTAssertEqual(texture.width, 16)
        XCTAssertEqual(texture.height, 12)
        XCTAssertEqual(texture.pixelFormat, .bgra8Unorm)
        XCTAssertEqual(texture.storageMode, .private)
        XCTAssertEqual(manager.currentPxByteSize, 16 * 12 * 4)
        XCTAssertEqual(manager.debugNeedsUpdateState(for: .outputTexture), false)
    }

    private func makeDevice() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        return device
    }

    private func makeArgumentEncoderManager(device: any MTLDevice) throws -> ArgumentEncoderManager {
        let library = try ShaderLibraryLoader.loadLibrary(for: device)
        guard let function = library.makeFunction(name: "volume_compute") else {
            throw XCTSkip("volume_compute not available in shader library")
        }

        return ArgumentEncoderManager(
            device: device,
            mtlFunction: function,
            debugOptions: VolumeRenderingDebugOptions()
        )
    }

    private func makeTexture(device: any MTLDevice,
                             width: Int,
                             height: Int,
                             pixelFormat: MTLPixelFormat) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderWrite, .shaderRead, .pixelFormatView]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("Failed to create test texture")
        }
        return texture
    }
}
