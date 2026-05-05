import Metal
import XCTest

@testable import MTKCore

final class VolumeLayerCompositePassTests: XCTestCase {
    func test_sourceOverCompositionIsDeterministicForSinglePixel() async throws {
        let setup = try makeSetup()
        let base = try makeTexture(device: setup.device, bgra: [0, 0, 0, 0])
        let overlay = try makeTexture(device: setup.device, bgra: [0, 0, 128, 128])
        let destination = try makeTexture(device: setup.device, bgra: [0, 0, 0, 0])

        try await setup.pass.composite(baseTexture: base,
                                       overlayTexture: overlay,
                                       destinationTexture: destination,
                                       overlayOpacity: 0.5,
                                       blendMode: .sourceOver,
                                       commandQueue: setup.commandQueue)

        XCTAssertEqual(try readBGRA(destination, setup: setup), [0, 0, 64, 64], accuracy: 2)
    }

    func test_additiveCompositionClampsPredictablyForSinglePixel() async throws {
        let setup = try makeSetup()
        let base = try makeTexture(device: setup.device, bgra: [64, 0, 0, 64])
        let overlay = try makeTexture(device: setup.device, bgra: [0, 0, 255, 255])
        let destination = try makeTexture(device: setup.device, bgra: [0, 0, 0, 0])

        try await setup.pass.composite(baseTexture: base,
                                       overlayTexture: overlay,
                                       destinationTexture: destination,
                                       overlayOpacity: 1,
                                       blendMode: .additive,
                                       commandQueue: setup.commandQueue)

        XCTAssertEqual(try readBGRA(destination, setup: setup), [64, 0, 255, 255], accuracy: 1)
    }

    func test_zeroOpacityLayerDoesNotAffectOutput() async throws {
        let setup = try makeSetup()
        let base = try makeTexture(device: setup.device, bgra: [48, 32, 16, 255])
        let overlay = try makeTexture(device: setup.device, bgra: [0, 0, 255, 255])
        let destination = try makeTexture(device: setup.device, bgra: [0, 0, 0, 0])

        try await setup.pass.composite(baseTexture: base,
                                       overlayTexture: overlay,
                                       destinationTexture: destination,
                                       overlayOpacity: 0,
                                       blendMode: .additive,
                                       commandQueue: setup.commandQueue)

        XCTAssertEqual(try readBGRA(destination, setup: setup), [48, 32, 16, 255], accuracy: 1)
    }

    private func makeSetup() throws -> (device: any MTLDevice, commandQueue: any MTLCommandQueue, pass: VolumeLayerCompositePass) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal command queue unavailable")
        }
        return (device, commandQueue, try VolumeLayerCompositePass(device: device))
    }

    private func makeTexture(device: any MTLDevice, bgra: [UInt8]) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: 1,
                                                                  height: 1,
                                                                  mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("Unable to create test texture")
        }
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                        mipmapLevel: 0,
                        withBytes: bgra,
                        bytesPerRow: 4)
        return texture
    }

    private func readBGRA(
        _ texture: any MTLTexture,
        setup: (device: any MTLDevice, commandQueue: any MTLCommandQueue, pass: VolumeLayerCompositePass)
    ) throws -> [UInt8] {
        try MPRTextureReadbackHelper.readBytes(from: texture,
                                               bytesPerPixel: 4,
                                               device: setup.device,
                                               commandQueue: setup.commandQueue)
    }
}

private extension XCTestCase {
    func XCTAssertEqual(_ actual: [UInt8],
                        _ expected: [UInt8],
                        accuracy: UInt8,
                        file: StaticString = #filePath,
                        line: UInt = #line) {
        guard actual.count == expected.count else {
            XCTFail("actual count=\(actual.count), expected count=\(expected.count)", file: file, line: line)
            return
        }
        for (actualValue, expectedValue) in zip(actual, expected) {
            let delta = abs(Int(actualValue) - Int(expectedValue))
            XCTAssertLessThanOrEqual(delta, Int(accuracy),
                                     "actual=\(actual), expected=\(expected)",
                                     file: file,
                                     line: line)
        }
    }
}
