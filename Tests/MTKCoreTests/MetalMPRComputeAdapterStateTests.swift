//
//  MetalMPRComputeAdapterStateTests.swift
//  MTK
//
//  Unit tests for MetalMPRComputeAdapter command and snapshot state.
//
//  Thales Matheus Mendonca Santos - February 2026

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

    func test_overridesApplyToNextSlab() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        try await adapter.send(.setBlend(.minimum))
        try await adapter.send(.setSlab(thickness: 15, steps: 10))

        let slice = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        XCTAssertFalse(slice.pixels.isEmpty)

        let snapshot = await adapter.debugLastSnapshot
        XCTAssertEqual(snapshot?.blend, .minimum)
        XCTAssertEqual(snapshot?.thickness, 15)
        XCTAssertEqual(snapshot?.steps, 10)

        let overridesAfter = await adapter.debugOverrides
        XCTAssertNil(overridesAfter.blend)
        XCTAssertNil(overridesAfter.slabThickness)
        XCTAssertNil(overridesAfter.slabSteps)
    }

    func test_overridesClearedAfterSlabGeneration() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        try await adapter.send(.setBlend(.maximum))

        _ = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        let overridesAfter = await adapter.debugOverrides
        XCTAssertNil(overridesAfter.blend)
    }

    func test_lastSnapshotUpdatedAfterSlabGeneration() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        let snapshotBefore = await adapter.debugLastSnapshot
        XCTAssertNil(snapshotBefore)

        _ = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 5,
            steps: 3,
            blend: .average
        )

        let snapshotAfter = await adapter.debugLastSnapshot
        XCTAssertNotNil(snapshotAfter)
        XCTAssertEqual(snapshotAfter?.blend, .average)
        XCTAssertEqual(snapshotAfter?.thickness, 5)
        XCTAssertEqual(snapshotAfter?.steps, 3)
    }

    func test_snapshotCapturesIntensityRange() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        _ = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        let snapshot = await adapter.debugLastSnapshot
        XCTAssertNotNil(snapshot?.intensityRange)
    }

    func test_makeSlabWithSmallDataset() async throws {
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

        let slice = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        XCTAssertGreaterThan(slice.width, 0)
        XCTAssertGreaterThan(slice.height, 0)
        XCTAssertFalse(slice.pixels.isEmpty)
    }

    func test_makeSlabWithLargeThickness() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        let slice = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 100,
            steps: 50,
            blend: .maximum
        )

        XCTAssertFalse(slice.pixels.isEmpty)
    }
}
