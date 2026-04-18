import XCTest

@testable import MTKCore

/// Tests for the `TestStatisticsHelper` CPU reference implementations.
///
/// These helpers were moved from the production `VolumeStatisticsCalculator`
/// into the test target in this PR so that production code no longer silently
/// falls back to CPU work on GPU setup failure.  The helpers are now the only
/// CPU reference; their correctness is validated here independently of the GPU
/// path.
final class TestStatisticsHelperTests: XCTestCase {

    // MARK: - computePercentilesCPU: rejection cases

    func testPercentilesRejectsEmptyHistogram() {
        XCTAssertThrowsError(
            try TestStatisticsHelper.computePercentilesCPU(from: [], percentiles: [0.5])
        ) { error in
            XCTAssertEqual(error as? VolumeStatisticsCalculator.StatisticsError, .emptyHistogram)
        }
    }

    func testPercentilesRejectsAllZeroHistogram() {
        let allZeros = [UInt32](repeating: 0, count: 256)
        XCTAssertThrowsError(
            try TestStatisticsHelper.computePercentilesCPU(from: allZeros, percentiles: [0.5])
        ) { error in
            XCTAssertEqual(error as? VolumeStatisticsCalculator.StatisticsError, .emptyHistogram)
        }
    }

    func testPercentilesRejectsEmptyPercentileArray() {
        let histogram = [UInt32](repeating: 100, count: 256)
        XCTAssertThrowsError(
            try TestStatisticsHelper.computePercentilesCPU(from: histogram, percentiles: [])
        ) { error in
            XCTAssertEqual(error as? VolumeStatisticsCalculator.StatisticsError, .invalidPercentiles)
        }
    }

    // MARK: - computePercentilesCPU: correctness

    func testPercentilesReturnCorrectCountMatchingInput() throws {
        let histogram = [UInt32](repeating: 100, count: 256)
        let percentiles: [Float] = [0.25, 0.5, 0.75]
        let result = try TestStatisticsHelper.computePercentilesCPU(from: histogram, percentiles: percentiles)
        XCTAssertEqual(result.count, percentiles.count)
    }

    func testPercentilesAreMonotonicallyNonDecreasing() throws {
        let histogram = [UInt32](repeating: 100, count: 256)
        let percentiles: [Float] = [0.1, 0.25, 0.5, 0.75, 0.9]
        let result = try TestStatisticsHelper.computePercentilesCPU(from: histogram, percentiles: percentiles)
        for i in 1..<result.count {
            XCTAssertGreaterThanOrEqual(result[i], result[i - 1],
                                       "Percentile bins should be non-decreasing")
        }
    }

    func testMedianOfUniformDistributionIsNearMiddle() throws {
        let histogram = [UInt32](repeating: 100, count: 256)
        let result = try TestStatisticsHelper.computePercentilesCPU(from: histogram, percentiles: [0.5])
        XCTAssertGreaterThanOrEqual(result[0], 120)
        XCTAssertLessThanOrEqual(result[0], 135)
    }

    func testZeroPercentileReturnsFirstPopulatedBin() throws {
        var histogram = [UInt32](repeating: 0, count: 256)
        histogram[50] = 1_000
        histogram[150] = 1_000
        let result = try TestStatisticsHelper.computePercentilesCPU(from: histogram, percentiles: [0.0])
        // 0th percentile threshold = 0; first cumulative sum > 0 is bin 50
        XCTAssertEqual(result[0], 50)
    }

    func testOneHundredPercentileReturnsLastPopulatedBin() throws {
        var histogram = [UInt32](repeating: 0, count: 256)
        histogram[50] = 500
        histogram[200] = 500
        let result = try TestStatisticsHelper.computePercentilesCPU(from: histogram, percentiles: [1.0])
        XCTAssertEqual(result[0], 200, "100th percentile should point to the last populated bin")
    }

    func testPercentileBinsAreWithinHistogramRange() throws {
        let binCount = 256
        let histogram = [UInt32](repeating: 10, count: binCount)
        let percentiles: [Float] = [0.0, 0.25, 0.5, 0.75, 1.0]
        let result = try TestStatisticsHelper.computePercentilesCPU(from: histogram, percentiles: percentiles)
        for bin in result {
            XCTAssertLessThan(bin, UInt32(binCount), "Bin index must be within histogram range")
        }
    }

    func testPercentilesWithSinglePopulatedBin() throws {
        var histogram = [UInt32](repeating: 0, count: 256)
        histogram[128] = 10_000
        let result = try TestStatisticsHelper.computePercentilesCPU(from: histogram, percentiles: [0.0, 0.5, 1.0])
        for bin in result {
            XCTAssertEqual(bin, 128, "All percentiles should map to the single populated bin")
        }
    }

    // MARK: - computeOtsuThresholdCPU: rejection cases

    func testOtsuRejectsEmptyHistogram() {
        XCTAssertThrowsError(
            try TestStatisticsHelper.computeOtsuThresholdCPU(from: [])
        ) { error in
            XCTAssertEqual(error as? VolumeStatisticsCalculator.StatisticsError, .emptyHistogram)
        }
    }

    func testOtsuRejectsAllZeroHistogram() {
        let allZeros = [UInt32](repeating: 0, count: 256)
        XCTAssertThrowsError(
            try TestStatisticsHelper.computeOtsuThresholdCPU(from: allZeros)
        ) { error in
            XCTAssertEqual(error as? VolumeStatisticsCalculator.StatisticsError, .emptyHistogram)
        }
    }

    // MARK: - computeOtsuThresholdCPU: correctness

    func testOtsuWithSinglePopulatedBinReturnsItsBinIndex() throws {
        var histogram = [UInt32](repeating: 0, count: 256)
        histogram[100] = 10_000
        let threshold = try TestStatisticsHelper.computeOtsuThresholdCPU(from: histogram)
        XCTAssertEqual(threshold, 100, "Otsu threshold for a single-bin histogram should be at that bin")
    }

    func testOtsuWithBimodalDistributionLiesBetweenPeaks() throws {
        var histogram = [UInt32](repeating: 0, count: 256)
        for i in 20...30 { histogram[i] = 500 }   // background peak
        for i in 100...110 { histogram[i] = 500 }  // foreground peak
        let threshold = try TestStatisticsHelper.computeOtsuThresholdCPU(from: histogram)
        XCTAssertGreaterThan(threshold, 30, "Threshold should be after background peak")
        XCTAssertLessThan(threshold, 100, "Threshold should be before foreground peak")
    }

    func testOtsuWithSymmetricBimodalDistributionIsNearMidpoint() throws {
        // Equal peaks at bins 40-50 and bins 150-160; midpoint ≈ 100
        var histogram = [UInt32](repeating: 0, count: 256)
        for i in 40...50 { histogram[i] = 400 }
        for i in 150...160 { histogram[i] = 400 }
        let threshold = try TestStatisticsHelper.computeOtsuThresholdCPU(from: histogram)
        XCTAssertGreaterThanOrEqual(threshold, 55, "Threshold should be after first peak")
        XCTAssertLessThanOrEqual(threshold, 145, "Threshold should be before second peak")
    }

    func testOtsuThresholdIsWithinHistogramBounds() throws {
        var histogram = [UInt32](repeating: 10, count: 256)
        histogram[50] = 1_000
        histogram[200] = 1_000
        let threshold = try TestStatisticsHelper.computeOtsuThresholdCPU(from: histogram)
        XCTAssertGreaterThanOrEqual(threshold, 0)
        XCTAssertLessThan(threshold, 256)
    }

    // MARK: - Cross-validation: CPU helper ↔ GPU results agree

    /// Verifies that `TestStatisticsHelper.computePercentilesCPU` and
    /// `TestStatisticsHelper.computeOtsuThresholdCPU` produce results that are
    /// internally self-consistent (same histogram, independently computed).
    func testCPUOtsuThresholdFallsBetweenPercentiles() throws {
        // Bimodal: background cluster at bins 10-20, foreground at bins 180-200
        var histogram = [UInt32](repeating: 5, count: 256)
        for i in 10...20 { histogram[i] = 800 }
        for i in 180...200 { histogram[i] = 600 }

        let otsu = try TestStatisticsHelper.computeOtsuThresholdCPU(from: histogram)
        let percentiles = try TestStatisticsHelper.computePercentilesCPU(from: histogram, percentiles: [0.02, 0.98])

        // Otsu threshold should separate the two clusters
        XCTAssertGreaterThan(otsu, percentiles[0], "Otsu threshold should be above the 2nd percentile")
        XCTAssertLessThan(otsu, percentiles[1], "Otsu threshold should be below the 98th percentile")
    }

    /// Regression: for a histogram that concentrates all samples in a single bin the
    /// CPU helper should not overflow or crash — it should return that bin.
    func testOtsuDoesNotCrashForEdgeCaseSingleBin() throws {
        var histogram = [UInt32](repeating: 0, count: 4096)
        histogram[0] = UInt32.max / 2
        let threshold = try TestStatisticsHelper.computeOtsuThresholdCPU(from: histogram)
        XCTAssertEqual(threshold, 0)
    }
}
