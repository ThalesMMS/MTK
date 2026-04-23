import Metal
import XCTest

@_spi(Testing) @testable import MTKCore

final class VolumeResourceManagerTests: XCTestCase {
    func test_acquirePopulatesHandleMetadataFromVolumeTexture() async throws {
        let device = try makeDevice()
        let commandQueue = try makeCommandQueue(device: device)
        let manager = VolumeResourceManager(device: device, commandQueue: commandQueue)
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 4, height: 8, depth: 2),
            pixelFormat: .int16Signed
        )

        let handle = try await manager.acquire(dataset: dataset,
                                               device: device,
                                               commandQueue: commandQueue)
        let texture = try XCTUnwrap(manager.texture(for: handle))
        let metadata = handle.metadata

        XCTAssertEqual(metadata.resourceType, .volume)
        XCTAssertEqual(metadata.estimatedBytes, ResourceMemoryEstimator.estimate(for: texture))
        XCTAssertEqual(metadata.pixelFormat, texture.pixelFormat)
        XCTAssertEqual(metadata.storageMode, texture.storageMode)
        XCTAssertEqual(metadata.dimensions.width, texture.width)
        XCTAssertEqual(metadata.dimensions.height, texture.height)
        XCTAssertEqual(metadata.dimensions.depth, texture.depth)
        XCTAssertEqual(manager.metadata(for: handle), metadata)
    }

    @MainActor
    func test_transferTextureAccessIsTrackedInResourceMetrics() throws {
        let device = try makeDevice()
        let commandQueue = try makeCommandQueue(device: device)
        let manager = VolumeResourceManager(device: device, commandQueue: commandQueue)

        let texture = try XCTUnwrap(manager.transferTexture(for: .ctBone, device: device))
        let metrics = manager.resourceMetrics()

        XCTAssertEqual(manager.debugTransferTextureCount, 1)
        XCTAssertEqual(metrics.volumeTextureCount, 0)
        XCTAssertEqual(metrics.transferTextureCount, 1)
        XCTAssertEqual(metrics.outputTexturePoolSize, 0)
        XCTAssertEqual(metrics.breakdown.transferTextures, ResourceMemoryEstimator.estimate(for: texture))
        XCTAssertEqual(metrics.estimatedMemoryBytes, ResourceMemoryEstimator.estimate(for: texture))
        XCTAssertEqual(metrics.resources.first?.resourceType, .transferFunction)
    }

    func test_replaceDatasetReleasesOldResourceAndAcquiresDataChangedDataset() async throws {
        let device = try makeDevice()
        let commandQueue = try makeCommandQueue(device: device)
        let manager = VolumeResourceManager(device: device, commandQueue: commandQueue)
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 4, height: 4, depth: 4),
            pixelFormat: .int16Unsigned
        )
        let changedDataset = VolumeDatasetTestFactory.makeDataChangedDataset(from: dataset)

        let oldHandle = try await manager.acquire(dataset: dataset,
                                                  device: device,
                                                  commandQueue: commandQueue)
        let oldTextureID = try XCTUnwrap(manager.debugTextureObjectIdentifier(for: oldHandle))
        let newHandle = try await manager.replaceDataset(oldHandle: oldHandle,
                                                         newDataset: changedDataset)
        let newTextureID = try XCTUnwrap(manager.debugTextureObjectIdentifier(for: newHandle))

        XCTAssertNil(manager.texture(for: oldHandle))
        XCTAssertNotEqual(oldTextureID, newTextureID)
        XCTAssertNotNil(manager.texture(for: newHandle))
        XCTAssertEqual(manager.debugTextureCount, 1)
        XCTAssertEqual(manager.debugTotalReferenceCount, 1)
        XCTAssertEqual(manager.resourceMetrics().volumeTextureCount, 1)
        XCTAssertEqual(manager.memoryBreakdown().volumeTextures,
                       ResourceMemoryEstimator.estimate(for: changedDataset))
    }

    private func makeDevice() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        return device
    }

    private func makeCommandQueue(device: any MTLDevice) throws -> any MTLCommandQueue {
        guard let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal command queue unavailable on this test runner")
        }
        return commandQueue
    }
}
