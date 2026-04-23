//
//  MetalMPRComputeAdapterCacheTests.swift
//  MTK
//
//  Unit tests for MetalMPRComputeAdapter output texture cache behaviour using
//  the public texture-native slab API.
//

import XCTest
import Metal
@_spi(Testing) @testable import MTKCore

final class MetalMPRComputeAdapterCacheTests: MetalMPRComputeAdapterTestCase {

    func test_makeSlabTextureReturnsCopyWhenUsingCachedOutputTexture() async throws {
        var values = Array(repeating: Int16(10), count: 4 * 4 * 4)
        values[0] = 1_000
        let dataset = VolumeDataset(
            data: values.withUnsafeBytes { Data($0) },
            dimensions: VolumeDimensions(width: 4, height: 4, depth: 4),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: 10...1_000
        )
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)
        let volumeTexture = try await makeVolumeTexture(for: dataset)

        let first = try await adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )
        let second = try await adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        XCTAssertFalse((first.texture as AnyObject) === (second.texture as AnyObject))
        XCTAssertEqual(second.intensityRange, dataset.intensityRange)
        XCTAssertEqual(try MPRTestHelpers.readInputValues(Int16.self, from: second).count, 16)
        let snapshot = await adapter.debugLastSnapshot
        XCTAssertEqual(snapshot?.intensityRange, second.intensityRange)
    }

    func test_makeSlabTextureReusesOutputTextureAcrossIterations() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(pixelFormat: .int16Signed)
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)
        let volumeTexture = try await makeVolumeTexture(for: dataset)

        for _ in 0..<10 {
            let frame = try await adapter.makeSlabTexture(
                dataset: dataset,
                volumeTexture: volumeTexture,
                plane: plane,
                thickness: 5,
                steps: 5,
                blend: .average
            )
            MPRTestHelpers.assertValidFrame(frame,
                                            expectedWidth: 64,
                                            expectedHeight: 64,
                                            expectedPixelFormat: dataset.pixelFormat)
            XCTAssertEqual(try MPRTestHelpers.readInputValues(Int16.self, from: frame).count, 64 * 64)
        }

        let outputAllocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertGreaterThan(outputAllocationCount, 0)
    }

    func test_outputTextureReuseAcrossBlendModes() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(pixelFormat: .int16Signed, seed: 7)
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)
        let volumeTexture = try await makeVolumeTexture(for: dataset)

        for blendMode in MPRBlendMode.allCases {
            let thickness = blendMode == .single ? 1 : 5
            let steps = blendMode == .single ? 1 : 5
            let frame = try await adapter.makeSlabTexture(
                dataset: dataset,
                volumeTexture: volumeTexture,
                plane: plane,
                thickness: thickness,
                steps: steps,
                blend: blendMode
            )
            MPRTestHelpers.assertValidFrame(frame,
                                            expectedWidth: 64,
                                            expectedHeight: 64,
                                            expectedPixelFormat: dataset.pixelFormat)
            XCTAssertEqual(try MPRTestHelpers.readInputValues(Int16.self, from: frame).count, 64 * 64)
        }

        let outputAllocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertGreaterThan(outputAllocationCount, 0)
        let cachedShape = await adapter.debugCachedOutputTextureShape
        XCTAssertEqual(cachedShape?.width, 64)
        XCTAssertEqual(cachedShape?.height, 64)
        XCTAssertEqual(cachedShape?.pixelFormat, dataset.pixelFormat)
    }

    func test_concurrentMakeSlabTextureUsesTemporaryOutputTextureFallback() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 96, height: 96, depth: 96),
            pixelFormat: .int16Signed,
            seed: 29
        )
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)
        let volumeTexture = try await makeVolumeTexture(for: dataset)

        async let firstFrame = adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: plane,
            thickness: 16,
            steps: 64,
            blend: .average
        )
        async let secondFrame = adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: plane,
            thickness: 16,
            steps: 64,
            blend: .average
        )

        let (first, second) = try await (firstFrame, secondFrame)
        MPRTestHelpers.assertValidFrame(first,
                                        expectedWidth: 96,
                                        expectedHeight: 96,
                                        expectedPixelFormat: dataset.pixelFormat)
        MPRTestHelpers.assertValidFrame(second,
                                        expectedWidth: 96,
                                        expectedHeight: 96,
                                        expectedPixelFormat: dataset.pixelFormat)
        XCTAssertEqual(try MPRTestHelpers.readInputValues(Int16.self, from: first).count, 96 * 96)
        XCTAssertEqual(try MPRTestHelpers.readInputValues(Int16.self, from: second).count, 96 * 96)

        let outputAllocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertGreaterThanOrEqual(outputAllocationCount, 2)
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
        let volumeTexture = try await makeVolumeTexture(for: dataset)

        let axialFrame = try await adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: axialPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )
        let sagittalFrame = try await adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: sagittalPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        MPRTestHelpers.assertValidFrame(axialFrame,
                                        expectedWidth: 48,
                                        expectedHeight: 32,
                                        expectedPixelFormat: dataset.pixelFormat)
        MPRTestHelpers.assertValidFrame(sagittalFrame,
                                        expectedWidth: 32,
                                        expectedHeight: 24,
                                        expectedPixelFormat: dataset.pixelFormat)
        XCTAssertEqual(try MPRTestHelpers.readInputValues(Int16.self, from: axialFrame).count, 48 * 32)
        XCTAssertEqual(try MPRTestHelpers.readInputValues(Int16.self, from: sagittalFrame).count, 32 * 24)

        let outputAllocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertGreaterThanOrEqual(outputAllocationCount, 2)
        let cachedShape = await adapter.debugCachedOutputTextureShape
        XCTAssertEqual(cachedShape?.width, 32)
        XCTAssertEqual(cachedShape?.height, 24)
        XCTAssertEqual(cachedShape?.pixelFormat, dataset.pixelFormat)
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
        let unsignedTexture = try await makeVolumeTexture(for: unsignedDataset)
        let signedTexture = try await makeVolumeTexture(for: signedDataset)

        let unsignedFrame = try await adapter.makeSlabTexture(
            dataset: unsignedDataset,
            volumeTexture: unsignedTexture,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )
        let signedFrame = try await adapter.makeSlabTexture(
            dataset: signedDataset,
            volumeTexture: signedTexture,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        XCTAssertEqual(try MPRTestHelpers.readInputValues(UInt16.self, from: unsignedFrame).count, 64 * 64)
        XCTAssertEqual(try MPRTestHelpers.readInputValues(Int16.self, from: signedFrame).count, 64 * 64)

        let outputAllocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertGreaterThanOrEqual(outputAllocationCount, 2)
        let cachedShape = await adapter.debugCachedOutputTextureShape
        XCTAssertEqual(cachedShape?.width, 64)
        XCTAssertEqual(cachedShape?.height, 64)
        XCTAssertEqual(cachedShape?.pixelFormat, .int16Signed)
    }

    func test_frameCorrectnessAfterTextureReuse() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 48, height: 32, depth: 24),
            pixelFormat: .int16Signed,
            seed: 3
        )
        let axialPlane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset, axis: .z)
        let sagittalPlane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset, axis: .x)
        let volumeTexture = try await makeVolumeTexture(for: dataset)

        let axialFrame = try await adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: axialPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )
        let repeatedAxialFrame = try await adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: axialPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )
        let sagittalFrame = try await adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: sagittalPlane,
            thickness: 5,
            steps: 5,
            blend: .maximum
        )

        let axialPixels = try MPRTestHelpers.readInputValues(Int16.self, from: axialFrame)
        let repeatedAxialPixels = try MPRTestHelpers.readInputValues(Int16.self, from: repeatedAxialFrame)

        MPRTestHelpers.assertValidFrame(axialFrame,
                                        expectedWidth: 48,
                                        expectedHeight: 32,
                                        expectedPixelFormat: dataset.pixelFormat)
        MPRTestHelpers.assertValidFrame(repeatedAxialFrame,
                                        expectedWidth: 48,
                                        expectedHeight: 32,
                                        expectedPixelFormat: dataset.pixelFormat)
        MPRTestHelpers.assertValidFrame(sagittalFrame,
                                        expectedWidth: 32,
                                        expectedHeight: 24,
                                        expectedPixelFormat: dataset.pixelFormat)
        XCTAssertEqual(repeatedAxialPixels, axialPixels)

        let outputAllocationCount = await adapter.debugOutputTextureAllocationCount
        XCTAssertGreaterThanOrEqual(outputAllocationCount, 2)
    }
}
