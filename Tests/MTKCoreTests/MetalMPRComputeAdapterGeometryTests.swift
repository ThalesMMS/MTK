//
//  MetalMPRComputeAdapterGeometryTests.swift
//  MTK
//
//  Unit tests for MetalMPRComputeAdapter geometry-derived slab output.
//
//  Thales Matheus Mendonca Santos - February 2026

import XCTest
import Metal
@_spi(Testing) @testable import MTKCore

final class MetalMPRComputeAdapterGeometryTests: MetalMPRComputeAdapterTestCase {

    func test_sliceContainsPixelSpacing() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        let slice = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        MPRTestHelpers.assertValidSlice(slice, expectedWidth: 64, expectedHeight: 64)
        XCTAssertNotNil(slice.pixelSpacing)
        if let spacing = slice.pixelSpacing {
            XCTAssertGreaterThan(spacing.x, 0)
            XCTAssertGreaterThan(spacing.y, 0)
        }
    }

    func test_dominantAxisDetection() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()

        let axialPlane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset, axis: .z)
        _ = try await adapter.makeSlab(
            dataset: dataset,
            plane: axialPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        let axialSnapshot = await adapter.debugLastSnapshot
        XCTAssertEqual(axialSnapshot?.axis, .z)

        let sagittalPlane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset, axis: .x)
        _ = try await adapter.makeSlab(
            dataset: dataset,
            plane: sagittalPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        let sagittalSnapshot = await adapter.debugLastSnapshot
        XCTAssertEqual(sagittalSnapshot?.axis, .x)

        let coronalPlane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset, axis: .y)
        _ = try await adapter.makeSlab(
            dataset: dataset,
            plane: coronalPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        let coronalSnapshot = await adapter.debugLastSnapshot
        XCTAssertEqual(coronalSnapshot?.axis, .y)
    }
}