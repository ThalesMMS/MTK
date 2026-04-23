import Metal
import XCTest

@_spi(Testing) @testable import MTKCore

final class VolumeResourceManagerDatasetReplacementTests: XCTestCase {
    func test_replaceDatasetReleasesOldHandleAndAcquiresNewDataset() async throws {
        let device = try makeDevice()
        let commandQueue = try makeCommandQueue(device: device)
        let manager = VolumeResourceManager(device: device, commandQueue: commandQueue)
        let firstDataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 8, height: 8, depth: 8),
            pixelFormat: .int16Signed
        )
        let secondDataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 4, height: 4, depth: 4),
            pixelFormat: .int16Unsigned,
            seed: 99
        )

        let oldHandle = try await manager.acquire(dataset: firstDataset,
                                                  device: device,
                                                  commandQueue: commandQueue)
        let newHandle = try await manager.replaceDataset(oldHandle: oldHandle,
                                                         newDataset: secondDataset)

        XCTAssertNil(manager.texture(for: oldHandle))
        XCTAssertNotNil(manager.texture(for: newHandle))
        XCTAssertEqual(manager.debugTextureCount, 1)
        XCTAssertEqual(manager.debugTotalReferenceCount, 1)
        XCTAssertEqual(manager.metadata(for: newHandle)?.pixelFormat, .r16Uint)
        XCTAssertEqual(manager.resourceMetrics().estimatedMemoryBytes,
                       ResourceMemoryEstimator.estimate(for: secondDataset))
    }

    func test_replaceDatasetWithSameDatasetKeepsSingleCachedTexture() async throws {
        let device = try makeDevice()
        let commandQueue = try makeCommandQueue(device: device)
        let manager = VolumeResourceManager(device: device, commandQueue: commandQueue)
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 8, height: 8, depth: 8),
            pixelFormat: .int16Signed
        )

        let oldHandle = try await manager.acquire(dataset: dataset,
                                                  device: device,
                                                  commandQueue: commandQueue)
        let oldTextureID = try XCTUnwrap(manager.debugTextureObjectIdentifier(for: oldHandle))
        let newHandle = try await manager.replaceDataset(oldHandle: oldHandle,
                                                         newDataset: dataset)
        let newTextureID = try XCTUnwrap(manager.debugTextureObjectIdentifier(for: newHandle))

        XCTAssertNil(manager.texture(for: oldHandle))
        XCTAssertEqual(oldTextureID, newTextureID)
        XCTAssertEqual(manager.debugTextureCount, 1)
        XCTAssertEqual(manager.debugTotalReferenceCount, 1)
    }

    func test_diagnosticLifecycleLoggingFlagDoesNotChangeReplacementBehavior() async throws {
        let device = try makeDevice()
        let commandQueue = try makeCommandQueue(device: device)
        let manager = VolumeResourceManager(device: device,
                                            commandQueue: commandQueue,
                                            featureFlags: [.diagnosticLogging])
        let firstDataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 4, height: 4, depth: 4),
            pixelFormat: .int16Signed
        )
        let secondDataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 4, height: 4, depth: 4),
            pixelFormat: .int16Unsigned,
            seed: 23
        )

        let oldHandle = try await manager.acquire(dataset: firstDataset,
                                                  device: device,
                                                  commandQueue: commandQueue)
        _ = try await manager.replaceDataset(oldHandle: oldHandle,
                                             newDataset: secondDataset)

        XCTAssertEqual(manager.debugTextureCount, 1)
        XCTAssertEqual(manager.debugTotalReferenceCount, 1)
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
