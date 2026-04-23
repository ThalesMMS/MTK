import simd
import XCTest

@testable import MTKCore

final class VolumeTransferFunctionDefaultsTests: XCTestCase {
    func test_defaultGrayscale_usesPositiveDatasetRange() {
        assertDefaultGrayscaleMatchesDatasetRange(50...400)
    }

    func test_defaultGrayscale_usesNegativeDatasetRange() {
        assertDefaultGrayscaleMatchesDatasetRange((-1_000)...(-100))
    }

    func test_defaultGrayscale_usesMixedDatasetRange() {
        assertDefaultGrayscaleMatchesDatasetRange((-1_024)...3_071)
    }

    private func assertDefaultGrayscaleMatchesDatasetRange(_ intensityRange: ClosedRange<Int32>,
                                                           file: StaticString = #filePath,
                                                           line: UInt = #line) {
        let dataset = makeDataset(intensityRange: intensityRange)
        let lower = Float(intensityRange.lowerBound)
        let upper = Float(intensityRange.upperBound)
        let transferFunction = VolumeTransferFunction.defaultGrayscale(for: dataset)

        XCTAssertEqual(
            transferFunction.opacityPoints,
            [
                VolumeTransferFunction.OpacityControlPoint(intensity: lower, opacity: 0),
                VolumeTransferFunction.OpacityControlPoint(intensity: upper, opacity: 1)
            ],
            file: file,
            line: line
        )
        XCTAssertEqual(
            transferFunction.colourPoints,
            [
                VolumeTransferFunction.ColourControlPoint(intensity: lower,
                                                          colour: SIMD4<Float>(0, 0, 0, 1)),
                VolumeTransferFunction.ColourControlPoint(intensity: upper,
                                                          colour: SIMD4<Float>(1, 1, 1, 1))
            ],
            file: file,
            line: line
        )
    }

    private func makeDataset(intensityRange: ClosedRange<Int32>) -> VolumeDataset {
        VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 4, height: 4, depth: 4),
            pixelFormat: .int16Signed
        )
        .withIntensityRange(intensityRange)
    }
}

private extension VolumeDataset {
    func withIntensityRange(_ intensityRange: ClosedRange<Int32>) -> VolumeDataset {
        var dataset = self
        dataset.intensityRange = intensityRange
        return dataset
    }
}
