//
//  MetalMPRComputeAdapterVolumeTextureCacheTests.swift
//  MTK
//
//  Unit tests for MetalMPRComputeAdapter internal volume texture caching.
//

import XCTest
import Metal
@_spi(Testing) @testable import MTKCore

final class MetalMPRComputeAdapterVolumeTextureCacheTests: MetalMPRComputeAdapterTestCase {

    func test_makeTextureFrameReusesVolumeTextureForSameDataset() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        let firstFrame = try await adapter.makeTextureFrame(
            dataset: dataset,
            plane: plane,
            thickness: 5,
            steps: 5,
            blend: .average
        )
        firstFrame.debugReleaseOutputTextureLease()

        let cachedIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertNotNil(cachedIdentity)
        XCTAssertEqual(cachedIdentity?.count, dataset.data.count)
        XCTAssertEqual(cachedIdentity?.dimensions, dataset.dimensions)
        XCTAssertEqual(cachedIdentity?.pixelFormat, dataset.pixelFormat)
        let storageMode = await adapter.debugCachedVolumeTextureStorageModeRawValue
        let usage = await adapter.debugCachedVolumeTextureUsageRawValue
        XCTAssertEqual(storageMode, MTLStorageMode.private.rawValue)
        XCTAssertEqual(usage, MTLTextureUsage.shaderRead.rawValue)

        let secondFrame = try await adapter.makeTextureFrame(
            dataset: dataset,
            plane: plane,
            thickness: 5,
            steps: 5,
            blend: .maximum
        )
        defer { secondFrame.debugReleaseOutputTextureLease() }

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 1)
    }

    func test_makeTextureFrameReusesInternalTexturesAcrossIterations() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(pixelFormat: .int16Signed)
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        for _ in 0..<10 {
            let frame = try await adapter.makeTextureFrame(dataset: dataset, plane: plane, thickness: 5, steps: 5, blend: .average)
            defer { frame.debugReleaseOutputTextureLease() }
            MPRTestHelpers.assertValidFrame(frame,
                                            expectedWidth: 64,
                                            expectedHeight: 64,
                                            expectedPixelFormat: dataset.pixelFormat)
            XCTAssertEqual(try MPRTestHelpers.readInputValues(Int16.self, from: frame).count, 64 * 64)
        }

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 1)
        let outputAllocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertGreaterThan(outputAllocationCount, 0)
    }

    func test_concurrentMakeTextureFrame_coalescesVolumeUpload() async throws {
        let dimensions = VolumeDimensions(width: 128, height: 128, depth: 128)
        let dataset = VolumeDatasetTestFactory.makeTestDataset(dimensions: dimensions,
                                                               pixelFormat: .int16Signed)
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)
        let gate = VolumeTextureUploadTestGate()
        await adapter.setVolumeTextureUploadTestingHooks(
            beforeUpload: { await gate.holdUpload() },
            onJoin: { await gate.recordJoin() }
        )

        let firstFrame = Task {
            try await adapter.makeTextureFrame(dataset: dataset,
                                               plane: plane,
                                               thickness: 3,
                                               steps: 3,
                                               blend: .single)
        }
        try await gate.waitUntilUploadStarts()
        let secondFrame = Task {
            try await adapter.makeTextureFrame(dataset: dataset,
                                               plane: plane,
                                               thickness: 3,
                                               steps: 3,
                                               blend: .maximum)
        }
        try await gate.waitUntilRequestJoins()
        await gate.releaseUpload()
        let frames = try await [firstFrame.value, secondFrame.value]
        defer { frames.forEach { $0.outputTextureLease?.release() } }
        await adapter.setVolumeTextureUploadTestingHooks(beforeUpload: nil, onJoin: nil)

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 1)
    }

    func test_newDatasetUpload_cancelsSupersededUpload() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(pixelFormat: .int16Signed)
        let replacement = VolumeDatasetTestFactory.makeDataChangedDataset(from: dataset)
        let gate = VolumeTextureUploadTestGate()
        await adapter.setVolumeTextureUploadTestingHooks(
            beforeUpload: { await gate.holdUpload() },
            onJoin: nil
        )

        let firstFrame = Task {
            try await adapter.makeTextureFrame(
                dataset: dataset,
                plane: MPRTestHelpers.makeTestPlaneGeometry(for: dataset),
                thickness: 3,
                steps: 3,
                blend: .single
            )
        }
        try await gate.waitUntilUploadStarts(count: 1)
        let replacementFrame = Task {
            try await adapter.makeTextureFrame(
                dataset: replacement,
                plane: MPRTestHelpers.makeTestPlaneGeometry(for: replacement),
                thickness: 3,
                steps: 3,
                blend: .single
            )
        }
        try await gate.waitUntilUploadStarts(count: 2)
        await gate.releaseUploads()

        do {
            _ = try await firstFrame.value
            XCTFail("Expected the superseded upload to fail after cancellation")
        } catch {
            guard let computeError = error as? MetalMPRComputeAdapter.ComputeError else {
                return XCTFail("Expected ComputeError, got \(error)")
            }
            guard case .volumeTextureCreationFailed = computeError else {
                return XCTFail("Expected volumeTextureCreationFailed, got \(computeError)")
            }
        }
        let frame = try await replacementFrame.value
        defer { frame.outputTextureLease?.release() }

        let uploadCount = await adapter.debugTextureUploadCount
        let cachedIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertEqual(uploadCount, 1)
        XCTAssertEqual(cachedIdentity?.contentFingerprint,
                       DatasetIdentity.Content(dataset: replacement).contentFingerprint)
    }

    func test_cacheInvalidatesOnDimensionChange() async throws {
        let dimensionsA = VolumeDimensions(width: 64, height: 64, depth: 64)
        let dimensionsB = VolumeDimensions(width: 32, height: 64, depth: 128)
        let sharedData = try VolumeDatasetTestFactory.makeSharedTestData(
            dimensions: dimensionsA,
            pixelFormat: .int16Unsigned,
            seed: 17
        )
        let datasetA = VolumeDatasetTestFactory.makeTestDataset(data: sharedData.data, dimensions: dimensionsA, pixelFormat: .int16Unsigned)
        let datasetB = VolumeDatasetTestFactory.makeTestDataset(data: sharedData.data, dimensions: dimensionsB, pixelFormat: .int16Unsigned)
        let planeA = MPRTestHelpers.makeTestPlaneGeometry(for: datasetA)
        let planeB = MPRTestHelpers.makeTestPlaneGeometry(for: datasetB)

        let firstFrame = try await adapter.makeTextureFrame(
            dataset: datasetA,
            plane: planeA,
            thickness: 5,
            steps: 5,
            blend: .single
        )
        firstFrame.debugReleaseOutputTextureLease()
        let initialIdentity = await adapter.debugCachedDatasetIdentity

        let secondFrame = try await adapter.makeTextureFrame(
            dataset: datasetB,
            plane: planeB,
            thickness: 5,
            steps: 5,
            blend: .single
        )
        defer { secondFrame.debugReleaseOutputTextureLease() }

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 2)
        let cachedIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertEqual(cachedIdentity?.count, initialIdentity?.count)
        XCTAssertEqual(cachedIdentity?.dimensions, datasetB.dimensions)
        XCTAssertEqual(cachedIdentity?.pixelFormat, datasetB.pixelFormat)
        XCTAssertNotEqual(cachedIdentity?.dimensions, initialIdentity?.dimensions)
        XCTAssertEqual(cachedIdentity?.contentFingerprint, initialIdentity?.contentFingerprint)
    }

    func test_cacheInvalidatesOnDataChange() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        let firstFrame = try await adapter.makeTextureFrame(
            dataset: dataset,
            plane: plane,
            thickness: 3,
            steps: 3,
            blend: .single
        )
        firstFrame.debugReleaseOutputTextureLease()
        let initialIdentity = await adapter.debugCachedDatasetIdentity

        let mutatedDataset = VolumeDatasetTestFactory.makeDataChangedDataset(from: dataset)
        let secondFrame = try await adapter.makeTextureFrame(
            dataset: mutatedDataset,
            plane: plane,
            thickness: 3,
            steps: 3,
            blend: .single
        )
        defer { secondFrame.debugReleaseOutputTextureLease() }

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 2)
        let updatedIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertEqual(updatedIdentity?.count, mutatedDataset.data.count)
        XCTAssertEqual(updatedIdentity?.dimensions, mutatedDataset.dimensions)
        XCTAssertEqual(updatedIdentity?.pixelFormat, mutatedDataset.pixelFormat)
        XCTAssertNotEqual(updatedIdentity?.contentFingerprint, initialIdentity?.contentFingerprint)
    }

    func test_cacheReusesTextureForEquivalentContentInDifferentStorage() async throws {
        let datasetA = VolumeDatasetTestFactory.makeTestDataset()
        let copiedData = datasetA.data.withUnsafeBytes { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count)
        }
        let datasetB = VolumeDataset(data: copiedData, imageData: datasetA.imageData)
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: datasetA)

        let firstFrame = try await adapter.makeTextureFrame(dataset: datasetA,
                                                            plane: plane,
                                                            thickness: 3,
                                                            steps: 3,
                                                            blend: .single)
        firstFrame.debugReleaseOutputTextureLease()
        let secondFrame = try await adapter.makeTextureFrame(dataset: datasetB,
                                                             plane: plane,
                                                             thickness: 3,
                                                             steps: 3,
                                                             blend: .single)
        defer { secondFrame.debugReleaseOutputTextureLease() }

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 1)
    }

    func test_cacheInvalidatesOnPixelFormatChange() async throws {
        let dimensions = VolumeDimensions(width: 64, height: 64, depth: 64)
        let sharedData = try VolumeDatasetTestFactory.makeSharedTestData(
            dimensions: dimensions,
            pixelFormat: .int16Unsigned,
            seed: 23
        )
        let datasetA = VolumeDatasetTestFactory.makeTestDataset(data: sharedData.data, dimensions: dimensions, pixelFormat: .int16Unsigned)
        let datasetB = VolumeDatasetTestFactory.makeTestDataset(data: sharedData.data, dimensions: dimensions, pixelFormat: .int16Signed)
        let planeA = MPRTestHelpers.makeTestPlaneGeometry(for: datasetA)
        let planeB = MPRTestHelpers.makeTestPlaneGeometry(for: datasetB)

        let firstFrame = try await adapter.makeTextureFrame(
            dataset: datasetA,
            plane: planeA,
            thickness: 3,
            steps: 3,
            blend: .single
        )
        firstFrame.debugReleaseOutputTextureLease()
        let initialIdentity = await adapter.debugCachedDatasetIdentity

        let secondFrame = try await adapter.makeTextureFrame(
            dataset: datasetB,
            plane: planeB,
            thickness: 3,
            steps: 3,
            blend: .single
        )
        defer { secondFrame.debugReleaseOutputTextureLease() }

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 2)
        let updatedIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertEqual(updatedIdentity?.count, initialIdentity?.count)
        XCTAssertEqual(updatedIdentity?.dimensions, initialIdentity?.dimensions)
        XCTAssertNotEqual(updatedIdentity?.pixelFormat, initialIdentity?.pixelFormat)
        XCTAssertEqual(updatedIdentity?.pixelFormat, .int16Signed)
        XCTAssertEqual(updatedIdentity?.contentFingerprint, initialIdentity?.contentFingerprint)
    }

    func test_cacheInvalidatesForExternallyMutatedData() async throws {
        let sharedData = try VolumeDatasetTestFactory.makeSharedTestData(
            pixelFormat: .int16Signed,
            seed: 31
        )
        let dataset = VolumeDatasetTestFactory.makeTestDataset(data: sharedData.data, pixelFormat: .int16Signed)
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        let firstFrame = try await adapter.makeTextureFrame(
            dataset: dataset,
            plane: plane,
            thickness: 3,
            steps: 3,
            blend: .single
        )
        firstFrame.debugReleaseOutputTextureLease()
        let initialIdentity = await adapter.debugCachedDatasetIdentity

        VolumeDatasetTestFactory.mutateSharedTestDataInPlace(sharedData.storage, pixelFormat: dataset.pixelFormat)
        let secondFrame = try await adapter.makeTextureFrame(
            dataset: dataset,
            plane: plane,
            thickness: 3,
            steps: 3,
            blend: .single
        )
        defer { secondFrame.debugReleaseOutputTextureLease() }

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 2)
        let updatedIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertEqual(updatedIdentity?.count, initialIdentity?.count)
        XCTAssertEqual(updatedIdentity?.dimensions, initialIdentity?.dimensions)
        XCTAssertEqual(updatedIdentity?.pixelFormat, initialIdentity?.pixelFormat)
        XCTAssertNotEqual(updatedIdentity?.contentFingerprint, initialIdentity?.contentFingerprint)
    }
}

private actor VolumeTextureUploadTestGate {
    private enum TimeoutError: Error {
        case conditionNotReached
    }

    private var uploadStartCount = 0
    private var requestJoined = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func holdUpload() async {
        uploadStartCount += 1
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func recordJoin() {
        requestJoined = true
    }

    func waitUntilUploadStarts(count: Int = 1) async throws {
        try await waitUntil { uploadStartCount >= count }
    }

    func waitUntilRequestJoins() async throws {
        try await waitUntil { requestJoined }
    }

    func releaseUpload() {
        releaseUploads()
    }

    func releaseUploads() {
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition() {
            guard clock.now < deadline else { throw TimeoutError.conditionNotReached }
            await Task.yield()
        }
    }
}
