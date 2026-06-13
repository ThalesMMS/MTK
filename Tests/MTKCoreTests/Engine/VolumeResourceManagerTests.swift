import Metal
import XCTest

@_spi(Testing) @testable import MTKCore

final class VolumeResourceManagerTests: XCTestCase {
    func test_concurrentAcquireForSameDatasetSharesInFlightUploadAndRetainsUntilAllHandlesRelease() async throws {
        let device = try makeDevice()
        let commandQueue = try makeCommandQueue(device: device)
        let uploadGate = DelayedDatasetUpload(device: device)
        let manager = VolumeResourceManager(
            device: device,
            commandQueue: commandQueue,
            datasetTextureUpload: uploadGate.upload(dataset:)
        )
        let harness = VolumeResourceManagerActor(manager: manager,
                                                 device: device,
                                                 commandQueue: commandQueue)
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 8, height: 8, depth: 8),
            pixelFormat: .int16Unsigned
        )

        async let firstHandle = harness.acquire(dataset: dataset)
        await uploadGate.waitUntilUploadCount(atLeast: 1)
        async let secondHandle = harness.acquire(dataset: dataset)
        await uploadGate.yieldForPendingAcquire()

        XCTAssertEqual(uploadGate.uploadCount, 1)

        uploadGate.resumeAll()
        let handles = try await [firstHandle, secondHandle]
        let initialTextureCount = await harness.textureCount
        let initialReferenceCount = await harness.totalReferenceCount
        let firstTextureID = await harness.textureObjectIdentifier(for: handles[0])
        let secondTextureID = await harness.textureObjectIdentifier(for: handles[1])

        XCTAssertEqual(initialTextureCount, 1)
        XCTAssertEqual(initialReferenceCount, 2)
        XCTAssertEqual(firstTextureID, secondTextureID)

        await harness.release(handle: handles[0])
        let firstHandleHasTextureAfterRelease = await harness.hasTexture(for: handles[0])
        let secondHandleHasTextureAfterRelease = await harness.hasTexture(for: handles[1])
        let textureCountAfterFirstRelease = await harness.textureCount
        let referenceCountAfterFirstRelease = await harness.totalReferenceCount

        XCTAssertFalse(firstHandleHasTextureAfterRelease)
        XCTAssertTrue(secondHandleHasTextureAfterRelease)
        XCTAssertEqual(textureCountAfterFirstRelease, 1)
        XCTAssertEqual(referenceCountAfterFirstRelease, 1)

        await harness.release(handle: handles[1])
        let finalTextureCount = await harness.textureCount
        let finalReferenceCount = await harness.totalReferenceCount

        XCTAssertEqual(finalTextureCount, 0)
        XCTAssertEqual(finalReferenceCount, 0)
    }

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

private actor VolumeResourceManagerActor {
    private let manager: VolumeResourceManager
    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue

    init(manager: VolumeResourceManager,
         device: any MTLDevice,
         commandQueue: any MTLCommandQueue) {
        self.manager = manager
        self.device = device
        self.commandQueue = commandQueue
    }

    var textureCount: Int { manager.debugTextureCount }
    var totalReferenceCount: Int { manager.debugTotalReferenceCount }

    func acquire(dataset: VolumeDataset) async throws -> VolumeResourceHandle {
        try await manager.acquire(dataset: dataset,
                                  device: device,
                                  commandQueue: commandQueue)
    }

    func release(handle: VolumeResourceHandle) {
        manager.release(handle: handle)
    }

    func hasTexture(for handle: VolumeResourceHandle) -> Bool {
        manager.texture(for: handle) != nil
    }

    func textureObjectIdentifier(for handle: VolumeResourceHandle) -> ObjectIdentifier? {
        manager.debugTextureObjectIdentifier(for: handle)
    }
}

private final class DelayedDatasetUpload: @unchecked Sendable {
    private let device: any MTLDevice
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var count: Int = 0

    init(device: any MTLDevice) {
        self.device = device
    }

    var uploadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func upload(dataset: VolumeDataset) async throws -> VolumeTextureUploader.UploadResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            count += 1
            continuations.append(continuation)
            lock.unlock()
        }

        let descriptor = VolumeTextureFactory.makeVolumeTextureDescriptor(
            dimensions: dataset.dimensions,
            pixelFormat: dataset.pixelFormat,
            storageMode: .private
        )
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw VolumeTextureFactory.TextureUploadError.textureCreationFailed
        }
        return VolumeTextureUploader.UploadResult(
            texture: texture,
            uploadTime: 0.001,
            peakMemoryBytes: nil
        )
    }

    func waitUntilUploadCount(atLeast targetCount: Int) async {
        while uploadCount < targetCount {
            await Task.yield()
        }
    }

    func yieldForPendingAcquire() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }

    func resumeAll() {
        let pending: [CheckedContinuation<Void, Never>]
        lock.lock()
        pending = continuations
        continuations.removeAll()
        lock.unlock()

        for continuation in pending {
            continuation.resume()
        }
    }
}
