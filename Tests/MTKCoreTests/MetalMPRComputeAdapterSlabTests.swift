//
//  MetalMPRComputeAdapterSlabTests.swift
//  MTK
//
//  Unit tests for MetalMPRComputeAdapter initialization and slab generation.
//
//  Thales Matheus Mendonca Santos - February 2026

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

    func test_makeSlabGeneratesValidSlice() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        let slice = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        XCTAssertEqual(slice.width, 64)
        XCTAssertEqual(slice.height, 64)
        XCTAssertEqual(slice.pixelFormat, dataset.pixelFormat)
        XCTAssertFalse(slice.pixels.isEmpty)
        XCTAssertGreaterThan(slice.bytesPerRow, 0)
    }

    func test_makeSlabWithMaximumBlend() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        let slice = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 5,
            steps: 5,
            blend: .maximum
        )

        XCTAssertEqual(slice.width, 64)
        XCTAssertEqual(slice.height, 64)
        XCTAssertFalse(slice.pixels.isEmpty)
    }

    func test_makeSlabWithMinimumBlend() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        let slice = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 5,
            steps: 5,
            blend: .minimum
        )

        XCTAssertEqual(slice.width, 64)
        XCTAssertEqual(slice.height, 64)
        XCTAssertFalse(slice.pixels.isEmpty)
    }

    func test_makeSlabWithAverageBlend() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        let slice = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 10,
            steps: 10,
            blend: .average
        )

        XCTAssertEqual(slice.width, 64)
        XCTAssertEqual(slice.height, 64)
        XCTAssertFalse(slice.pixels.isEmpty)
    }

    func test_makeSlabSanitizesThickness() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        let slice = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: -10,
            steps: 5,
            blend: .single
        )

        XCTAssertFalse(slice.pixels.isEmpty)
        XCTAssertGreaterThan(slice.width, 0)
        XCTAssertGreaterThan(slice.height, 0)
    }

    func test_makeSlabSanitizesSteps() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset()
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        let slice = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 5,
            steps: 0,
            blend: .single
        )

        XCTAssertFalse(slice.pixels.isEmpty)
        XCTAssertGreaterThan(slice.width, 0)
        XCTAssertGreaterThan(slice.height, 0)
    }

    func test_makeSlabWithInt16SignedPixelFormat() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(pixelFormat: .int16Signed)
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        let slice = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        XCTAssertEqual(slice.pixelFormat, .int16Signed)
        XCTAssertFalse(slice.pixels.isEmpty)
    }

    func test_makeSlabWithInt16UnsignedPixelFormat() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(pixelFormat: .int16Unsigned)
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset)

        let slice = try await adapter.makeSlab(
            dataset: dataset,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        XCTAssertEqual(slice.pixelFormat, .int16Unsigned)
        XCTAssertFalse(slice.pixels.isEmpty)
    }
}