//
//  MetalMPRComputeAdapterSlabTests.swift
//  MTK
//
//  Unit tests for MetalMPRComputeAdapter texture-native slab generation.
//

import XCTest
import Metal
#if canImport(MetalPerformanceShaders)
import MetalPerformanceShaders
#endif
@_spi(Testing) @testable import MTKCore

final class MetalMPRComputeAdapterSlabTests: MetalMPRComputeAdapterTestCase {

    func test_adapterInitializesSuccessfully() async {
        XCTAssertNotNil(adapter)
    }

    func test_adapterDetectsMPSAvailability() async {
        let mpsAvailable = await adapter.debugMPSAvailable
        #if canImport(MetalPerformanceShaders)
        XCTAssertEqual(mpsAvailable, MPSSupportsMTLDevice(device))
        #else
        XCTAssertFalse(mpsAvailable)
        #endif
    }

    func test_makeSlabTextureGeneratesValidFrame() async throws {
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
        XCTAssertEqual(frame.intensityRange, dataset.intensityRange)
        XCTAssertEqual(frame.planeGeometry, plane)
    }

    func test_makeSlabTextureSupportsAllBlendModes() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)
        let volumeTexture = try await makeVolumeTexture(for: dataset)

        for blend in [MPRBlendMode.maximum, .minimum, .average] {
            let frame = try await adapter.makeSlabTexture(
                dataset: dataset,
                volumeTexture: volumeTexture,
                plane: plane,
                thickness: 5,
                steps: 5,
                blend: blend
            )

            MPRTestHelpers.assertValidFrame(frame,
                                            expectedWidth: 64,
                                            expectedHeight: 64,
                                            expectedPixelFormat: dataset.pixelFormat)
            XCTAssertEqual(try MPRTestHelpers.readInputValues(UInt16.self, from: frame).count, 64 * 64)
        }
    }

    func test_makeSlabTextureSanitizesThickness() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)
        let volumeTexture = try await makeVolumeTexture(for: dataset)

        let frame = try await adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: plane,
            thickness: -10,
            steps: 5,
            blend: .single
        )

        MPRTestHelpers.assertValidFrame(frame,
                                        expectedWidth: 64,
                                        expectedHeight: 64,
                                        expectedPixelFormat: dataset.pixelFormat)
        XCTAssertEqual(try MPRTestHelpers.readInputValues(UInt16.self, from: frame).count, 64 * 64)
    }

    func test_makeSlabTextureSanitizesSteps() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)
        let volumeTexture = try await makeVolumeTexture(for: dataset)

        let frame = try await adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: plane,
            thickness: 5,
            steps: 0,
            blend: .single
        )

        MPRTestHelpers.assertValidFrame(frame,
                                        expectedWidth: 64,
                                        expectedHeight: 64,
                                        expectedPixelFormat: dataset.pixelFormat)
        XCTAssertEqual(try MPRTestHelpers.readInputValues(UInt16.self, from: frame).count, 64 * 64)
    }

    func test_makeSlabTextureWithInt16SignedPixelFormat() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(pixelFormat: .int16Signed)
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
                                        expectedPixelFormat: .int16Signed)
        XCTAssertEqual(try MPRTestHelpers.readInputValues(Int16.self, from: frame).count, 64 * 64)
        XCTAssertEqual(frame.texture.pixelFormat, .r16Sint)
    }

    func test_makeSlabTextureWithInt16UnsignedPixelFormat() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(pixelFormat: .int16Unsigned)
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
                                        expectedPixelFormat: .int16Unsigned)
        XCTAssertEqual(try MPRTestHelpers.readInputValues(UInt16.self, from: frame).count, 64 * 64)
        XCTAssertEqual(frame.texture.pixelFormat, .r16Uint)
    }
}
