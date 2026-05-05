import Foundation
import simd
import XCTest

@testable import MTKCore

final class VolumePipelineTests: XCTestCase {
    func testPipelineAppliesFiltersInOrderBeforeMapping() async throws {
        let dataset = makeSignedDataset(values: [1], dimensions: VolumeDimensions(width: 1, height: 1, depth: 1))
        let pipeline = VolumePipeline(
            source: VolumeDatasetSource(dataset),
            filters: [
                AddSignedScalarFilter(amount: 2),
                MultiplySignedScalarFilter(factor: 3)
            ],
            mapper: DefaultVolumeMapper()
        )

        let filtered = try await pipeline.dataset()
        XCTAssertEqual(signedValues(from: filtered), [9])

        let mapped = try await pipeline.mappedVolume()
        XCTAssertEqual(signedValues(from: mapped.dataset), [9])
        XCTAssertEqual(mapped.primaryLayer.id, VolumeRenderRequest.primaryVolumeLayerID)
    }

    func testCropCopiesVoxelOrderShiftsOriginAndPreservesMetadata() async throws {
        let dimensions = VolumeDimensions(width: 3, height: 3, depth: 2)
        let imageData = ImageData3D(
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 2, y: 3, z: 5),
            origin: SIMD3<Float>(10, 20, 30),
            direction: matrix_identity_float3x3,
            pixelFormat: .int16Signed,
            intensityRange: 0...17,
            recommendedWindow: 2...12,
            clinicalMetadata: ClinicalImageMetadata(modality: "CT")
        )
        let dataset = makeSignedDataset(values: Array(Int16(0)...Int16(17)), imageData: imageData)
        let filter = try VolumeCropFilter(inclusiveVoxelMin: SIMD3<Int32>(1, 1, 0),
                                          inclusiveVoxelMax: SIMD3<Int32>(2, 2, 1))

        let cropped = try await filter.apply(to: dataset)

        XCTAssertEqual(cropped.dimensions, VolumeDimensions(width: 2, height: 2, depth: 2))
        XCTAssertEqual(signedValues(from: cropped), [4, 5, 7, 8, 13, 14, 16, 17])
        XCTAssertEqual(cropped.imageData.origin, SIMD3<Float>(12, 23, 30))
        XCTAssertEqual(cropped.spacing, dataset.spacing)
        XCTAssertEqual(cropped.imageData.direction, dataset.imageData.direction)
        XCTAssertEqual(cropped.recommendedWindow, 2...12)
        XCTAssertEqual(cropped.imageData.clinicalMetadata?.modality, "CT")
        XCTAssertEqual(cropped.intensityRange, 4...17)
    }

    func testCropRejectsInvalidAndOutOfRangeBounds() async throws {
        XCTAssertThrowsError(
            try VolumeCropFilter(inclusiveVoxelMin: SIMD3<Int32>(2, 0, 0),
                                 inclusiveVoxelMax: SIMD3<Int32>(1, 0, 0))
        ) { error in
            XCTAssertEqual(error as? VolumePipelineError, .invalidCropBounds)
        }

        let dataset = makeSignedDataset(values: [0, 1], dimensions: VolumeDimensions(width: 2, height: 1, depth: 1))
        let filter = try VolumeCropFilter(inclusiveVoxelMin: .zero,
                                          inclusiveVoxelMax: SIMD3<Int32>(2, 0, 0))
        do {
            _ = try await filter.apply(to: dataset)
            XCTFail("Expected out-of-range crop to throw")
        } catch {
            XCTAssertEqual(error as? VolumePipelineError, .invalidCropBounds)
        }
    }

    func testThresholdSupportsSignedAndUnsignedModes() async throws {
        let signed = makeSignedDataset(values: [-10, 0, 5, 20],
                                       dimensions: VolumeDimensions(width: 4, height: 1, depth: 1))
        let keepInside = VolumeThresholdFilter(range: 0...10, replacementValue: -1)
        let signedOutput = try await keepInside.apply(to: signed)

        XCTAssertEqual(signedValues(from: signedOutput), [-1, 0, 5, -1])
        XCTAssertEqual(signedOutput.intensityRange, -1...5)

        let unsigned = makeUnsignedDataset(values: [1, 5, 9],
                                           dimensions: VolumeDimensions(width: 3, height: 1, depth: 1))
        let keepOutside = VolumeThresholdFilter(range: 2...8,
                                                replacementValue: 0,
                                                mode: .keepOutside)
        let unsignedOutput = try await keepOutside.apply(to: unsigned)

        XCTAssertEqual(unsignedValues(from: unsignedOutput), [1, 0, 9])
        XCTAssertEqual(unsignedOutput.intensityRange, 0...9)
    }

    func testThresholdRejectsReplacementOutsidePixelFormat() async throws {
        let dataset = makeUnsignedDataset(values: [1, 2],
                                          dimensions: VolumeDimensions(width: 2, height: 1, depth: 1))
        let filter = VolumeThresholdFilter(range: 0...1, replacementValue: -1)

        do {
            _ = try await filter.apply(to: dataset)
            XCTFail("Expected unsigned threshold replacement to throw")
        } catch {
            XCTAssertEqual(error as? VolumePipelineError,
                           .scalarValueOutOfRange(value: -1, pixelFormat: .int16Unsigned))
        }
    }

    func testHistogramAnalyzesFilteredPipelineDataset() async throws {
        let dataset = makeSignedDataset(values: [0, 1, 2, 3],
                                        dimensions: VolumeDimensions(width: 4, height: 1, depth: 1))
        let pipeline = VolumePipeline(
            source: VolumeDatasetSource(dataset),
            filters: [
                try VolumeCropFilter(inclusiveVoxelMin: SIMD3<Int32>(1, 0, 0),
                                     inclusiveVoxelMax: SIMD3<Int32>(3, 0, 0)),
                VolumeThresholdFilter(range: 2...3, replacementValue: 0)
            ]
        )

        let histogram = try await pipeline.analyze(
            VolumeHistogramFilter(descriptor: VolumeHistogramDescriptor(binCount: 4,
                                                                        intensityRange: 0...4,
                                                                        normalize: false))
        )

        XCTAssertEqual(histogram.bins, [1, 0, 1, 1])

        let normalized = try await pipeline.analyze(
            VolumeHistogramFilter(descriptor: VolumeHistogramDescriptor(binCount: 4,
                                                                        intensityRange: 0...4,
                                                                        normalize: true))
        )
        XCTAssertEqual(normalized.bins.reduce(0, +), 1, accuracy: 1e-6)
    }

    func testResampleNearestPreservesExtentThroughSpacing() async throws {
        let dataset = makeSignedDataset(values: [10, 20],
                                        dimensions: VolumeDimensions(width: 2, height: 1, depth: 1),
                                        spacing: VolumeSpacing(x: 2, y: 3, z: 4))
        let filter = try VolumeResampleFilter(targetDimensions: VolumeDimensions(width: 4, height: 1, depth: 1),
                                              interpolation: .nearest)

        let output = try await filter.apply(to: dataset)

        XCTAssertEqual(signedValues(from: output), [10, 10, 20, 20])
        XCTAssertEqual(output.spacing, VolumeSpacing(x: 1, y: 3, z: 4))
        XCTAssertEqual(output.intensityRange, 10...20)
    }

    func testResampleTrilinearSamplesCenterAndRejectsInvalidDimensions() async throws {
        let dataset = makeSignedDataset(values: [0, 10, 20, 30],
                                        dimensions: VolumeDimensions(width: 2, height: 2, depth: 1),
                                        spacing: VolumeSpacing(x: 2, y: 3, z: 4))
        let filter = try VolumeResampleFilter(targetDimensions: VolumeDimensions(width: 1, height: 1, depth: 1),
                                              interpolation: .trilinear)

        let output = try await filter.apply(to: dataset)

        XCTAssertEqual(signedValues(from: output), [15])
        XCTAssertEqual(output.spacing, VolumeSpacing(x: 4, y: 6, z: 4))

        XCTAssertThrowsError(
            try VolumeResampleFilter(targetDimensions: VolumeDimensions(width: 0, height: 1, depth: 1))
        ) { error in
            XCTAssertEqual(error as? VolumePipelineError, .invalidDimensions)
        }
    }

    func testGradientHistogramCountsUniformAndSpacingAwareRamps() async throws {
        let uniform = makeSignedDataset(values: Array(repeating: 5, count: 8),
                                        dimensions: VolumeDimensions(width: 2, height: 2, depth: 2))
        let descriptor = VolumeGradientHistogramDescriptor(intensityBinCount: 2,
                                                           gradientBinCount: 2,
                                                           intensityRange: 0...10,
                                                           gradientRange: 0...10)
        let uniformHistogram = try await VolumeGradientHistogramFilter(descriptor: descriptor)
            .analyze(uniform)

        XCTAssertEqual(uniformHistogram.bins[1][0], 8)
        XCTAssertEqual(uniformHistogram.bins.flatMap { $0 }.reduce(0, +), 8)

        let slowRamp = makeSignedDataset(values: [0, 10, 20],
                                         dimensions: VolumeDimensions(width: 3, height: 1, depth: 1),
                                         spacing: VolumeSpacing(x: 2, y: 1, z: 1))
        let fastRamp = makeSignedDataset(values: [0, 10, 20],
                                         dimensions: VolumeDimensions(width: 3, height: 1, depth: 1),
                                         spacing: VolumeSpacing(x: 1, y: 1, z: 1))
        let rampDescriptor = VolumeGradientHistogramDescriptor(intensityBinCount: 2,
                                                               gradientBinCount: 4,
                                                               intensityRange: 0...20,
                                                               gradientRange: 0...8)

        let slowHistogram = try await VolumeGradientHistogramFilter(descriptor: rampDescriptor)
            .analyze(slowRamp)
        let fastHistogram = try await VolumeGradientHistogramFilter(descriptor: rampDescriptor)
            .analyze(fastRamp)

        XCTAssertEqual(gradientTotals(slowHistogram), [0, 0, 3, 0])
        XCTAssertEqual(gradientTotals(fastHistogram), [0, 0, 0, 3])
    }

    func testDefaultMapperProvidesRenderingDefaults() async throws {
        let dataset = makeSignedDataset(values: [0, 10],
                                        dimensions: VolumeDimensions(width: 2, height: 1, depth: 1),
                                        recommendedWindow: 0...10)

        let mapped = try await DefaultVolumeMapper().map(dataset)

        XCTAssertEqual(mapped.dataset, dataset)
        XCTAssertEqual(mapped.recommendedWindow, 0...10)
        XCTAssertEqual(mapped.primaryLayer.id, VolumeRenderRequest.primaryVolumeLayerID)
        XCTAssertEqual(mapped.primaryLayer.scalarVolume?.dataset, dataset)
        XCTAssertEqual(mapped.transferFunction.opacityPoints.first?.intensity, 0)
        XCTAssertEqual(mapped.transferFunction.opacityPoints.last?.intensity, 10)
    }
}

private struct AddSignedScalarFilter: VolumeDatasetFilter {
    let executionPolicy: VolumeFilterExecutionPolicy = .cpu
    var amount: Int16

    func apply(to dataset: VolumeDataset) async throws -> VolumeDataset {
        let values = signedValues(from: dataset).map { $0 + amount }
        var imageData = dataset.imageData
        imageData.intensityRange = intensityRange(values.map(Int32.init))
        return makeSignedDataset(values: values, imageData: imageData)
    }
}

private struct MultiplySignedScalarFilter: VolumeDatasetFilter {
    let executionPolicy: VolumeFilterExecutionPolicy = .cpu
    var factor: Int16

    func apply(to dataset: VolumeDataset) async throws -> VolumeDataset {
        let values = signedValues(from: dataset).map { $0 * factor }
        var imageData = dataset.imageData
        imageData.intensityRange = intensityRange(values.map(Int32.init))
        return makeSignedDataset(values: values, imageData: imageData)
    }
}

private func makeSignedDataset(values: [Int16],
                               dimensions: VolumeDimensions,
                               spacing: VolumeSpacing = VolumeSpacing(x: 1, y: 1, z: 1),
                               recommendedWindow: ClosedRange<Int32>? = nil) -> VolumeDataset {
    let imageData = ImageData3D(dimensions: dimensions,
                                spacing: spacing,
                                origin: .zero,
                                direction: matrix_identity_float3x3,
                                pixelFormat: .int16Signed,
                                intensityRange: intensityRange(values.map(Int32.init)),
                                recommendedWindow: recommendedWindow)
    return makeSignedDataset(values: values, imageData: imageData)
}

private func makeSignedDataset(values: [Int16], imageData: ImageData3D) -> VolumeDataset {
    precondition(values.count == imageData.dimensions.voxelCount)
    return VolumeDataset(data: values.withUnsafeBytes { Data($0) },
                         imageData: imageData)
}

private func makeUnsignedDataset(values: [UInt16],
                                 dimensions: VolumeDimensions) -> VolumeDataset {
    let imageData = ImageData3D(dimensions: dimensions,
                                spacing: VolumeSpacing(x: 1, y: 1, z: 1),
                                origin: .zero,
                                direction: matrix_identity_float3x3,
                                pixelFormat: .int16Unsigned,
                                intensityRange: intensityRange(values.map(Int32.init)))
    return VolumeDataset(data: values.withUnsafeBytes { Data($0) },
                         imageData: imageData)
}

private func signedValues(from dataset: VolumeDataset) -> [Int16] {
    dataset.data.withUnsafeBytes { buffer in
        Array(UnsafeBufferPointer(start: buffer.baseAddress!.assumingMemoryBound(to: Int16.self),
                                  count: dataset.voxelCount))
    }
}

private func unsignedValues(from dataset: VolumeDataset) -> [UInt16] {
    dataset.data.withUnsafeBytes { buffer in
        Array(UnsafeBufferPointer(start: buffer.baseAddress!.assumingMemoryBound(to: UInt16.self),
                                  count: dataset.voxelCount))
    }
}

private func intensityRange(_ values: [Int32]) -> ClosedRange<Int32> {
    values.min()!...values.max()!
}

private func gradientTotals(_ histogram: VolumeGradientHistogram) -> [Float] {
    guard let firstRow = histogram.bins.first else { return [] }
    return firstRow.indices.map { gradientIndex in
        histogram.bins.reduce(0) { total, row in
            total + row[gradientIndex]
        }
    }
}
