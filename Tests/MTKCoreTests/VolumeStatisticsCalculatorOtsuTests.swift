//
//  VolumeStatisticsCalculatorOtsuTests.swift
//  MTK
//
//  Unit tests for VolumeStatisticsCalculator Otsu threshold computation.
//
//  Thales Matheus Mendonca Santos - February 2026

import XCTest
import Metal
@_spi(Testing) import MTKCore

final class VolumeStatisticsCalculatorOtsuTests: XCTestCase {
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

    func testComputeOtsuThresholdWithBimodalDistribution() {
        let expectation = expectation(description: "Otsu threshold computation")

        var histogram = [UInt32](repeating: 10, count: 256)
        for i in 45...55 {
            histogram[i] = 500
        }
        for i in 195...205 {
            histogram[i] = 500
        }

        calculator.computeOtsuThreshold(from: [histogram]) { result in
            switch result {
            case .success(let threshold):
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

        var histogram = [UInt32](repeating: 5, count: 256)
        for i in 30...40 {
            histogram[i] = 800
        }
        for i in 180...190 {
            histogram[i] = 300
        }

        calculator.computeOtsuThreshold(from: [histogram]) { result in
            switch result {
            case .success(let threshold):
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

        var histogram = [UInt32](repeating: 0, count: 256)
        for i in 0..<50 {
            histogram[i] = UInt32(1000 - (i * 15))
        }
        for i in 50..<256 {
            histogram[i] = UInt32(max(10, 250 - i))
        }

        calculator.computeOtsuThreshold(from: [histogram]) { result in
            switch result {
            case .success(let threshold):
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

        let histogram = [UInt32](repeating: 100, count: 256)

        calculator.computeOtsuThreshold(from: [histogram]) { result in
            switch result {
            case .success(let threshold):
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

        var histogram = [UInt32](repeating: 0, count: 256)
        histogram[100] = 10000

        calculator.computeOtsuThreshold(from: [histogram]) { result in
            switch result {
            case .success(let threshold):
                XCTAssertEqual(threshold, 100, "Single-bin threshold should match the populated bin")
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

    func testComputeOtsuThresholdReturnsExplicitFailuresForGPUSetupErrors() {
        let histogram = [[UInt32]](repeating: [UInt32](repeating: 100, count: 256), count: 1)
        let scenarios: [(VolumeStatisticsCalculator.ForcedFailure, VolumeStatisticsCalculator.StatisticsError)] = [
            (.bufferAllocationFailed, .bufferAllocationFailed),
            (.pipelineUnavailable, .pipelineUnavailable),
            (.commandBufferCreationFailed, .commandBufferCreationFailed),
            (.encoderCreationFailed, .encoderCreationFailed)
        ]

        for (forcedFailure, expectedError) in scenarios {
            let expectation = expectation(description: "Otsu failure \(forcedFailure)")
            let failingCalculator = TestStatisticsHelper.makeCalculator(device: device,
                                                                        commandQueue: commandQueue,
                                                                        library: library,
                                                                        forcedFailure: forcedFailure)

            failingCalculator.computeOtsuThreshold(from: histogram) { result in
                TestStatisticsHelper.assertStatisticsFailure(result, equals: expectedError)
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 5.0)
        }
    }
}
