import Foundation
import XCTest
@testable import MTKCore

final class AutoWindowLevelCalculatorTests: XCTestCase {
    func test_sliceCalculation_usesOnlyRequestedSlice() throws {
        let firstSlice = (0..<100).map { Int16(-1_000 + $0) }
        let secondSlice = (0..<100).map { Int16(100 + $0) }
        let dataset = makeDataset(values: firstSlice + secondSlice,
                                  width: 10,
                                  height: 10,
                                  depth: 2)

        let first = try XCTUnwrap(AutoWindowLevelCalculator.calculate(dataset: dataset, sliceIndex: 0))
        let second = try XCTUnwrap(AutoWindowLevelCalculator.calculate(dataset: dataset, sliceIndex: 1))

        XCTAssertLessThan(first.upperBound, 0)
        XCTAssertGreaterThanOrEqual(second.lowerBound, 100)
    }

    func test_calculation_ignoresSignedPaddingSentinel() throws {
        let padding = [Int16](repeating: .min, count: 60)
        let anatomy = (0..<40).map(Int16.init)
        let dataset = makeDataset(values: padding + anatomy,
                                  width: 10,
                                  height: 10,
                                  depth: 1)

        let result = try XCTUnwrap(AutoWindowLevelCalculator.calculate(dataset: dataset, sliceIndex: 0))

        XCTAssertGreaterThanOrEqual(result.lowerBound, 0)
        XCTAssertLessThanOrEqual(result.upperBound, 39)
    }

    func test_calculation_preservesAirHeavyCTDistribution() throws {
        let air = [Int16](repeating: -1_000, count: 80)
        let anatomy = (0..<20).map { Int16($0 * 25) }
        let dataset = makeDataset(values: air + anatomy,
                                  width: 10,
                                  height: 10,
                                  depth: 1)

        let result = try XCTUnwrap(AutoWindowLevelCalculator.calculate(dataset: dataset, sliceIndex: 0))

        XCTAssertEqual(result.lowerBound, -1_000)
        XCTAssertGreaterThan(result.upperBound, 0)
    }

    func test_calculation_trimsMRIntensityOutliers() throws {
        let anatomy = (0..<98).map(Int16.init)
        let dataset = makeDataset(values: anatomy + [30_000, 31_000],
                                  width: 10,
                                  height: 10,
                                  depth: 1)

        let result = try XCTUnwrap(AutoWindowLevelCalculator.calculate(dataset: dataset, sliceIndex: 0))

        XCTAssertEqual(result.lowerBound, 1)
        XCTAssertEqual(result.upperBound, 97)
    }

    private func makeDataset(values: [Int16], width: Int, height: Int, depth: Int) -> VolumeDataset {
        VolumeDataset(
            data: values.withUnsafeBytes { Data($0) },
            dimensions: VolumeDimensions(width: width, height: height, depth: depth),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: Int32(values.min() ?? 0)...Int32(values.max() ?? 0)
        )
    }
}
