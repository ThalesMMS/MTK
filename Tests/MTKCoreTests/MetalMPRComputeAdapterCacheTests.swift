//
//  MetalMPRComputeAdapterCacheTests.swift
//  MTK
//
//  Unit tests for MetalMPRComputeAdapter texture cache and repeated slab generation.
//
//  Thales Matheus Mendonca Santos - February 2026

import XCTest
import Metal
@_spi(Testing) @testable import MTKCore

final class MetalMPRComputeAdapterCacheTests: MetalMPRComputeAdapterTestCase {

    func test_makeSlabReusesTextureForSameDataset() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        _ = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 5,
            steps: 5,
            blend: .average
        )

        let cachedIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertNotNil(cachedIdentity)
        XCTAssertEqual(cachedIdentity?.count, dataset.data.count)
        XCTAssertEqual(cachedIdentity?.dimensions, dataset.dimensions)
        XCTAssertEqual(cachedIdentity?.pixelFormat, dataset.pixelFormat)

        _ = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 5,
            steps: 5,
            blend: .maximum
        )

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 1)
    }

    func test_cachedTextureReuseAcrossIterations() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(pixelFormat: .int16Signed)
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        for _ in 0..<10 {
            let slice = try await adapter.makeSlab(
                dataset: dataset,
                plane: plane,
                thickness: 5,
                steps: 5,
                blend: .average
            )
            MPRTestHelpers.assertValidSlice(slice, expectedWidth: 64, expectedHeight: 64)
        }

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 1)

        let outputAllocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertEqual(outputAllocationCount, 1)
    }

    func test_makeSlabReusesOutputTextureForSameGeometry() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        for _ in 0..<3 {
            let slice = try await adapter.makeSlab(
                dataset: dataset,
                plane: plane,
                thickness: 5,
                steps: 5,
                blend: .average
            )
            MPRTestHelpers.assertValidSlice(slice, expectedWidth: 64, expectedHeight: 64)
        }

        let allocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertEqual(allocationCount, 1)

        let cachedShape = await adapter.debugCachedOutputTextureShape
        XCTAssertEqual(cachedShape?.width, 64)
        XCTAssertEqual(cachedShape?.height, 64)
        XCTAssertEqual(cachedShape?.pixelFormat, dataset.pixelFormat)
    }

    func test_outputTextureReuseAcrossIterations() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(pixelFormat: .int16Signed)
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        for _ in 0..<10 {
            let slice = try await adapter.makeSlab(
                dataset: dataset,
                plane: plane,
                thickness: 5,
                steps: 5,
                blend: .average
            )
            MPRTestHelpers.assertValidSlice(slice, expectedWidth: 64, expectedHeight: 64)
        }

        let allocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertEqual(allocationCount, 1)
    }

    func test_readbackBufferReuseAcrossIterations() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(pixelFormat: .int16Signed)
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        for _ in 0..<12 {
            let slice = try await adapter.makeSlab(
                dataset: dataset,
                plane: plane,
                thickness: 5,
                steps: 5,
                blend: .average
            )
            MPRTestHelpers.assertValidSlice(slice, expectedWidth: 64, expectedHeight: 64)
        }

        let allocationCount = await adapter.debugReadbackAllocationCount
        XCTAssertEqual(allocationCount, 1)

        let cachedShape = await adapter.debugCachedReadbackShape
        XCTAssertEqual(cachedShape?.width, 64)
        XCTAssertEqual(cachedShape?.height, 64)
        XCTAssertEqual(cachedShape?.bytesPerPixel, dataset.pixelFormat.bytesPerVoxel)
    }

    func test_readbackBufferInvalidatesOnDimensionChange() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 48, height: 32, depth: 24),
            pixelFormat: .int16Signed,
            seed: 5
        )
        let axialPlane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset, axis: .z)
        let sagittalPlane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset, axis: .x)

        let axialSlice = try await adapter.makeSlab(
            dataset: dataset,
            plane: axialPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )
        MPRTestHelpers.assertValidSlice(axialSlice, expectedWidth: 48, expectedHeight: 32)

        let sagittalSlice = try await adapter.makeSlab(
            dataset: dataset,
            plane: sagittalPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )
        MPRTestHelpers.assertValidSlice(sagittalSlice, expectedWidth: 32, expectedHeight: 24)

        let allocationCount = await adapter.debugReadbackAllocationCount
        XCTAssertEqual(allocationCount, 2)

        let cachedShape = await adapter.debugCachedReadbackShape
        XCTAssertEqual(cachedShape?.width, 32)
        XCTAssertEqual(cachedShape?.height, 24)
        XCTAssertEqual(cachedShape?.bytesPerPixel, dataset.pixelFormat.bytesPerVoxel)
    }

    func test_readbackBufferInvalidatesOnPixelFormatChange() async throws {
        let dimensions = VolumeDimensions(width: 64, height: 64, depth: 64)
        let sharedData = try VolumeDatasetTestFactory.makeSharedTestData(
            dimensions: dimensions,
            pixelFormat: .int16Unsigned,
            seed: 11
        )
        let unsignedDataset = VolumeDatasetTestFactory.makeTestDataset(
            data: sharedData.data,
            dimensions: dimensions,
            pixelFormat: .int16Unsigned
        )
        let signedDataset = VolumeDatasetTestFactory.makeTestDataset(
            data: sharedData.data,
            dimensions: dimensions,
            pixelFormat: .int16Signed
        )
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: unsignedDataset)

        _ = try await adapter.makeSlab(
            dataset: unsignedDataset,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        _ = try await adapter.makeSlab(
            dataset: signedDataset,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        let allocationCount = await adapter.debugReadbackAllocationCount
        XCTAssertEqual(allocationCount, 2)

        let cachedShape = await adapter.debugCachedReadbackShape
        XCTAssertEqual(cachedShape?.width, 64)
        XCTAssertEqual(cachedShape?.height, 64)
        XCTAssertEqual(cachedShape?.bytesPerPixel, signedDataset.pixelFormat.bytesPerVoxel)
    }

    func test_returnedSlicePixelsStableAfterSubsequentCalls() async throws {
        let dimensions = VolumeDimensions(width: 32, height: 32, depth: 32)
        let initialDataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: dimensions,
            pixelFormat: .int16Signed,
            seed: 3
        )
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: initialDataset)

        let originalSlice = try await adapter.makeSlab(
            dataset: initialDataset,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )
        let originalPixels = Data(Array(originalSlice.pixels))

        for seed in [41, 79, 127, 191] {
            let overwriteDataset = VolumeDatasetTestFactory.makeTestDataset(
                dimensions: dimensions,
                pixelFormat: .int16Signed,
                seed: seed
            )
            let overwriteSlice = try await adapter.makeSlab(
                dataset: overwriteDataset,
                plane: plane,
                thickness: 1,
                steps: 1,
                blend: .single
            )
            MPRTestHelpers.assertValidSlice(overwriteSlice, expectedWidth: 32, expectedHeight: 32)
        }

        XCTAssertEqual(originalSlice.pixels, originalPixels)

        let allocationCount = await adapter.debugReadbackAllocationCount
        XCTAssertEqual(allocationCount, 1)
    }

    func test_outputTextureReuseAcrossBlendModes() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(pixelFormat: .int16Signed, seed: 7)
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        for blendMode in MPRBlendMode.allCases {
            let thickness = blendMode == .single ? 1 : 5
            let steps = blendMode == .single ? 1 : 5

            let slice = try await adapter.makeSlab(
                dataset: dataset,
                plane: plane,
                thickness: thickness,
                steps: steps,
                blend: blendMode
            )
            MPRTestHelpers.assertValidSlice(slice, expectedWidth: 64, expectedHeight: 64)
        }

        let allocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertEqual(allocationCount, 1)

        let cachedShape = await adapter.debugCachedOutputTextureShape
        XCTAssertEqual(cachedShape?.width, 64)
        XCTAssertEqual(cachedShape?.height, 64)
        XCTAssertEqual(cachedShape?.pixelFormat, dataset.pixelFormat)
    }

    func test_concurrentMakeSlabUsesTemporaryOutputTextureFallback() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 96, height: 96, depth: 96),
            pixelFormat: .int16Signed,
            seed: 29
        )
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        async let firstSlice = adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 16,
            steps: 64,
            blend: .average
        )
        async let secondSlice = adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 16,
            steps: 64,
            blend: .average
        )

        let (first, second) = try await (firstSlice, secondSlice)
        MPRTestHelpers.assertValidSlice(first, expectedWidth: 96, expectedHeight: 96)
        MPRTestHelpers.assertValidSlice(second, expectedWidth: 96, expectedHeight: 96)

        let allocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertEqual(allocationCount, 2)

        let cachedShape = await adapter.debugCachedOutputTextureShape
        XCTAssertEqual(cachedShape?.width, 96)
        XCTAssertEqual(cachedShape?.height, 96)
        XCTAssertEqual(cachedShape?.pixelFormat, dataset.pixelFormat)
    }

    func test_outputTextureInvalidatesOnDimensionChange() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 48, height: 32, depth: 24),
            pixelFormat: .int16Signed,
            seed: 5
        )
        let axialPlane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset, axis: .z)
        let sagittalPlane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset, axis: .x)

        let axialSlice = try await adapter.makeSlab(
            dataset: dataset,
            plane: axialPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )
        MPRTestHelpers.assertValidSlice(axialSlice, expectedWidth: 48, expectedHeight: 32)

        let sagittalSlice = try await adapter.makeSlab(
            dataset: dataset,
            plane: sagittalPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )
        MPRTestHelpers.assertValidSlice(sagittalSlice, expectedWidth: 32, expectedHeight: 24)

        let allocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertEqual(allocationCount, 2)

        let cachedShape = await adapter.debugCachedOutputTextureShape
        XCTAssertEqual(cachedShape?.width, 32)
        XCTAssertEqual(cachedShape?.height, 24)
        XCTAssertEqual(cachedShape?.pixelFormat, dataset.pixelFormat)
    }

    func test_outputTextureShapeUpdatesOnInvalidation() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 48, height: 32, depth: 24),
            pixelFormat: .int16Unsigned,
            seed: 19
        )
        let axialPlane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset, axis: .z)
        let sagittalPlane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset, axis: .x)

        _ = try await adapter.makeSlab(
            dataset: dataset,
            plane: axialPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        let initialShape = await adapter.debugCachedOutputTextureShape
        XCTAssertEqual(initialShape?.width, 48)
        XCTAssertEqual(initialShape?.height, 32)
        XCTAssertEqual(initialShape?.pixelFormat, dataset.pixelFormat)

        _ = try await adapter.makeSlab(
            dataset: dataset,
            plane: sagittalPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        let updatedShape = await adapter.debugCachedOutputTextureShape
        XCTAssertEqual(updatedShape?.width, 32)
        XCTAssertEqual(updatedShape?.height, 24)
        XCTAssertEqual(updatedShape?.pixelFormat, dataset.pixelFormat)
        XCTAssertNotEqual(updatedShape?.width, initialShape?.width)
        XCTAssertNotEqual(updatedShape?.height, initialShape?.height)

        let allocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertEqual(allocationCount, 2)
    }

    func test_outputTextureInvalidatesOnPixelFormatChange() async throws {
        let dimensions = VolumeDimensions(width: 64, height: 64, depth: 64)
        let sharedData = try VolumeDatasetTestFactory.makeSharedTestData(
            dimensions: dimensions,
            pixelFormat: .int16Unsigned,
            seed: 11
        )
        let unsignedDataset = VolumeDatasetTestFactory.makeTestDataset(
            data: sharedData.data,
            dimensions: dimensions,
            pixelFormat: .int16Unsigned
        )
        let signedDataset = VolumeDatasetTestFactory.makeTestDataset(
            data: sharedData.data,
            dimensions: dimensions,
            pixelFormat: .int16Signed
        )
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: unsignedDataset)

        _ = try await adapter.makeSlab(
            dataset: unsignedDataset,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        _ = try await adapter.makeSlab(
            dataset: signedDataset,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        let allocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertEqual(allocationCount, 2)

        let cachedShape = await adapter.debugCachedOutputTextureShape
        XCTAssertEqual(cachedShape?.width, 64)
        XCTAssertEqual(cachedShape?.height, 64)
        XCTAssertEqual(cachedShape?.pixelFormat, .int16Signed)
    }

    func test_makeSlabInvalidatesCacheOnDimensionChange() async throws {
        let dimensionsA = VolumeDimensions(width: 64, height: 64, depth: 64)
        let dimensionsB = VolumeDimensions(width: 32, height: 64, depth: 128)
        let sharedData = try VolumeDatasetTestFactory.makeSharedTestData(
            dimensions: dimensionsA,
            pixelFormat: .int16Unsigned,
            seed: 17
        )
        let datasetA = VolumeDatasetTestFactory.makeTestDataset(
            data: sharedData.data,
            dimensions: dimensionsA,
            pixelFormat: .int16Unsigned
        )
        let datasetB = VolumeDatasetTestFactory.makeTestDataset(
            data: sharedData.data,
            dimensions: dimensionsB,
            pixelFormat: .int16Unsigned
        )
        let planeA = MPRTestHelpers.makeTestPlaneGeometry(for: datasetA)
        let planeB = MPRTestHelpers.makeTestPlaneGeometry(for: datasetB)

        _ = try await adapter.makeSlab(
            dataset: datasetA,
            plane: planeA,
            thickness: 5,
            steps: 5,
            blend: .single
        )

        let initialIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertNotNil(initialIdentity)

        _ = try await adapter.makeSlab(
            dataset: datasetB,
            plane: planeB,
            thickness: 5,
            steps: 5,
            blend: .single
        )

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 2)

        let cachedIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertEqual(cachedIdentity?.count, initialIdentity?.count)
        XCTAssertEqual(cachedIdentity?.dimensions, datasetB.dimensions)
        XCTAssertEqual(cachedIdentity?.pixelFormat, datasetB.pixelFormat)
        XCTAssertNotEqual(cachedIdentity?.dimensions, initialIdentity?.dimensions)
        XCTAssertEqual(cachedIdentity?.pixelFormat, initialIdentity?.pixelFormat)
        XCTAssertEqual(cachedIdentity?.contentFingerprint, initialIdentity?.contentFingerprint)
    }

    func test_makeSlabInvalidatesCacheOnDataChange() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        _ = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 3,
            steps: 3,
            blend: .single
        )

        let initialIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertNotNil(initialIdentity)

        let mutatedDataset = VolumeDatasetTestFactory.makeDataChangedDataset(from: dataset)
        _ = try await adapter.makeSlab(
            dataset: mutatedDataset,
            plane: plane,
            thickness: 3,
            steps: 3,
            blend: .single
        )

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 2)

        let updatedIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertEqual(updatedIdentity?.count, mutatedDataset.data.count)
        XCTAssertEqual(updatedIdentity?.dimensions, mutatedDataset.dimensions)
        XCTAssertEqual(updatedIdentity?.pixelFormat, mutatedDataset.pixelFormat)
        XCTAssertNotEqual(updatedIdentity?.contentFingerprint, initialIdentity?.contentFingerprint)
    }

    func test_makeSlabInvalidatesCacheOnPixelFormatChange() async throws {
        let dimensions = VolumeDimensions(width: 64, height: 64, depth: 64)
        let sharedData = try VolumeDatasetTestFactory.makeSharedTestData(
            dimensions: dimensions,
            pixelFormat: .int16Unsigned,
            seed: 23
        )
        let datasetA = VolumeDatasetTestFactory.makeTestDataset(
            data: sharedData.data,
            dimensions: dimensions,
            pixelFormat: .int16Unsigned
        )
        let datasetB = VolumeDatasetTestFactory.makeTestDataset(
            data: sharedData.data,
            dimensions: dimensions,
            pixelFormat: .int16Signed
        )
        let planeA = MPRTestHelpers.makeTestPlaneGeometry(for: datasetA)
        let planeB = MPRTestHelpers.makeTestPlaneGeometry(for: datasetB)

        _ = try await adapter.makeSlab(
            dataset: datasetA,
            plane: planeA,
            thickness: 3,
            steps: 3,
            blend: .single
        )

        let initialIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertNotNil(initialIdentity)

        _ = try await adapter.makeSlab(
            dataset: datasetB,
            plane: planeB,
            thickness: 3,
            steps: 3,
            blend: .single
        )

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 2)

        let updatedIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertEqual(updatedIdentity?.count, initialIdentity?.count)
        XCTAssertEqual(updatedIdentity?.dimensions, initialIdentity?.dimensions)
        XCTAssertNotEqual(updatedIdentity?.pixelFormat, initialIdentity?.pixelFormat)
        XCTAssertEqual(updatedIdentity?.dimensions, dimensions)
        XCTAssertEqual(updatedIdentity?.pixelFormat, .int16Signed)
        XCTAssertEqual(updatedIdentity?.contentFingerprint, initialIdentity?.contentFingerprint)
    }

    func test_makeSlabInvalidatesCacheOnInPlaceDataMutation() async throws {
        let sharedData = try VolumeDatasetTestFactory.makeSharedTestData(
            pixelFormat: .int16Signed,
            seed: 31
        )
        let dataset = VolumeDatasetTestFactory.makeTestDataset(data: sharedData.data, pixelFormat: .int16Signed)
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        _ = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 3,
            steps: 3,
            blend: .single
        )

        let initialIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertNotNil(initialIdentity)

        VolumeDatasetTestFactory.mutateSharedTestDataInPlace(sharedData.storage, pixelFormat: dataset.pixelFormat)

        _ = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 3,
            steps: 3,
            blend: .single
        )

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 2)

        let updatedIdentity = await adapter.debugCachedDatasetIdentity
        XCTAssertEqual(updatedIdentity?.count, initialIdentity?.count)
        XCTAssertEqual(updatedIdentity?.dimensions, initialIdentity?.dimensions)
        XCTAssertEqual(updatedIdentity?.pixelFormat, initialIdentity?.pixelFormat)
        XCTAssertNotEqual(updatedIdentity?.contentFingerprint, initialIdentity?.contentFingerprint)
    }

    func test_multipleSlabGenerationsSucceed() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        for _ in 0..<3 {
            let slice = try await adapter.makeSlab(
                dataset: dataset,
                plane: plane,
                thickness: 5,
                steps: 5,
                blend: .single
            )
            XCTAssertFalse(slice.pixels.isEmpty)
        }

        let outputAllocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertEqual(outputAllocationCount, 1)
    }

    func test_multipleSlabsWithDifferentBlendModes() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        for blendMode in MPRBlendMode.allCases {
            let slice = try await adapter.makeSlab(
                dataset: dataset,
                plane: plane,
                thickness: 5,
                steps: 5,
                blend: blendMode
            )
            XCTAssertFalse(slice.pixels.isEmpty)
        }

        let outputAllocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertEqual(outputAllocationCount, 1)
    }

    func test_sliceCorrectnessAfterTextureReuse() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 48, height: 32, depth: 24),
            pixelFormat: .int16Signed,
            seed: 3
        )
        let axialPlane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset, axis: .z)
        let sagittalPlane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset, axis: .x)

        let axialSlice = try await adapter.makeSlab(
            dataset: dataset,
            plane: axialPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )
        MPRTestHelpers.assertValidSlice(axialSlice, expectedWidth: 48, expectedHeight: 32)

        let repeatedAxialSlice = try await adapter.makeSlab(
            dataset: dataset,
            plane: axialPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )
        XCTAssertEqual(repeatedAxialSlice.pixels, axialSlice.pixels)
        XCTAssertEqual(repeatedAxialSlice.intensityRange, axialSlice.intensityRange)
        MPRTestHelpers.assertValidSlice(repeatedAxialSlice, expectedWidth: 48, expectedHeight: 32)

        let sagittalSlice = try await adapter.makeSlab(
            dataset: dataset,
            plane: sagittalPlane,
            thickness: 5,
            steps: 5,
            blend: .maximum
        )
        MPRTestHelpers.assertValidSlice(sagittalSlice, expectedWidth: 32, expectedHeight: 24)

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 1)

        let outputAllocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertEqual(outputAllocationCount, 2)
    }

    func test_sliceCorrectnessAcrossBlendModes() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(pixelFormat: .int16Signed, seed: 9)
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        for blendMode in MPRBlendMode.allCases {
            let thickness = blendMode == .single ? 1 : 5
            let steps = blendMode == .single ? 1 : 5

            let slice = try await adapter.makeSlab(
                dataset: dataset,
                plane: plane,
                thickness: thickness,
                steps: steps,
                blend: blendMode
            )

            MPRTestHelpers.assertValidSlice(slice, expectedWidth: 64, expectedHeight: 64)
        }

        let uploadCount = await adapter.debugTextureUploadCount
        XCTAssertEqual(uploadCount, 1)

        let outputAllocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertEqual(outputAllocationCount, 1)
    }

    func test_outputTextureAllocationReductionDemonstrated() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 16, height: 16, depth: 16),
            pixelFormat: .int16Unsigned,
            seed: 13
        )
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)
        var lastSlice: MPRSlice?

        for _ in 0..<100 {
            lastSlice = try await adapter.makeSlab(
                dataset: dataset,
                plane: plane,
                thickness: 3,
                steps: 3,
                blend: .average
            )
        }

        if let lastSlice {
            MPRTestHelpers.assertValidSlice(lastSlice, expectedWidth: 16, expectedHeight: 16)
        } else {
            XCTFail("Expected at least one generated slice")
        }

        let allocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertEqual(allocationCount, 1)
        print("Output texture allocations: \(allocationCount) (vs 100 without caching)")
    }
}