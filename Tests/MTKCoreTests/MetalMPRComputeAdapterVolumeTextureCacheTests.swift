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

        _ = try await adapter.makeTextureFrame(dataset: dataset, plane: plane, thickness: 5, steps: 5, blend: .average)

        let cachedIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertNotNil(cachedIdentity)
        XCTAssertEqual(cachedIdentity?.count, dataset.data.count)
        XCTAssertEqual(cachedIdentity?.dimensions, dataset.dimensions)
        XCTAssertEqual(cachedIdentity?.pixelFormat, dataset.pixelFormat)

        _ = try await adapter.makeTextureFrame(dataset: dataset, plane: plane, thickness: 5, steps: 5, blend: .maximum)

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 1)
    }

    func test_makeTextureFrameReusesInternalTexturesAcrossIterations() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(pixelFormat: .int16Signed)
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        for _ in 0..<10 {
            let frame = try await adapter.makeTextureFrame(dataset: dataset, plane: plane, thickness: 5, steps: 5, blend: .average)
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

        _ = try await adapter.makeTextureFrame(dataset: datasetA, plane: planeA, thickness: 5, steps: 5, blend: .single)
        let initialIdentity = await adapter.debugCachedDatasetIdentity

        _ = try await adapter.makeTextureFrame(dataset: datasetB, plane: planeB, thickness: 5, steps: 5, blend: .single)

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

        _ = try await adapter.makeTextureFrame(dataset: dataset, plane: plane, thickness: 3, steps: 3, blend: .single)
        let initialIdentity = await adapter.debugCachedDatasetIdentity

        let mutatedDataset = VolumeDatasetTestFactory.makeDataChangedDataset(from: dataset)
        _ = try await adapter.makeTextureFrame(dataset: mutatedDataset, plane: plane, thickness: 3, steps: 3, blend: .single)

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 2)
        let updatedIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertEqual(updatedIdentity?.count, mutatedDataset.data.count)
        XCTAssertEqual(updatedIdentity?.dimensions, mutatedDataset.dimensions)
        XCTAssertEqual(updatedIdentity?.pixelFormat, mutatedDataset.pixelFormat)
        XCTAssertNotEqual(updatedIdentity?.contentFingerprint, initialIdentity?.contentFingerprint)
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

        _ = try await adapter.makeTextureFrame(dataset: datasetA, plane: planeA, thickness: 3, steps: 3, blend: .single)
        let initialIdentity = await adapter.debugCachedDatasetIdentity

        _ = try await adapter.makeTextureFrame(dataset: datasetB, plane: planeB, thickness: 3, steps: 3, blend: .single)

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 2)
        let updatedIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertEqual(updatedIdentity?.count, initialIdentity?.count)
        XCTAssertEqual(updatedIdentity?.dimensions, initialIdentity?.dimensions)
        XCTAssertNotEqual(updatedIdentity?.pixelFormat, initialIdentity?.pixelFormat)
        XCTAssertEqual(updatedIdentity?.pixelFormat, .int16Signed)
        XCTAssertEqual(updatedIdentity?.contentFingerprint, initialIdentity?.contentFingerprint)
    }

    func test_cacheInvalidatesOnInPlaceDataMutation() async throws {
        let sharedData = try VolumeDatasetTestFactory.makeSharedTestData(
            pixelFormat: .int16Signed,
            seed: 31
        )
        let dataset = VolumeDatasetTestFactory.makeTestDataset(data: sharedData.data, pixelFormat: .int16Signed)
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        _ = try await adapter.makeTextureFrame(dataset: dataset, plane: plane, thickness: 3, steps: 3, blend: .single)
        let initialIdentity = await adapter.debugCachedDatasetIdentity

        VolumeDatasetTestFactory.mutateSharedTestDataInPlace(sharedData.storage, pixelFormat: dataset.pixelFormat)
        _ = try await adapter.makeTextureFrame(dataset: dataset, plane: plane, thickness: 3, steps: 3, blend: .single)

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 2)
        let updatedIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertEqual(updatedIdentity?.count, initialIdentity?.count)
        XCTAssertEqual(updatedIdentity?.dimensions, initialIdentity?.dimensions)
        XCTAssertEqual(updatedIdentity?.pixelFormat, initialIdentity?.pixelFormat)
        XCTAssertNotEqual(updatedIdentity?.contentFingerprint, initialIdentity?.contentFingerprint)
    }
}
