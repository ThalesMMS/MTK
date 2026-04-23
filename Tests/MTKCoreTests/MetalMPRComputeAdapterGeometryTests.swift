//
//  MetalMPRComputeAdapterGeometryTests.swift
//  MTK
//
//  Unit tests for MetalMPRComputeAdapter geometry-derived texture output.
//

import XCTest
import Metal
@_spi(Testing) @testable import MTKCore

final class MetalMPRComputeAdapterGeometryTests: MetalMPRComputeAdapterTestCase {

    func test_framePreservesPlaneGeometry() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
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

        MPRTestHelpers.assertValidFrame(frame,
                                        expectedWidth: 64,
                                        expectedHeight: 64,
                                        expectedPixelFormat: dataset.pixelFormat)
        XCTAssertEqual(try MPRTestHelpers.readInputValues(UInt16.self, from: frame).count, 64 * 64)
        XCTAssertEqual(frame.planeGeometry, plane)
    }

    func test_dominantAxisDetection() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let volumeTexture = try await makeVolumeTexture(for: dataset)

        let axialPlane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset, axis: .z)
        let axialFrame = try await adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: axialPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )
        XCTAssertEqual(try MPRTestHelpers.readInputValues(UInt16.self, from: axialFrame).count, axialFrame.texture.width * axialFrame.texture.height)
        let axialSnapshot = await adapter.debugLastSnapshot
        XCTAssertEqual(axialSnapshot?.axis, .z)

        let sagittalPlane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset, axis: .x)
        let sagittalFrame = try await adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: sagittalPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )
        XCTAssertEqual(try MPRTestHelpers.readInputValues(UInt16.self, from: sagittalFrame).count, sagittalFrame.texture.width * sagittalFrame.texture.height)
        let sagittalSnapshot = await adapter.debugLastSnapshot
        XCTAssertEqual(sagittalSnapshot?.axis, .x)

        let coronalPlane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset, axis: .y)
        let coronalFrame = try await adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: coronalPlane,
            thickness: 1,
            steps: 1,
            blend: .single
        )
        XCTAssertEqual(try MPRTestHelpers.readInputValues(UInt16.self, from: coronalFrame).count, coronalFrame.texture.width * coronalFrame.texture.height)
        let coronalSnapshot = await adapter.debugLastSnapshot
        XCTAssertEqual(coronalSnapshot?.axis, .y)
    }
}
