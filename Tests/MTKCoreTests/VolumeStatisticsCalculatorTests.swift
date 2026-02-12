//
//  VolumeStatisticsCalculatorTests.swift
//  MTK
//
//  Unit tests for VolumeStatisticsCalculator percentile and Otsu threshold computation.
//  Validates GPU calculations match expected values and CPU fallback behavior.
//
//  Thales Matheus Mendonça Santos — February 2026

import XCTest
import Metal
@_spi(Testing) import MTKCore

final class VolumeStatisticsCalculatorTests: XCTestCase {

    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var library: MTLLibrary!
    private var calculator: VolumeStatisticsCalculator!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        self.device = device

        guard let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Failed to create command queue")
        }
        self.commandQueue = commandQueue

        guard let library = ShaderLibraryLoader.makeDefaultLibrary(on: device) else {
            throw XCTSkip("No bundled metallib present; expected on CI without GPU assets")
        }
        self.library = library

        let featureFlags = FeatureFlags.evaluate(for: device)
        let debugOptions = VolumeRenderingDebugOptions()
        self.calculator = VolumeStatisticsCalculator(
            device: device,
            commandQueue: commandQueue,
            library: library,
            featureFlags: featureFlags,
            debugOptions: debugOptions
        )
    }

    // MARK: - Percentile Calculation Tests

    func testComputePercentilesWithUniformDistribution() {
        let expectation = expectation(description: "Percentile computation")

        // Create uniform histogram: 100 samples per bin across 256 bins
        let histogram = [[UInt32]](repeating: [UInt32](repeating: 100, count: 256), count: 1)
        let percentiles: [Float] = [0.02, 0.5, 0.98]

        calculator.computePercentiles(from: histogram, percentiles: percentiles) { result in
            switch result {
            case .success(let bins):
                XCTAssertEqual(bins.count, 3)

                // For uniform distribution:
                // Total count = 256 * 100 = 25,600
                // 2nd percentile threshold = 25,600 * 0.02 = 512 (bin ~5)
                // 50th percentile threshold = 25,600 * 0.5 = 12,800 (bin ~128)
                // 98th percentile threshold = 25,600 * 0.98 = 25,088 (bin ~250)
                XCTAssertLessThanOrEqual(bins[0], 10, "2nd percentile should be in early bins")
                XCTAssertGreaterThanOrEqual(bins[1], 120, "50th percentile should be near middle")
                XCTAssertLessThanOrEqual(bins[1], 135, "50th percentile should be near middle")
                XCTAssertGreaterThanOrEqual(bins[2], 245, "98th percentile should be in late bins")

                expectation.fulfill()
            case .failure(let error):
                XCTFail("Percentile computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testComputePercentilesWithSkewedDistribution() {
        let expectation = expectation(description: "Skewed percentile computation")

        // Create skewed histogram: most samples in low bins
        var histogram = [UInt32](repeating: 10, count: 256)
        // Heavy concentration in bins 20-30
        for i in 20...30 {
            histogram[i] = 1000
        }

        let percentiles: [Float] = [0.25, 0.5, 0.75]

        calculator.computePercentiles(from: [histogram], percentiles: percentiles) { result in
            switch result {
            case .success(let bins):
                XCTAssertEqual(bins.count, 3)

                // All percentiles should be in or near the concentration range
                XCTAssertGreaterThanOrEqual(bins[0], 15, "25th percentile should be near concentration")
                XCTAssertLessThanOrEqual(bins[0], 35, "25th percentile should be near concentration")
                XCTAssertGreaterThanOrEqual(bins[1], 20, "50th percentile should be in concentration")
                XCTAssertLessThanOrEqual(bins[1], 30, "50th percentile should be in concentration")
                XCTAssertGreaterThanOrEqual(bins[2], 20, "75th percentile should be near concentration")
                XCTAssertLessThanOrEqual(bins[2], 35, "75th percentile should be near concentration")

                expectation.fulfill()
            case .failure(let error):
                XCTFail("Percentile computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testComputePercentilesWithSingleBin() {
        let expectation = expectation(description: "Single bin percentile computation")

        // All samples in one bin
        var histogram = [UInt32](repeating: 0, count: 256)
        histogram[128] = 10000

        let percentiles: [Float] = [0.0, 0.5, 1.0]

        calculator.computePercentiles(from: [histogram], percentiles: percentiles) { result in
            switch result {
            case .success(let bins):
                XCTAssertEqual(bins.count, 3)

                // All percentiles should point to the same bin
                XCTAssertEqual(bins[0], 128, "All percentiles should be at bin 128")
                XCTAssertEqual(bins[1], 128, "All percentiles should be at bin 128")
                XCTAssertEqual(bins[2], 128, "All percentiles should be at bin 128")

                expectation.fulfill()
            case .failure(let error):
                XCTFail("Percentile computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testComputePercentilesRejectsEmptyHistogram() {
        let expectation = expectation(description: "Empty histogram rejection")

        let emptyHistogram: [[UInt32]] = [[]]
        let percentiles: [Float] = [0.5]

        calculator.computePercentiles(from: emptyHistogram, percentiles: percentiles) { result in
            switch result {
            case .success:
                XCTFail("Should reject empty histogram")
            case .failure(let error):
                if let statsError = error as? VolumeStatisticsCalculator.StatisticsError {
                    XCTAssertEqual(statsError, .emptyHistogram)
                } else {
                    XCTFail("Wrong error type: \(error)")
                }
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testComputePercentilesRejectsEmptyPercentileArray() {
        let expectation = expectation(description: "Empty percentile array rejection")

        let histogram = [[UInt32]](repeating: [UInt32](repeating: 100, count: 256), count: 1)
        let percentiles: [Float] = []

        calculator.computePercentiles(from: histogram, percentiles: percentiles) { result in
            switch result {
            case .success:
                XCTFail("Should reject empty percentiles array")
            case .failure(let error):
                if let statsError = error as? VolumeStatisticsCalculator.StatisticsError {
                    XCTAssertEqual(statsError, .invalidPercentiles)
                } else {
                    XCTFail("Wrong error type: \(error)")
                }
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testComputePercentilesHandlesMultiChannelHistogram() {
        let expectation = expectation(description: "Multi-channel histogram")

        // Create multi-channel histogram (uses first channel)
        let channel1 = [UInt32](repeating: 100, count: 256)
        let channel2 = [UInt32](repeating: 50, count: 256)
        let histogram = [channel1, channel2]

        let percentiles: [Float] = [0.5]

        calculator.computePercentiles(from: histogram, percentiles: percentiles) { result in
            switch result {
            case .success(let bins):
                XCTAssertEqual(bins.count, 1)
                // Should use first channel (uniform 100 per bin)
                // 50th percentile should be near middle
                XCTAssertGreaterThanOrEqual(bins[0], 120)
                XCTAssertLessThanOrEqual(bins[0], 135)
                expectation.fulfill()
            case .failure(let error):
                XCTFail("Multi-channel computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - Otsu Threshold Tests

    func testComputeOtsuThresholdWithBimodalDistribution() {
        let expectation = expectation(description: "Otsu threshold computation")

        // Create bimodal histogram: peak at bin 50 and peak at bin 200
        var histogram = [UInt32](repeating: 10, count: 256)
        // Background peak (bins 45-55)
        for i in 45...55 {
            histogram[i] = 500
        }
        // Foreground peak (bins 195-205)
        for i in 195...205 {
            histogram[i] = 500
        }

        calculator.computeOtsuThreshold(from: [histogram]) { result in
            switch result {
            case .success(let threshold):
                // Optimal threshold should be between the two peaks
                // For symmetric bimodal distribution, threshold should be roughly midway
                XCTAssertGreaterThan(threshold, 60, "Threshold should be after first peak")
                XCTAssertLessThan(threshold, 190, "Threshold should be before second peak")
                XCTAssertGreaterThanOrEqual(threshold, 100, "Threshold should be in middle region")
                XCTAssertLessThanOrEqual(threshold, 150, "Threshold should be in middle region")
                expectation.fulfill()
            case .failure(let error):
                XCTFail("Otsu computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testComputeOtsuThresholdWithAsymmetricBimodalDistribution() {
        let expectation = expectation(description: "Asymmetric bimodal Otsu")

        // Create asymmetric bimodal histogram: larger background, smaller foreground
        var histogram = [UInt32](repeating: 5, count: 256)
        // Large background peak (bins 30-40)
        for i in 30...40 {
            histogram[i] = 800
        }
        // Smaller foreground peak (bins 180-190)
        for i in 180...190 {
            histogram[i] = 300
        }

        calculator.computeOtsuThreshold(from: [histogram]) { result in
            switch result {
            case .success(let threshold):
                // Threshold should separate the two modes
                XCTAssertGreaterThan(threshold, 45, "Threshold should be after background peak")
                XCTAssertLessThan(threshold, 175, "Threshold should be before foreground peak")
                expectation.fulfill()
            case .failure(let error):
                XCTFail("Otsu computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testComputeOtsuThresholdWithSkewedDistribution() {
        let expectation = expectation(description: "Skewed distribution Otsu")

        // Create right-skewed distribution (common in medical imaging)
        var histogram = [UInt32](repeating: 0, count: 256)
        // Heavy concentration in lower bins with long tail
        for i in 0..<50 {
            histogram[i] = UInt32(1000 - (i * 15))
        }
        for i in 50..<256 {
            histogram[i] = UInt32(max(10, 250 - i))
        }

        calculator.computeOtsuThreshold(from: [histogram]) { result in
            switch result {
            case .success(let threshold):
                // Threshold should be in lower range for right-skewed data
                XCTAssertGreaterThan(threshold, 0, "Threshold should be above minimum")
                XCTAssertLessThan(threshold, 100, "Threshold should be in lower range for skewed data")
                expectation.fulfill()
            case .failure(let error):
                XCTFail("Otsu computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testComputeOtsuThresholdWithUniformDistribution() {
        let expectation = expectation(description: "Otsu uniform distribution")

        // Uniform distribution should have threshold near middle
        let histogram = [UInt32](repeating: 100, count: 256)

        calculator.computeOtsuThreshold(from: [histogram]) { result in
            switch result {
            case .success(let threshold):
                // For uniform distribution, threshold is arbitrary but should be valid
                XCTAssertGreaterThanOrEqual(threshold, 0, "Threshold should be non-negative")
                XCTAssertLessThan(threshold, 256, "Threshold should be within bin range")
                expectation.fulfill()
            case .failure(let error):
                XCTFail("Otsu computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testComputeOtsuThresholdRejectsEmptyHistogram() {
        let expectation = expectation(description: "Empty histogram rejection")

        let emptyHistogram: [[UInt32]] = [[]]

        calculator.computeOtsuThreshold(from: emptyHistogram) { result in
            switch result {
            case .success:
                XCTFail("Should reject empty histogram")
            case .failure(let error):
                if let statsError = error as? VolumeStatisticsCalculator.StatisticsError {
                    XCTAssertEqual(statsError, .emptyHistogram)
                } else {
                    XCTFail("Wrong error type: \(error)")
                }
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testComputeOtsuThresholdWithSingleBin() {
        let expectation = expectation(description: "Single bin Otsu")

        // All samples in one bin
        var histogram = [UInt32](repeating: 0, count: 256)
        histogram[100] = 10000

        calculator.computeOtsuThreshold(from: [histogram]) { result in
            switch result {
            case .success(let threshold):
                // Should return a valid threshold (at or near the populated bin)
                XCTAssertGreaterThanOrEqual(threshold, 0, "Threshold should be non-negative")
                XCTAssertLessThan(threshold, 256, "Threshold should be within bin range")
                // For single bin, threshold should be at or near that bin
                XCTAssertGreaterThanOrEqual(threshold, 95, "Threshold should be near populated bin")
                XCTAssertLessThanOrEqual(threshold, 105, "Threshold should be near populated bin")
                expectation.fulfill()
            case .failure(let error):
                XCTFail("Otsu computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testComputeOtsuThresholdAccuracyWithKnownDistribution() {
        let expectation = expectation(description: "Known distribution Otsu accuracy")

        // Create a well-defined bimodal distribution with equal peaks
        // Background: bins 40-60 (centered at 50), Foreground: bins 140-160 (centered at 150)
        var histogram = [UInt32](repeating: 0, count: 256)
        for i in 40...60 {
            histogram[i] = 400
        }
        for i in 140...160 {
            histogram[i] = 400
        }

        calculator.computeOtsuThreshold(from: [histogram]) { result in
            switch result {
            case .success(let threshold):
                // For two equal-sized, well-separated Gaussian-like peaks,
                // optimal threshold should be approximately midway between peak centers
                // Peak centers: 50 and 150, expected threshold near 100
                XCTAssertGreaterThanOrEqual(threshold, 85, "Threshold should be near midpoint of peaks")
                XCTAssertLessThanOrEqual(threshold, 115, "Threshold should be near midpoint of peaks")
                expectation.fulfill()
            case .failure(let error):
                XCTFail("Otsu computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testComputeOtsuThresholdWithMultiChannelHistogram() {
        let expectation = expectation(description: "Multi-channel Otsu")

        // Create multi-channel histogram (should use first channel)
        var channel1 = [UInt32](repeating: 10, count: 256)
        for i in 50...60 {
            channel1[i] = 500
        }
        for i in 150...160 {
            channel1[i] = 500
        }

        let channel2 = [UInt32](repeating: 100, count: 256)

        let histogram = [channel1, channel2]

        calculator.computeOtsuThreshold(from: histogram) { result in
            switch result {
            case .success(let threshold):
                // Should use first channel's bimodal distribution
                XCTAssertGreaterThan(threshold, 65, "Threshold should separate first channel's peaks")
                XCTAssertLessThan(threshold, 145, "Threshold should separate first channel's peaks")
                expectation.fulfill()
            case .failure(let error):
                XCTFail("Multi-channel Otsu computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - CPU Fallback Verification Tests

    func testPercentilesProduceMathematicallyCorrectResults() {
        let expectation = expectation(description: "Mathematically correct percentiles")

        // Create a known distribution where we can verify exact percentile bins
        // Distribution: 10 samples in each bin from 0-99, total 1000 samples
        var histogram = [UInt32](repeating: 10, count: 100)
        // Pad to 256 bins with zeros
        histogram.append(contentsOf: [UInt32](repeating: 0, count: 156))

        let percentiles: [Float] = [0.25, 0.5, 0.75]

        calculator.computePercentiles(from: [histogram], percentiles: percentiles) { result in
            switch result {
            case .success(let bins):
                XCTAssertEqual(bins.count, 3)

                // Total count = 1000, uniform distribution across 100 bins
                // 25th percentile: 1000 * 0.25 = 250 → bin 25
                // 50th percentile: 1000 * 0.5 = 500 → bin 50
                // 75th percentile: 1000 * 0.75 = 750 → bin 75
                XCTAssertEqual(bins[0], 25, "25th percentile should be at bin 25")
                XCTAssertEqual(bins[1], 50, "50th percentile should be at bin 50")
                XCTAssertEqual(bins[2], 75, "75th percentile should be at bin 75")

                expectation.fulfill()
            case .failure(let error):
                XCTFail("Percentile computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testOtsuThresholdProducesMathematicallyCorrectResult() {
        let expectation = expectation(description: "Mathematically correct Otsu")

        // Create a perfect bimodal distribution with known optimal threshold
        // Background: 100 samples each in bins 20-30 (centered at 25)
        // Foreground: 100 samples each in bins 70-80 (centered at 75)
        var histogram = [UInt32](repeating: 0, count: 256)
        for i in 20...30 {
            histogram[i] = 100
        }
        for i in 70...80 {
            histogram[i] = 100
        }

        calculator.computeOtsuThreshold(from: [histogram]) { result in
            switch result {
            case .success(let threshold):
                // For symmetric bimodal distribution, optimal threshold should be
                // approximately midway between the two modes
                // Expected: between 30 and 70, closer to the middle
                XCTAssertGreaterThan(threshold, 30, "Threshold should be after background peak")
                XCTAssertLessThan(threshold, 70, "Threshold should be before foreground peak")

                // For symmetric bimodal, threshold should be in the central region
                XCTAssertGreaterThanOrEqual(threshold, 40, "Threshold should be in central gap")
                XCTAssertLessThanOrEqual(threshold, 60, "Threshold should be in central gap")

                expectation.fulfill()
            case .failure(let error):
                XCTFail("Otsu computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testPercentilesHandleBoundaryConditions() {
        let expectation = expectation(description: "Percentile boundary conditions")

        // Test boundary percentiles (0% and 100%)
        var histogram = [UInt32](repeating: 0, count: 256)
        histogram[50] = 100  // All samples in one bin

        let percentiles: [Float] = [0.0, 1.0]

        calculator.computePercentiles(from: [histogram], percentiles: percentiles) { result in
            switch result {
            case .success(let bins):
                XCTAssertEqual(bins.count, 2)

                // Both 0th and 100th percentile should point to bin 50
                XCTAssertEqual(bins[0], 50, "0th percentile should be at bin 50")
                XCTAssertEqual(bins[1], 50, "100th percentile should be at bin 50")

                expectation.fulfill()
            case .failure(let error):
                XCTFail("Percentile computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testPercentilesHandleLargeHistogram() {
        let expectation = expectation(description: "Large histogram percentiles")

        // Test with maximum size histogram (256 bins)
        var histogram = [UInt32](repeating: 0, count: 256)
        // Create a linear gradient distribution
        for i in 0..<256 {
            histogram[i] = UInt32(i + 1)  // Increasing counts
        }

        let percentiles: [Float] = [0.1, 0.5, 0.9]

        calculator.computePercentiles(from: [histogram], percentiles: percentiles) { result in
            switch result {
            case .success(let bins):
                XCTAssertEqual(bins.count, 3)

                // For linear gradient, percentiles should be distributed accordingly
                // Lower percentiles should be in lower bins
                XCTAssertLessThan(bins[0], bins[1], "10th percentile should be before 50th")
                XCTAssertLessThan(bins[1], bins[2], "50th percentile should be before 90th")

                // Verify bins are within valid range
                for bin in bins {
                    XCTAssertGreaterThanOrEqual(bin, 0, "Bin index should be non-negative")
                    XCTAssertLessThan(bin, 256, "Bin index should be within range")
                }

                expectation.fulfill()
            case .failure(let error):
                XCTFail("Large histogram computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testOtsuThresholdHandlesSinglePeakDistribution() {
        let expectation = expectation(description: "Single peak Otsu")

        // Single peak distribution (unimodal) - common in saturated images
        var histogram = [UInt32](repeating: 0, count: 256)
        // Gaussian-like distribution centered at bin 128
        for i in 100...156 {
            let distance = abs(i - 128)
            histogram[i] = UInt32(max(10, 200 - (distance * distance)))
        }

        calculator.computeOtsuThreshold(from: [histogram]) { result in
            switch result {
            case .success(let threshold):
                // For unimodal distribution, threshold is less meaningful
                // but should still be within the data range
                XCTAssertGreaterThanOrEqual(threshold, 0, "Threshold should be non-negative")
                XCTAssertLessThan(threshold, 256, "Threshold should be within bin range")

                // Threshold should be somewhere in the distribution
                XCTAssertGreaterThanOrEqual(threshold, 50, "Threshold should be in data range")
                XCTAssertLessThanOrEqual(threshold, 200, "Threshold should be in data range")

                expectation.fulfill()
            case .failure(let error):
                XCTFail("Single peak Otsu computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testPercentilesConsistencyAcrossMultipleRuns() {
        let firstExpectation = expectation(description: "First percentile run")
        let secondExpectation = expectation(description: "Second percentile run")

        // Create a test histogram
        var histogram = [UInt32](repeating: 10, count: 256)
        for i in 50...150 {
            histogram[i] = 100
        }

        let percentiles: [Float] = [0.25, 0.5, 0.75]
        var firstResult: [UInt32]?
        var secondResult: [UInt32]?

        // First run
        calculator.computePercentiles(from: [histogram], percentiles: percentiles) { result in
            switch result {
            case .success(let bins):
                firstResult = bins
                firstExpectation.fulfill()
            case .failure(let error):
                XCTFail("First run failed: \(error)")
                firstExpectation.fulfill()
            }
        }

        wait(for: [firstExpectation], timeout: 5.0)

        // Second run with same data
        calculator.computePercentiles(from: [histogram], percentiles: percentiles) { result in
            switch result {
            case .success(let bins):
                secondResult = bins
                secondExpectation.fulfill()
            case .failure(let error):
                XCTFail("Second run failed: \(error)")
                secondExpectation.fulfill()
            }
        }

        wait(for: [secondExpectation], timeout: 5.0)

        // Verify consistency
        XCTAssertNotNil(firstResult)
        XCTAssertNotNil(secondResult)
        if let first = firstResult, let second = secondResult {
            XCTAssertEqual(first.count, second.count)
            for i in 0..<first.count {
                XCTAssertEqual(first[i], second[i], "Results should be identical across runs")
            }
        }
    }

    func testOtsuThresholdConsistencyAcrossMultipleRuns() {
        let firstExpectation = expectation(description: "First Otsu run")
        let secondExpectation = expectation(description: "Second Otsu run")

        // Create a bimodal test histogram
        var histogram = [UInt32](repeating: 10, count: 256)
        for i in 40...50 {
            histogram[i] = 400
        }
        for i in 180...190 {
            histogram[i] = 400
        }

        var firstResult: UInt32?
        var secondResult: UInt32?

        // First run
        calculator.computeOtsuThreshold(from: [histogram]) { result in
            switch result {
            case .success(let threshold):
                firstResult = threshold
                firstExpectation.fulfill()
            case .failure(let error):
                XCTFail("First run failed: \(error)")
                firstExpectation.fulfill()
            }
        }

        wait(for: [firstExpectation], timeout: 5.0)

        // Second run with same data
        calculator.computeOtsuThreshold(from: [histogram]) { result in
            switch result {
            case .success(let threshold):
                secondResult = threshold
                secondExpectation.fulfill()
            case .failure(let error):
                XCTFail("Second run failed: \(error)")
                secondExpectation.fulfill()
            }
        }

        wait(for: [secondExpectation], timeout: 5.0)

        // Verify consistency
        XCTAssertNotNil(firstResult)
        XCTAssertNotNil(secondResult)
        if let first = firstResult, let second = secondResult {
            XCTAssertEqual(first, second, "Otsu results should be identical across runs")
        }
    }

    func testCalculatorHandlesRapidSequentialCalls() {
        let expectations = (0..<5).map { expectation(description: "Sequential call \($0)") }

        // Create test histogram
        var histogram = [UInt32](repeating: 50, count: 256)
        for i in 100...120 {
            histogram[i] = 200
        }

        let percentiles: [Float] = [0.5]

        // Fire off multiple calls in quick succession
        for i in 0..<5 {
            calculator.computePercentiles(from: [histogram], percentiles: percentiles) { result in
                switch result {
                case .success(let bins):
                    XCTAssertEqual(bins.count, 1)
                    XCTAssertGreaterThanOrEqual(bins[0], 0)
                    XCTAssertLessThan(bins[0], 256)
                    expectations[i].fulfill()
                case .failure(let error):
                    XCTFail("Sequential call \(i) failed: \(error)")
                    expectations[i].fulfill()
                }
            }
        }

        wait(for: expectations, timeout: 10.0)
    }

    // MARK: - Bit Depth Support Tests

    func testPercentilesWithEightBitHistogram() {
        let expectation = expectation(description: "8-bit histogram percentiles")

        // Create 8-bit histogram: 256 bins typical for UInt8 volumes
        var histogram = [UInt32](repeating: 0, count: 256)
        // Simulate typical 8-bit grayscale distribution
        for i in 0..<256 {
            // Create a distribution with peak in mid-range
            let distance = abs(i - 128)
            histogram[i] = UInt32(max(10, 1000 - (distance * 5)))
        }

        let percentiles: [Float] = [0.02, 0.5, 0.98]

        calculator.computePercentiles(from: [histogram], percentiles: percentiles) { result in
            switch result {
            case .success(let bins):
                XCTAssertEqual(bins.count, 3)

                // Verify bins are within 8-bit range [0, 255]
                for bin in bins {
                    XCTAssertGreaterThanOrEqual(bin, 0, "Bin should be non-negative")
                    XCTAssertLessThan(bin, 256, "Bin should be within 8-bit range")
                }

                // Verify percentile ordering
                XCTAssertLessThan(bins[0], bins[1], "2nd percentile should be before 50th")
                XCTAssertLessThan(bins[1], bins[2], "50th percentile should be before 98th")

                // For distribution centered at 128, median should be near center
                XCTAssertGreaterThanOrEqual(bins[1], 100, "Median should be in central region")
                XCTAssertLessThanOrEqual(bins[1], 156, "Median should be in central region")

                expectation.fulfill()
            case .failure(let error):
                XCTFail("8-bit percentile computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testOtsuThresholdWithEightBitHistogram() {
        let expectation = expectation(description: "8-bit histogram Otsu")

        // Create 8-bit bimodal histogram typical for segmentation tasks
        var histogram = [UInt32](repeating: 5, count: 256)
        // Background peak at low intensities (bins 20-40)
        for i in 20...40 {
            let distance = abs(i - 30)
            histogram[i] = UInt32(max(100, 800 - (distance * distance * 2)))
        }
        // Foreground peak at high intensities (bins 180-220)
        for i in 180...220 {
            let distance = abs(i - 200)
            histogram[i] = UInt32(max(100, 600 - (distance * distance * 1)))
        }

        calculator.computeOtsuThreshold(from: [histogram]) { result in
            switch result {
            case .success(let threshold):
                // Threshold should be within 8-bit range
                XCTAssertGreaterThanOrEqual(threshold, 0, "Threshold should be non-negative")
                XCTAssertLessThan(threshold, 256, "Threshold should be within 8-bit range")

                // Threshold should separate the two modes
                XCTAssertGreaterThan(threshold, 45, "Threshold should be after background peak")
                XCTAssertLessThan(threshold, 175, "Threshold should be before foreground peak")

                expectation.fulfill()
            case .failure(let error):
                XCTFail("8-bit Otsu computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testPercentilesWithSixteenBitHistogram() {
        let expectation = expectation(description: "16-bit histogram percentiles")

        // Create 16-bit histogram: 4096 bins typical for medical imaging (CT range -1024 to 3071)
        let binCount = 4096
        var histogram = [UInt32](repeating: 0, count: binCount)

        // Simulate typical CT distribution with air, soft tissue, and bone peaks
        // Air peak: bins 0-200 (HU -1024 to -824)
        for i in 0..<200 {
            histogram[i] = UInt32(max(10, 500 - (i * 2)))
        }
        // Soft tissue peak: bins 1024-1280 (HU 0 to 256)
        for i in 1024..<1280 {
            let distance = abs(i - 1152)
            histogram[i] = UInt32(max(50, 2000 - (distance * 5)))
        }
        // Bone peak: bins 2048-2560 (HU 1024 to 1536)
        for i in 2048..<2560 {
            let distance = abs(i - 2304)
            histogram[i] = UInt32(max(20, 800 - distance))
        }

        let percentiles: [Float] = [0.02, 0.5, 0.98]

        calculator.computePercentiles(from: [histogram], percentiles: percentiles) { result in
            switch result {
            case .success(let bins):
                XCTAssertEqual(bins.count, 3)

                // Verify bins are within 16-bit range [0, 4095]
                for bin in bins {
                    XCTAssertGreaterThanOrEqual(bin, 0, "Bin should be non-negative")
                    XCTAssertLessThan(bin, UInt32(binCount), "Bin should be within 16-bit histogram range")
                }

                // Verify percentile ordering
                XCTAssertLessThan(bins[0], bins[1], "2nd percentile should be before 50th")
                XCTAssertLessThan(bins[1], bins[2], "50th percentile should be before 98th")

                // 2nd percentile should be in air/background range
                XCTAssertLessThan(bins[0], 500, "2nd percentile should be in lower intensity range")

                // 98th percentile should capture bone intensities
                XCTAssertGreaterThan(bins[2], 1500, "98th percentile should capture higher intensities")

                expectation.fulfill()
            case .failure(let error):
                XCTFail("16-bit percentile computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testOtsuThresholdWithSixteenBitHistogram() {
        let expectation = expectation(description: "16-bit histogram Otsu")

        // Create 16-bit bimodal histogram typical for CT bone segmentation
        let binCount = 4096
        var histogram = [UInt32](repeating: 0, count: binCount)

        // Soft tissue peak: bins 1024-1280 (HU 0 to 256)
        for i in 1024..<1280 {
            let distance = abs(i - 1152)
            histogram[i] = UInt32(max(100, 3000 - (distance * distance / 10)))
        }
        // Bone peak: bins 2048-2560 (HU 1024 to 1536)
        for i in 2048..<2560 {
            let distance = abs(i - 2304)
            histogram[i] = UInt32(max(50, 1500 - (distance * distance / 20)))
        }

        calculator.computeOtsuThreshold(from: [histogram]) { result in
            switch result {
            case .success(let threshold):
                // Threshold should be within 16-bit range
                XCTAssertGreaterThanOrEqual(threshold, 0, "Threshold should be non-negative")
                XCTAssertLessThan(threshold, UInt32(binCount), "Threshold should be within 16-bit histogram range")

                // Threshold should separate soft tissue from bone
                XCTAssertGreaterThan(threshold, 1300, "Threshold should be after soft tissue peak")
                XCTAssertLessThan(threshold, 2000, "Threshold should be before bone peak")

                // Expected threshold should be in the gap between peaks
                XCTAssertGreaterThanOrEqual(threshold, 1400, "Threshold should be in central gap")
                XCTAssertLessThanOrEqual(threshold, 1900, "Threshold should be in central gap")

                expectation.fulfill()
            case .failure(let error):
                XCTFail("16-bit Otsu computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testPercentilesWithSignedSixteenBitRange() {
        let expectation = expectation(description: "Signed 16-bit percentiles")

        // Create histogram representing signed 16-bit CT data (typical range -1024 to 3071)
        // Bin 0 represents HU -1024, bin 4095 represents HU 3071
        let binCount = 4096
        var histogram = [UInt32](repeating: 0, count: binCount)

        // Simulate full CT range with realistic distribution
        // Air: bins 0-100 (HU -1024 to -924, below typical scan range)
        for i in 0..<100 {
            histogram[i] = 50
        }
        // Lung tissue: bins 200-400 (HU -824 to -624)
        for i in 200..<400 {
            histogram[i] = UInt32(300 + (i - 300) / 2)
        }
        // Soft tissue: bins 1000-1300 (HU -24 to 276)
        for i in 1000..<1300 {
            let distance = abs(i - 1150)
            histogram[i] = UInt32(max(100, 1500 - (distance * 3)))
        }
        // Bone: bins 2000-2500 (HU 976 to 1476)
        for i in 2000..<2500 {
            histogram[i] = UInt32(max(50, 400 - abs(i - 2250) / 2))
        }

        let percentiles: [Float] = [0.01, 0.99]

        calculator.computePercentiles(from: [histogram], percentiles: percentiles) { result in
            switch result {
            case .success(let bins):
                XCTAssertEqual(bins.count, 2)

                // Verify bins are within valid range
                for bin in bins {
                    XCTAssertGreaterThanOrEqual(bin, 0)
                    XCTAssertLessThan(bin, UInt32(binCount))
                }

                // 1st percentile should be in lower range
                XCTAssertLessThan(bins[0], 1000, "1st percentile should be in lower intensity range")

                // 99th percentile should be in higher range
                XCTAssertGreaterThan(bins[1], 1500, "99th percentile should be in higher intensity range")

                expectation.fulfill()
            case .failure(let error):
                XCTFail("Signed 16-bit percentile computation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testHistogramSizeConsistency() {
        let expectation256 = expectation(description: "256 bin histogram")
        let expectation4096 = expectation(description: "4096 bin histogram")

        // Test with 8-bit histogram (256 bins)
        let histogram8bit = [UInt32](repeating: 100, count: 256)
        let percentiles: [Float] = [0.5]

        calculator.computePercentiles(from: [histogram8bit], percentiles: percentiles) { result in
            switch result {
            case .success(let bins):
                XCTAssertEqual(bins.count, 1)
                XCTAssertLessThan(bins[0], 256, "Result should be within 256 bins")
                expectation256.fulfill()
            case .failure(let error):
                XCTFail("256 bin computation failed: \(error)")
                expectation256.fulfill()
            }
        }

        // Test with 16-bit histogram (4096 bins)
        let histogram16bit = [UInt32](repeating: 100, count: 4096)

        calculator.computePercentiles(from: [histogram16bit], percentiles: percentiles) { result in
            switch result {
            case .success(let bins):
                XCTAssertEqual(bins.count, 1)
                XCTAssertLessThan(bins[0], 4096, "Result should be within 4096 bins")
                expectation4096.fulfill()
            case .failure(let error):
                XCTFail("4096 bin computation failed: \(error)")
                expectation4096.fulfill()
            }
        }

        wait(for: [expectation256, expectation4096], timeout: 5.0)
    }

    // MARK: - Performance Tests

    /// Verify statistics computation meets 100ms performance requirement
    /// Target: Percentile + Otsu computation should complete within 100ms
    func testPerformanceStatisticsComputation() {
        let percentilesExpectation = expectation(description: "Percentile performance")
        let otsuExpectation = expectation(description: "Otsu performance")

        // Create realistic histogram: bimodal distribution typical of CT scans
        var histogram = [UInt32](repeating: 0, count: 256)
        // Air/background peak (bins 10-30)
        for i in 10...30 {
            let distance = abs(i - 20)
            histogram[i] = UInt32(max(100, 5000 - (distance * distance * 50)))
        }
        // Soft tissue peak (bins 80-120)
        for i in 80...120 {
            let distance = abs(i - 100)
            histogram[i] = UInt32(max(100, 8000 - (distance * distance * 30)))
        }
        // Bone peak (bins 180-220)
        for i in 180...220 {
            let distance = abs(i - 200)
            histogram[i] = UInt32(max(50, 3000 - (distance * distance * 20)))
        }

        let percentiles: [Float] = [0.02, 0.98]  // Window level adjustment range

        // Warmup runs
        calculator.computePercentiles(from: [histogram], percentiles: percentiles) { _ in }
        calculator.computeOtsuThreshold(from: [histogram]) { _ in }

        // Wait briefly for warmup to complete
        Thread.sleep(forTimeInterval: 0.1)

        // Measure percentile computation
        let percentilesStartTime = CFAbsoluteTimeGetCurrent()
        calculator.computePercentiles(from: [histogram], percentiles: percentiles) { result in
            let percentilesDuration = (CFAbsoluteTimeGetCurrent() - percentilesStartTime) * 1000  // Convert to ms

            switch result {
            case .success:
                print("""
                Performance Benchmark - Percentiles:
                  Duration: \(String(format: "%.2f", percentilesDuration))ms
                  Target: < 50ms (half of 100ms budget)
                """)

                XCTAssertLessThan(percentilesDuration, 50.0, "Percentile computation should complete within 50ms (actual: \(String(format: "%.2f", percentilesDuration))ms)")
                percentilesExpectation.fulfill()
            case .failure(let error):
                XCTFail("Percentile computation failed: \(error)")
                percentilesExpectation.fulfill()
            }
        }

        // Measure Otsu threshold computation
        let otsuStartTime = CFAbsoluteTimeGetCurrent()
        calculator.computeOtsuThreshold(from: [histogram]) { result in
            let otsuDuration = (CFAbsoluteTimeGetCurrent() - otsuStartTime) * 1000  // Convert to ms

            switch result {
            case .success:
                print("""
                Performance Benchmark - Otsu Threshold:
                  Duration: \(String(format: "%.2f", otsuDuration))ms
                  Target: < 50ms (half of 100ms budget)
                """)

                XCTAssertLessThan(otsuDuration, 50.0, "Otsu threshold computation should complete within 50ms (actual: \(String(format: "%.2f", otsuDuration))ms)")
                otsuExpectation.fulfill()
            case .failure(let error):
                XCTFail("Otsu computation failed: \(error)")
                otsuExpectation.fulfill()
            }
        }

        wait(for: [percentilesExpectation, otsuExpectation], timeout: 5.0)
    }

    /// Verify combined statistics computation under realistic UI interaction load
    /// Simulates rapid window level adjustments during image review
    func testPerformanceCombinedStatisticsUnderLoad() {
        let iterations = 10
        let expectations = (0..<iterations).map { expectation(description: "Load test iteration \($0)") }

        // Create realistic histogram
        var histogram = [UInt32](repeating: 0, count: 256)
        for i in 20...40 {
            histogram[i] = UInt32(4000 - abs(i - 30) * 100)
        }
        for i in 100...140 {
            histogram[i] = UInt32(6000 - abs(i - 120) * 80)
        }

        let percentiles: [Float] = [0.02, 0.98]
        var durations: [Double] = []

        // Warmup
        calculator.computePercentiles(from: [histogram], percentiles: percentiles) { _ in }
        Thread.sleep(forTimeInterval: 0.05)

        // Measure multiple iterations
        for i in 0..<iterations {
            let startTime = CFAbsoluteTimeGetCurrent()

            calculator.computePercentiles(from: [histogram], percentiles: percentiles) { result in
                let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

                switch result {
                case .success:
                    durations.append(duration)
                    expectations[i].fulfill()
                case .failure(let error):
                    XCTFail("Iteration \(i) failed: \(error)")
                    expectations[i].fulfill()
                }
            }

            // Small delay to simulate realistic UI interaction cadence
            Thread.sleep(forTimeInterval: 0.01)
        }

        wait(for: expectations, timeout: 10.0)

        // Verify all iterations met performance target
        let maxDuration = durations.max() ?? 0
        let avgDuration = durations.reduce(0, +) / Double(durations.count)

        print("""
        Performance Benchmark - Load Test (\(iterations) iterations):
          Max Duration: \(String(format: "%.2f", maxDuration))ms
          Avg Duration: \(String(format: "%.2f", avgDuration))ms
          Target: < 100ms per operation
        """)

        XCTAssertLessThan(maxDuration, 100.0, "Maximum duration should be under 100ms (actual: \(String(format: "%.2f", maxDuration))ms)")
        XCTAssertLessThan(avgDuration, 50.0, "Average duration should be well under target (actual: \(String(format: "%.2f", avgDuration))ms)")
    }
}
