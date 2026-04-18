//
//  MetalVolumeRenderingAdapterTexturePreparationTests.swift
//  MTK
//
//  Unit tests for MetalVolumeRenderingAdapter transfer-function preparation.
//

import CoreGraphics
import Foundation
import Metal
import simd
import XCTest

@_spi(Testing) @testable import MTKCore

// MARK: - File-level helpers

private func makeValidTransferFunction() -> VolumeTransferFunction {
    VolumeTransferFunction(
        opacityPoints: [
            VolumeTransferFunction.OpacityControlPoint(intensity: 0, opacity: 0),
            VolumeTransferFunction.OpacityControlPoint(intensity: 4095, opacity: 1),
        ],
        colourPoints: [
            VolumeTransferFunction.ColourControlPoint(intensity: 0, colour: SIMD4<Float>(0, 0, 0, 1)),
            VolumeTransferFunction.ColourControlPoint(intensity: 4095, colour: SIMD4<Float>(1, 1, 1, 1)),
        ]
    )
}

// MARK: - sanitizeColourPoints / sanitizeAlphaPoints (MetalVolumeRenderingAdapter+TexturePreparation.swift)

final class SanitizeTransferFunctionPointsTests: XCTestCase {
    private var adapter: MetalVolumeRenderingAdapter!

    override func setUpWithError() throws {
        try super.setUpWithError()
        adapter = try makeTestAdapter()
    }

    func testSanitizeColourPointsThrowsForEmptyInput() async {
        await XCTAssertThrowsAsync(
            try await adapter.sanitizeColourPointsForTesting([]),
            expecting: MetalVolumeRenderingAdapter.AdapterError.emptyColorPoints
        )
    }

    func testSanitizeColourPointsConvertsValuesCorrectly() async throws {
        let input = [
            VolumeTransferFunction.ColourControlPoint(
                intensity: 0.5,
                colour: SIMD4<Float>(0.1, 0.2, 0.3, 0.4)
            )
        ]
        let output = try await adapter.sanitizeColourPointsForTesting(input)
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output[0].dataValue, 0.5, accuracy: 1e-6)
        XCTAssertEqual(output[0].colourValue.r, 0.1, accuracy: 1e-6)
        XCTAssertEqual(output[0].colourValue.g, 0.2, accuracy: 1e-6)
        XCTAssertEqual(output[0].colourValue.b, 0.3, accuracy: 1e-6)
        XCTAssertEqual(output[0].colourValue.a, 0.4, accuracy: 1e-6)
    }

    func testSanitizeColourPointsPreservesMultiplePoints() async throws {
        let input = [
            VolumeTransferFunction.ColourControlPoint(
                intensity: 0,
                colour: SIMD4<Float>(0, 0, 0, 1)
            ),
            VolumeTransferFunction.ColourControlPoint(
                intensity: 4095,
                colour: SIMD4<Float>(1, 1, 1, 1)
            )
        ]
        let output = try await adapter.sanitizeColourPointsForTesting(input)
        XCTAssertEqual(output.count, 2)
        XCTAssertEqual(output[0].dataValue, 0, accuracy: 1e-6)
        XCTAssertEqual(output[1].dataValue, 4095, accuracy: 1e-6)
    }

    func testSanitizeAlphaPointsThrowsForEmptyInput() async {
        await XCTAssertThrowsAsync(
            try await adapter.sanitizeAlphaPointsForTesting([]),
            expecting: MetalVolumeRenderingAdapter.AdapterError.emptyAlphaPoints
        )
    }

    func testSanitizeAlphaPointsConvertsValuesCorrectly() async throws {
        let input = [
            VolumeTransferFunction.OpacityControlPoint(intensity: 1024, opacity: 0.75)
        ]
        let output = try await adapter.sanitizeAlphaPointsForTesting(input)
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output[0].dataValue, 1024, accuracy: 1e-6)
        XCTAssertEqual(output[0].alphaValue, 0.75, accuracy: 1e-6)
    }

    func testSanitizeAlphaPointsPreservesMultiplePoints() async throws {
        let input = [
            VolumeTransferFunction.OpacityControlPoint(intensity: 0, opacity: 0),
            VolumeTransferFunction.OpacityControlPoint(intensity: 2048, opacity: 0.5),
            VolumeTransferFunction.OpacityControlPoint(intensity: 4095, opacity: 1.0),
        ]
        let output = try await adapter.sanitizeAlphaPointsForTesting(input)
        XCTAssertEqual(output.count, 3)
        XCTAssertEqual(output[1].dataValue, 2048, accuracy: 1e-6)
        XCTAssertEqual(output[1].alphaValue, 0.5, accuracy: 1e-6)
    }

}

extension MetalVolumeRenderingAdapter {
    fileprivate func sanitizeColourPointsForTesting(
        _ points: [VolumeTransferFunction.ColourControlPoint]
    ) throws -> [TransferFunction.ColorPoint] {
        try sanitizeColourPoints(points)
    }

    fileprivate func sanitizeAlphaPointsForTesting(
        _ points: [VolumeTransferFunction.OpacityControlPoint]
    ) throws -> [TransferFunction.AlphaPoint] {
        try sanitizeAlphaPoints(points)
    }
}

// MARK: - makeTransferFunction (MetalVolumeRenderingAdapter+TexturePreparation.swift)

final class MakeTransferFunctionTests: XCTestCase {
    private var adapter: MetalVolumeRenderingAdapter!

    override func setUpWithError() throws {
        try super.setUpWithError()
        adapter = try makeTestAdapter()
    }

    func testMakeTransferFunctionSetsIntensityRangeFromDataset() async throws {
        let dataset = makeDataset(intensityMin: -1024, intensityMax: 3071)
        let transfer = makeValidTransferFunction()
        let tf = try await adapter.makeTransferFunctionForTesting(from: transfer, dataset: dataset)
        XCTAssertEqual(tf.minimumValue, -1024, accuracy: 1, "minimumValue should come from dataset intensityRange")
        XCTAssertEqual(tf.maximumValue, 3071, accuracy: 1, "maximumValue should come from dataset intensityRange")
    }

    func testMakeTransferFunctionSetsShiftToZero() async throws {
        let dataset = makeDataset(intensityMin: 0, intensityMax: 4095)
        let transfer = makeValidTransferFunction()
        let tf = try await adapter.makeTransferFunctionForTesting(from: transfer, dataset: dataset)
        XCTAssertEqual(tf.shift, 0, accuracy: 1e-6, "shift should always be 0")
    }

    func testMakeTransferFunctionThrowsForEmptyColourPoints() async {
        let dataset = makeDataset(intensityMin: 0, intensityMax: 4095)
        let emptyColorTransfer = VolumeTransferFunction(
            opacityPoints: [VolumeTransferFunction.OpacityControlPoint(intensity: 0, opacity: 1)],
            colourPoints: []
        )
        await XCTAssertThrowsAsync(
            try await adapter.makeTransferFunctionForTesting(from: emptyColorTransfer, dataset: dataset),
            expecting: MetalVolumeRenderingAdapter.AdapterError.emptyColorPoints
        )
    }

    func testMakeTransferFunctionThrowsForEmptyAlphaPoints() async {
        let dataset = makeDataset(intensityMin: 0, intensityMax: 4095)
        let emptyAlphaTransfer = VolumeTransferFunction(
            opacityPoints: [],
            colourPoints: [VolumeTransferFunction.ColourControlPoint(intensity: 0, colour: SIMD4<Float>(repeating: 1))]
        )
        await XCTAssertThrowsAsync(
            try await adapter.makeTransferFunctionForTesting(from: emptyAlphaTransfer, dataset: dataset),
            expecting: MetalVolumeRenderingAdapter.AdapterError.emptyAlphaPoints
        )
    }

    func testMakeTransferFunctionSetsLinearColorSpace() async throws {
        let dataset = makeDataset(intensityMin: 0, intensityMax: 4095)
        let transfer = makeValidTransferFunction()
        let tf = try await adapter.makeTransferFunctionForTesting(from: transfer, dataset: dataset)
        XCTAssertEqual(tf.colorSpace, .linear, "colorSpace should always be .linear")
    }

    private func makeDataset(intensityMin: Int32, intensityMax: Int32) -> VolumeDataset {
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        let values: [UInt16] = Array(repeating: 1000, count: dimensions.voxelCount)
        let data = values.withUnsafeBytes { Data($0) }
        return VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned,
            intensityRange: intensityMin...intensityMax,
            recommendedWindow: intensityMin...intensityMax
        )
    }

}

extension MetalVolumeRenderingAdapter {
    fileprivate func makeTransferFunctionForTesting(
        from transfer: VolumeTransferFunction,
        dataset: VolumeDataset
    ) throws -> TransferFunction {
        try makeTransferFunction(from: transfer, dataset: dataset)
    }
}

// MARK: - TransferCache intensityRange cache invalidation (new behavior in PR)

final class TransferCacheIntensityRangeTests: XCTestCase {
    /// Regression test: ensure transfer texture is regenerated when the dataset's
    /// intensityRange changes even if the transfer function object is the same.
    /// This covers the new `intensityRange` field added to TransferCache in this PR.
    func testRenderProducesResultWithSameTransferFunctionButDifferentIntensityRange() async throws {
        let adapter = try makeTestAdapter()
        let transfer = makeValidTransferFunction()

        let dataset1 = makeDataset(pixelFormat: .int16Unsigned,
                                   voxelValue: 1_000,
                                   recommendedWindow: -1024...3071)
        let dataset2 = makeDataset(pixelFormat: .int16Signed,
                                   voxelValue: 500,
                                   recommendedWindow: -1024...3071)
        XCTAssertNotEqual(dataset1.intensityRange, dataset2.intensityRange)

        let request1 = makeRenderRequest(dataset: dataset1, transfer: transfer)
        let result1 = try await adapter.renderImage(using: request1)
        let transferTexture1 = await adapter.debugTransferCacheTexture
        let unwrappedTransferTexture1 = try XCTUnwrap(transferTexture1)
        XCTAssertNotNil(result1.cgImage, "First render should produce an image")

        let request2 = makeRenderRequest(dataset: dataset2, transfer: transfer)
        let result2 = try await adapter.renderImage(using: request2)
        let transferTexture2 = await adapter.debugTransferCacheTexture
        let unwrappedTransferTexture2 = try XCTUnwrap(transferTexture2)
        XCTAssertNotNil(result2.cgImage, "Second render with different intensityRange should produce an image")

        XCTAssertNotEqual(ObjectIdentifier(unwrappedTransferTexture1),
                          ObjectIdentifier(unwrappedTransferTexture2),
                          "Different intensity ranges with the same transfer function should regenerate the transfer texture")
    }

    private func makeDataset(pixelFormat: VolumePixelFormat,
                             voxelValue: Int32,
                             recommendedWindow: ClosedRange<Int32>) -> VolumeDataset {
        let dimensions = VolumeDimensions(width: 8, height: 8, depth: 8)
        let data: Data
        switch pixelFormat {
        case .int16Signed:
            let values: [Int16] = Array(repeating: Int16(clamping: voxelValue), count: dimensions.voxelCount)
            data = values.withUnsafeBytes { Data($0) }
        case .int16Unsigned:
            let values: [UInt16] = Array(repeating: UInt16(clamping: voxelValue), count: dimensions.voxelCount)
            data = values.withUnsafeBytes { Data($0) }
        }
        return VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: pixelFormat,
            recommendedWindow: recommendedWindow
        )
    }

    private func makeRenderRequest(dataset: VolumeDataset,
                                   transfer: VolumeTransferFunction) -> VolumeRenderRequest {
        VolumeRenderRequest(
            dataset: dataset,
            transferFunction: transfer,
            viewportSize: CGSize(width: 64, height: 64),
            camera: VolumeRenderRequest.Camera(
                position: SIMD3<Float>(0, 0, 3),
                target: SIMD3<Float>(0, 0, 0),
                up: SIMD3<Float>(0, 1, 0),
                fieldOfView: 45
            ),
            samplingDistance: 1.0 / 64.0,
            compositing: .frontToBack,
            quality: .interactive
        )
    }

}
