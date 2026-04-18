//
//  VolumeStatisticsCalculatorVerificationTests.swift
//  MTK
//
//  Unit tests for VolumeStatisticsCalculator reference verification and histogram format support.
//
//  Thales Matheus Mendonca Santos - February 2026

import XCTest
import Metal
@_spi(Testing) import MTKCore

final class VolumeStatisticsCalculatorVerificationTests: XCTestCase {
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

        let library = try ShaderLibraryLoader.loadLibrary(for: device)
        self.library = library

        self.calculator = VolumeStatisticsCalculator(
            device: device,
            commandQueue: commandQueue,
            library: library,
            featureFlags: FeatureFlags.evaluate(for: device),
            debugOptions: VolumeRenderingDebugOptions(),
            forcedFailure: nil
        )
    }

    func testPercentilesProduceMathematicallyCorrectResults() {
        let expectation = expectation(description: "Mathematically correct percentiles")

        var histogram = [UInt32](repeating: 10, count: 100)
        histogram.append(contentsOf: [UInt32](repeating: 0, count: 156))

        let percentiles: [Float] = [0.25, 0.5, 0.75]
        guard let expectedBins = expectedPercentiles(from: histogram,
                                                     percentiles: percentiles) else {
            return
        }

        calculator.computePercentiles(from: [histogram], percentiles: percentiles) { result in
            switch result {
            case .success(let bins):
                XCTAssertEqual(bins, expectedBins)
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

        var histogram = [UInt32](repeating: 0, count: 256)
        for i in 20...30 {
            histogram[i] = 100
        }
        for i in 70...80 {
            histogram[i] = 100
        }

        guard let expectedThreshold = expectedOtsuThreshold(from: histogram) else {
            return
        }

        calculator.computeOtsuThreshold(from: [histogram]) { result in
            switch result {
            case .success(let threshold):
                XCTAssertEqual(threshold, expectedThreshold)
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

        var histogram = [UInt32](repeating: 0, count: 256)
        histogram[50] = 100

        let percentiles: [Float] = [0.0, 1.0]
        guard let expectedBins = expectedPercentiles(from: histogram,
                                                     percentiles: percentiles) else {
            return
        }

        calculator.computePercentiles(from: [histogram], percentiles: percentiles) { result in
            switch result {
            case .success(let bins):
                XCTAssertEqual(bins, expectedBins)
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

        var histogram = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            histogram[i] = UInt32(i + 1)
        }

        let percentiles: [Float] = [0.1, 0.5, 0.9]
        guard let expectedBins = expectedPercentiles(from: histogram,
                                                     percentiles: percentiles) else {
            return
        }

        calculator.computePercentiles(from: [histogram], percentiles: percentiles) { result in
            switch result {
            case .success(let bins):
                XCTAssertEqual(bins, expectedBins)
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

        var histogram = [UInt32](repeating: 0, count: 256)
        for i in 100...156 {
            let distance = abs(i - 128)
            histogram[i] = UInt32(max(10, 200 - (distance * distance)))
        }
        guard let expectedThreshold = expectedOtsuThreshold(from: histogram) else {
            return
        }

        calculator.computeOtsuThreshold(from: [histogram]) { result in
            switch result {
            case .success(let threshold):
                XCTAssertEqual(threshold, expectedThreshold)
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

        var histogram = [UInt32](repeating: 10, count: 256)
        for i in 50...150 {
            histogram[i] = 100
        }

        let percentiles: [Float] = [0.25, 0.5, 0.75]
        var firstResult: [UInt32]?
        var secondResult: [UInt32]?

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

        XCTAssertNotNil(firstResult)
        XCTAssertNotNil(secondResult)
        if let first = firstResult, let second = secondResult {
            XCTAssertEqual(first.count, second.count)
            for index in 0..<first.count {
                XCTAssertEqual(first[index], second[index], "Results should be identical across runs")
            }
        }
    }

    func testOtsuThresholdConsistencyAcrossMultipleRuns() {
        let firstExpectation = expectation(description: "First Otsu run")
        let secondExpectation = expectation(description: "Second Otsu run")

        var histogram = [UInt32](repeating: 10, count: 256)
        for i in 40...50 {
            histogram[i] = 400
        }
        for i in 180...190 {
            histogram[i] = 400
        }

        var firstResult: UInt32?
        var secondResult: UInt32?

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

        XCTAssertNotNil(firstResult)
        XCTAssertNotNil(secondResult)
        if let first = firstResult, let second = secondResult {
            XCTAssertEqual(first, second, "Otsu results should be identical across runs")
        }
    }

    func testCalculatorHandlesRapidSequentialCalls() {
        let expectations = (0..<5).map { expectation(description: "Sequential call \($0)") }

        var histogram = [UInt32](repeating: 50, count: 256)
        for i in 100...120 {
            histogram[i] = 200
        }

        let percentiles: [Float] = [0.5]

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

    func testPercentilesWithEightBitHistogram() {
        let expectation = expectation(description: "8-bit histogram percentiles")

        var histogram = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            let distance = abs(i - 128)
            histogram[i] = UInt32(max(10, 1000 - (distance * 5)))
        }

        let percentiles: [Float] = [0.02, 0.5, 0.98]

        calculator.computePercentiles(from: [histogram], percentiles: percentiles) { result in
            switch result {
            case .success(let bins):
                XCTAssertEqual(bins.count, 3)
                for bin in bins {
                    XCTAssertGreaterThanOrEqual(bin, 0, "Bin should be non-negative")
                    XCTAssertLessThan(bin, 256, "Bin should be within 8-bit range")
                }
                XCTAssertLessThan(bins[0], bins[1], "2nd percentile should be before 50th")
                XCTAssertLessThan(bins[1], bins[2], "50th percentile should be before 98th")
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

        var histogram = [UInt32](repeating: 5, count: 256)
        for i in 20...40 {
            let distance = abs(i - 30)
            histogram[i] = UInt32(max(100, 800 - (distance * distance * 2)))
        }
        for i in 180...220 {
            let distance = abs(i - 200)
            histogram[i] = UInt32(max(100, 600 - (distance * distance)))
        }

        calculator.computeOtsuThreshold(from: [histogram]) { result in
            switch result {
            case .success(let threshold):
                XCTAssertGreaterThanOrEqual(threshold, 0, "Threshold should be non-negative")
                XCTAssertLessThan(threshold, 256, "Threshold should be within 8-bit range")
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

        let binCount = 4096
        var histogram = [UInt32](repeating: 0, count: binCount)

        for i in 0..<200 {
            histogram[i] = UInt32(max(10, 500 - (i * 2)))
        }
        for i in 1024..<1280 {
            let distance = abs(i - 1152)
            histogram[i] = UInt32(max(50, 2000 - (distance * 5)))
        }
        for i in 2048..<2560 {
            let distance = abs(i - 2304)
            histogram[i] = UInt32(max(20, 800 - distance))
        }

        let percentiles: [Float] = [0.02, 0.5, 0.98]

        calculator.computePercentiles(from: [histogram], percentiles: percentiles) { result in
            switch result {
            case .success(let bins):
                XCTAssertEqual(bins.count, 3)
                for bin in bins {
                    XCTAssertGreaterThanOrEqual(bin, 0, "Bin should be non-negative")
                    XCTAssertLessThan(bin, UInt32(binCount), "Bin should be within 16-bit histogram range")
                }
                XCTAssertLessThan(bins[0], bins[1], "2nd percentile should be before 50th")
                XCTAssertLessThan(bins[1], bins[2], "50th percentile should be before 98th")
                XCTAssertLessThan(bins[0], 500, "2nd percentile should be in lower intensity range")
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

        let binCount = 4096
        var histogram = [UInt32](repeating: 0, count: binCount)

        for i in 1024..<1280 {
            let distance = abs(i - 1152)
            histogram[i] = UInt32(max(100, 3000 - (distance * distance / 10)))
        }
        for i in 2048..<2560 {
            let distance = abs(i - 2304)
            histogram[i] = UInt32(max(50, 1500 - (distance * distance / 20)))
        }

        calculator.computeOtsuThreshold(from: [histogram]) { result in
            switch result {
            case .success(let threshold):
                XCTAssertGreaterThanOrEqual(threshold, 0, "Threshold should be non-negative")
                XCTAssertLessThan(threshold, UInt32(binCount), "Threshold should be within 16-bit histogram range")
                XCTAssertGreaterThan(threshold, 1300, "Threshold should be after soft tissue peak")
                XCTAssertLessThan(threshold, 2000, "Threshold should be before bone peak")
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

        let binCount = 4096
        var histogram = [UInt32](repeating: 0, count: binCount)

        for i in 0..<100 {
            histogram[i] = 50
        }
        for i in 200..<400 {
            histogram[i] = UInt32(300 + (i - 300) / 2)
        }
        for i in 1000..<1300 {
            let distance = abs(i - 1150)
            histogram[i] = UInt32(max(100, 1500 - (distance * 3)))
        }
        for i in 2000..<2500 {
            histogram[i] = UInt32(max(50, 400 - abs(i - 2250) / 2))
        }

        let percentiles: [Float] = [0.01, 0.99]

        calculator.computePercentiles(from: [histogram], percentiles: percentiles) { result in
            switch result {
            case .success(let bins):
                XCTAssertEqual(bins.count, 2)
                for bin in bins {
                    XCTAssertGreaterThanOrEqual(bin, 0)
                    XCTAssertLessThan(bin, UInt32(binCount))
                }
                XCTAssertLessThan(bins[0], 1000, "1st percentile should be in lower intensity range")
                XCTAssertGreaterThan(bins[1], 1500, "99th percentile should be in higher range")
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

    private func expectedPercentiles(from histogram: [UInt32],
                                     percentiles: [Float],
                                     file: StaticString = #filePath,
                                     line: UInt = #line) -> [UInt32]? {
        do {
            return try TestStatisticsHelper.computePercentilesCPU(from: histogram,
                                                                  percentiles: percentiles)
        } catch {
            XCTFail("CPU percentile reference failed: \(error)", file: file, line: line)
            return nil
        }
    }

    private func expectedOtsuThreshold(from histogram: [UInt32],
                                       file: StaticString = #filePath,
                                       line: UInt = #line) -> UInt32? {
        do {
            return try TestStatisticsHelper.computeOtsuThresholdCPU(from: histogram)
        } catch {
            XCTFail("CPU Otsu reference failed: \(error)", file: file, line: line)
            return nil
        }
    }
}
