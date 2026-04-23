//
//  MetalMPRComputeAdapterStateTests.swift
//  MTK
//
//  Unit tests for MetalMPRComputeAdapter command and snapshot state.
//

import XCTest
import Metal
@_spi(Testing) @testable import MTKCore

final class MetalMPRComputeAdapterStateTests: MetalMPRComputeAdapterTestCase {

    func test_sendSetBlendCommandUpdatesOverride() async throws {
        let overridesBefore = await adapter.debugOverrides
        XCTAssertNil(overridesBefore.blend)

        try await adapter.send(.setBlend(.maximum))

        let overridesAfter = await adapter.debugOverrides
        XCTAssertEqual(overridesAfter.blend, .maximum)
    }

    func test_sendSetSlabCommandUpdatesOverrides() async throws {
        let overridesBefore = await adapter.debugOverrides
        XCTAssertNil(overridesBefore.slabThickness)
        XCTAssertNil(overridesBefore.slabSteps)

        try await adapter.send(.setSlab(thickness: 10, steps: 5))

        let overridesAfter = await adapter.debugOverrides
        XCTAssertEqual(overridesAfter.slabThickness, 10)
        XCTAssertEqual(overridesAfter.slabSteps, 5)
    }

    func test_overridesApplyToNextFrame() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)
        let volumeTexture = try await makeVolumeTexture(for: dataset)

        try await adapter.send(.setBlend(.minimum))
        try await adapter.send(.setSlab(thickness: 15, steps: 10))

        let frame = try await adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        MPRTestHelpers.assertValidFrame(frame,
                                        expectedWidth: 64,
                                        expectedHeight: 64,
                                        expectedPixelFormat: dataset.pixelFormat)
        XCTAssertEqual(try MPRTestHelpers.readInputValues(UInt16.self, from: frame).count, 64 * 64)

        let snapshot = await adapter.debugLastSnapshot
        XCTAssertEqual(snapshot?.blend, .minimum)
        XCTAssertEqual(snapshot?.thickness, 15)
        XCTAssertEqual(snapshot?.steps, 10)

        let overridesAfter = await adapter.debugOverrides
        XCTAssertNil(overridesAfter.blend)
        XCTAssertNil(overridesAfter.slabThickness)
        XCTAssertNil(overridesAfter.slabSteps)
    }

    func test_overridesClearedAfterFrameGeneration() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)
        let volumeTexture = try await makeVolumeTexture(for: dataset)

        try await adapter.send(.setBlend(.maximum))
        _ = try await adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        let overridesAfter = await adapter.debugOverrides
        XCTAssertNil(overridesAfter.blend)
    }

    func test_lastSnapshotUpdatedAfterFrameGeneration() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)
        let volumeTexture = try await makeVolumeTexture(for: dataset)

        let snapshotBefore = await adapter.debugLastSnapshot
        XCTAssertNil(snapshotBefore)

        let frame = try await adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: plane,
            thickness: 5,
            steps: 3,
            blend: .average
        )
        XCTAssertEqual(try MPRTestHelpers.readInputValues(UInt16.self, from: frame).count, 64 * 64)

        let snapshot = await adapter.debugLastSnapshot
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.blend, .average)
        XCTAssertEqual(snapshot?.thickness, 5)
        XCTAssertEqual(snapshot?.steps, 3)
        XCTAssertEqual(snapshot?.intensityRange, dataset.intensityRange)
    }

    func test_makeTextureFrameWithSmallDataset() async throws {
        let dimensions = VolumeDimensions(width: 2, height: 2, depth: 2)
        let values: [UInt16] = Array(repeating: 1000, count: dimensions.voxelCount)
        let data = values.withUnsafeBytes { Data($0) }
        let dataset = VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned
        )

        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)
        let volumeTexture = try await makeVolumeTexture(for: dataset)
        let frame = try await adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        XCTAssertGreaterThan(frame.texture.width, 0)
        XCTAssertGreaterThan(frame.texture.height, 0)
        XCTAssertEqual(try MPRTestHelpers.readInputValues(UInt16.self, from: frame).count, frame.texture.width * frame.texture.height)
        XCTAssertEqual(frame.intensityRange, dataset.intensityRange)
    }

    func test_makeSlabTextureWithLargeThickness() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)
        let volumeTexture = try await makeVolumeTexture(for: dataset)

        let frame = try await adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: plane,
            thickness: 100,
            steps: 50,
            blend: .maximum
        )

        MPRTestHelpers.assertValidFrame(frame,
                                        expectedWidth: 64,
                                        expectedHeight: 64,
                                        expectedPixelFormat: dataset.pixelFormat)
        XCTAssertEqual(try MPRTestHelpers.readInputValues(UInt16.self, from: frame).count, 64 * 64)
    }
}
