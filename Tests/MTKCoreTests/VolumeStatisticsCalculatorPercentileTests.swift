//
//  VolumeStatisticsCalculatorPercentileTests.swift
//  MTK
//
//  Unit tests for VolumeStatisticsCalculator percentile computation.
//
//  Thales Matheus Mendonca Santos - February 2026

import XCTest
import Metal
@_spi(Testing) import MTKCore

final class VolumeStatisticsCalculatorPercentileTests: XCTestCase {
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

        self.calculator = TestStatisticsHelper.makeCalculator(device: device,
                                                              commandQueue: commandQueue,
                                                              library: library)
    }

    func testComputePercentilesWithUniformDistribution() {
        let expectation = expectation(description: "Percentile computation")

        let histogram = [[UInt32]](repeating: [UInt32](repeating: 100, count: 256), count: 1)
        let percentiles: [Float] = [0.02, 0.5, 0.98]

        calculator.computePercentiles(from: histogram, percentiles: percentiles) { result in
            switch result {
            case .success(let bins):
                XCTAssertEqual(bins.count, 3)
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

        var histogram = [UInt32](repeating: 10, count: 256)
        for i in 20...30 {
            histogram[i] = 1000
        }

        let percentiles: [Float] = [0.25, 0.5, 0.75]

        calculator.computePercentiles(from: [histogram], percentiles: percentiles) { result in
            switch result {
            case .success(let bins):
                XCTAssertEqual(bins.count, 3)
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

        var histogram = [UInt32](repeating: 0, count: 256)
        histogram[128] = 10000

        let percentiles: [Float] = [0.0, 0.5, 1.0]

        calculator.computePercentiles(from: [histogram], percentiles: percentiles) { result in
            switch result {
            case .success(let bins):
                XCTAssertEqual(bins.count, 3)
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

        let channel1 = [UInt32](repeating: 100, count: 256)
        let channel2 = [UInt32](repeating: 50, count: 256)
        let histogram = [channel1, channel2]

        let percentiles: [Float] = [0.5]

        calculator.computePercentiles(from: histogram, percentiles: percentiles) { result in
            switch result {
            case .success(let bins):
                XCTAssertEqual(bins.count, 1)
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

    func testComputePercentilesReturnsExplicitFailuresForGPUSetupErrors() {
        let histogram = [[UInt32]](repeating: [UInt32](repeating: 100, count: 256), count: 1)
        let percentiles: [Float] = [0.25, 0.5, 0.75]
        let scenarios: [(VolumeStatisticsCalculator.ForcedFailure, VolumeStatisticsCalculator.StatisticsError)] = [
            (.bufferAllocationFailed, .bufferAllocationFailed),
            (.pipelineUnavailable, .pipelineUnavailable),
            (.commandBufferCreationFailed, .commandBufferCreationFailed),
            (.encoderCreationFailed, .encoderCreationFailed)
        ]

        for (forcedFailure, expectedError) in scenarios {
            let expectation = expectation(description: "Percentiles failure \(forcedFailure)")
            let failingCalculator = TestStatisticsHelper.makeCalculator(device: device,
                                                                        commandQueue: commandQueue,
                                                                        library: library,
                                                                        forcedFailure: forcedFailure)

            failingCalculator.computePercentiles(from: histogram, percentiles: percentiles) { result in
                TestStatisticsHelper.assertStatisticsFailure(result, equals: expectedError)
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 5.0)
        }
    }

    /// A dispatch the driver discarded before it ran completes with no error at all, over
    /// buffers the GPU never touched — which reads back as bin 0 for every percentile, a
    /// perfectly ordinary-looking answer. Only the scan total says the work never happened.
    func testComputePercentilesFailsWhenTheDispatchNeverRan() {
        let histogram = [[UInt32]](repeating: [UInt32](repeating: 100, count: 256), count: 1)
        let percentiles: [Float] = [0.25, 0.5, 0.75]
        let expectation = expectation(description: "Percentiles dispatch never ran")
        let calculator = TestStatisticsHelper.makeCalculator(device: device,
                                                             commandQueue: commandQueue,
                                                             library: library,
                                                             forcedFailure: .dispatchNeverRuns)

        calculator.computePercentiles(from: histogram, percentiles: percentiles) { result in
            TestStatisticsHelper.assertStatisticsFailure(
                result,
                equals: .cumulativeSumDidNotCoverHistogram(counted: 0, expected: 25_600)
            )
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testComputePercentilesRecoversWhenOnlyTheFirstDispatchIsDiscarded() {
        let histogram = [[UInt32]](repeating: [UInt32](repeating: 100, count: 256), count: 1)
        let percentiles: [Float] = [0.25, 0.5, 0.75]
        let expectedBins = try? TestStatisticsHelper.computePercentilesCPU(from: histogram[0],
                                                                           percentiles: percentiles)
        let expectation = expectation(description: "Percentiles retry")
        let calculator = TestStatisticsHelper.makeCalculator(device: device,
                                                             commandQueue: commandQueue,
                                                             library: library,
                                                             forcedFailure: .firstDispatchNeverRuns)

        calculator.computePercentiles(from: histogram, percentiles: percentiles) { result in
            switch result {
            case .success(let bins):
                XCTAssertEqual(bins, expectedBins)
            case .failure(let error):
                XCTFail("One discarded dispatch should not fail the computation: \(error)")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }
}
