import XCTest
import Metal
@testable import MTKCore

final class VolumeTextureFactoryAsyncTests: XCTestCase {

    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Failed to create command queue")
        }
        self.commandQueue = queue
    }

    // MARK: - Small Dataset Tests

    func testAsyncTextureUploadWithSmallDataset() async throws {
        let dataset = makeSmallTestDataset()
        let factory = VolumeTextureFactory(dataset: dataset)

        let texture = try await factory.generateAsync(device: device, commandQueue: commandQueue)

        XCTAssertNotNil(texture)
        XCTAssertEqual(texture.width, dataset.dimensions.width)
        XCTAssertEqual(texture.height, dataset.dimensions.height)
        XCTAssertEqual(texture.depth, dataset.dimensions.depth)
        XCTAssertEqual(texture.textureType, .type3D)
        XCTAssertEqual(texture.pixelFormat, .r16Uint)
    }

    func testAsyncTextureHasCorrectLabel() async throws {
        let dataset = makeSmallTestDataset()
        let factory = VolumeTextureFactory(dataset: dataset)

        let texture = try await factory.generateAsync(device: device, commandQueue: commandQueue)

        XCTAssertEqual(texture.label, "VolumeTexture3D")
    }

    // MARK: - Typical CT Dataset Size Tests

    func testAsyncTextureUploadWithTypicalCTDatasetSize() async throws {
        let dataset = makeTypicalCTDataset()
        let factory = VolumeTextureFactory(dataset: dataset)

        let texture = try await factory.generateAsync(device: device, commandQueue: commandQueue)

        XCTAssertNotNil(texture)
        XCTAssertEqual(texture.width, 512)
        XCTAssertEqual(texture.height, 512)
        XCTAssertEqual(texture.depth, 179)
        XCTAssertEqual(texture.textureType, .type3D)
        XCTAssertEqual(texture.pixelFormat, .r16Sint)
    }

    func testAsyncTextureUploadWithLargeDataset() async throws {
        let dataset = makeLargeTestDataset()
        let factory = VolumeTextureFactory(dataset: dataset)

        let texture = try await factory.generateAsync(device: device, commandQueue: commandQueue)

        XCTAssertNotNil(texture)
        XCTAssertEqual(texture.width, 256)
        XCTAssertEqual(texture.height, 256)
        XCTAssertEqual(texture.depth, 256)
    }

    // MARK: - Different Pixel Format Tests

    func testAsyncTextureUploadWithSignedInt16Format() async throws {
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        let values: [Int16] = Array(repeating: -500, count: dimensions.voxelCount)
        let data = values.withUnsafeBytes { Data($0) }
        let dataset = VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed
        )
        let factory = VolumeTextureFactory(dataset: dataset)

        let texture = try await factory.generateAsync(device: device, commandQueue: commandQueue)

        XCTAssertNotNil(texture)
        XCTAssertEqual(texture.pixelFormat, .r16Sint)
    }

    func testAsyncTextureUploadWithUnsignedInt16Format() async throws {
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        let values: [UInt16] = Array(repeating: 1000, count: dimensions.voxelCount)
        let data = values.withUnsafeBytes { Data($0) }
        let dataset = VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned
        )
        let factory = VolumeTextureFactory(dataset: dataset)

        let texture = try await factory.generateAsync(device: device, commandQueue: commandQueue)

        XCTAssertNotNil(texture)
        XCTAssertEqual(texture.pixelFormat, .r16Uint)
    }

    // MARK: - Comparison with Synchronous Method

    func testAsyncAndSyncMethodsProduceSameDimensions() async throws {
        let dataset = makeSmallTestDataset()
        let factory = VolumeTextureFactory(dataset: dataset)

        let syncTexture = try XCTUnwrap(factory.generate(device: device))
        let asyncTexture = try await factory.generateAsync(device: device, commandQueue: commandQueue)

        XCTAssertEqual(syncTexture.width, asyncTexture.width)
        XCTAssertEqual(syncTexture.height, asyncTexture.height)
        XCTAssertEqual(syncTexture.depth, asyncTexture.depth)
        XCTAssertEqual(syncTexture.pixelFormat, asyncTexture.pixelFormat)
        XCTAssertEqual(syncTexture.textureType, asyncTexture.textureType)
    }

    // MARK: - Multiple Uploads

    func testMultipleAsyncUploadsSucceed() async throws {
        let dataset = makeSmallTestDataset()
        let factory = VolumeTextureFactory(dataset: dataset)

        let texture1 = try await factory.generateAsync(device: device, commandQueue: commandQueue)
        let texture2 = try await factory.generateAsync(device: device, commandQueue: commandQueue)

        XCTAssertNotNil(texture1)
        XCTAssertNotNil(texture2)
        XCTAssertEqual(texture1.width, texture2.width)
        XCTAssertEqual(texture1.height, texture2.height)
        XCTAssertEqual(texture1.depth, texture2.depth)
    }

    // MARK: - Dataset Update Tests

    func testAsyncUploadAfterDatasetUpdate() async throws {
        let initialDataset = makeSmallTestDataset()
        let factory = VolumeTextureFactory(dataset: initialDataset)

        let texture1 = try await factory.generateAsync(device: device, commandQueue: commandQueue)
        XCTAssertEqual(texture1.width, 2)
        XCTAssertEqual(texture1.height, 2)
        XCTAssertEqual(texture1.depth, 2)

        let newDataset = makeTypicalCTDataset()
        factory.update(dataset: newDataset)

        let texture2 = try await factory.generateAsync(device: device, commandQueue: commandQueue)
        XCTAssertEqual(texture2.width, 512)
        XCTAssertEqual(texture2.height, 512)
        XCTAssertEqual(texture2.depth, 179)
    }

    // MARK: - Helpers

    private func makeSmallTestDataset() -> VolumeDataset {
        let dimensions = VolumeDimensions(width: 2, height: 2, depth: 2)
        let values: [UInt16] = Array(repeating: 1_000, count: dimensions.voxelCount)
        let data = values.withUnsafeBytes { Data($0) }
        return VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned
        )
    }

    private func makeTypicalCTDataset() -> VolumeDataset {
        let dimensions = VolumeDimensions(width: 512, height: 512, depth: 179)
        let values: [Int16] = Array(repeating: -500, count: dimensions.voxelCount)
        let data = values.withUnsafeBytes { Data($0) }
        return VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 0.000586, y: 0.000586, z: 0.002),
            pixelFormat: .int16Signed,
            intensityRange: (-1024)...3071
        )
    }

    private func makeLargeTestDataset() -> VolumeDataset {
        let dimensions = VolumeDimensions(width: 256, height: 256, depth: 256)
        let values: [UInt16] = Array(repeating: 2_000, count: dimensions.voxelCount)
        let data = values.withUnsafeBytes { Data($0) }
        return VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 0.001, y: 0.001, z: 0.001),
            pixelFormat: .int16Unsigned
        )
    }
}
