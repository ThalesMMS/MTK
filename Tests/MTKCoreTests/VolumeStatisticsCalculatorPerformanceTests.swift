//
//  VolumeStatisticsCalculatorPerformanceTests.swift
//  MTK
//
//  Performance tests for VolumeStatisticsCalculator.
//
//  Thales Matheus Mendonca Santos - February 2026

import Foundation
import XCTest
import Metal
@_spi(Testing) import MTKCore

final class VolumeStatisticsCalculatorPerformanceTests: XCTestCase {
    private enum Thresholds {
        static let percentilesMilliseconds = value(named: "MTK_STATS_PERCENTILES_THRESHOLD_MS",
                                                   defaultMilliseconds: 50)
        static let otsuMilliseconds = value(named: "MTK_STATS_OTSU_THRESHOLD_MS",
                                            defaultMilliseconds: 50)
        static let loadMaxMilliseconds = value(named: "MTK_STATS_LOAD_MAX_THRESHOLD_MS",
                                               defaultMilliseconds: 100)
        static let loadAverageMilliseconds = value(named: "MTK_STATS_LOAD_AVG_THRESHOLD_MS",
                                                   defaultMilliseconds: 50)

        private static func value(named name: String,
                                  defaultMilliseconds: Double) -> Double {
            guard let rawValue = ProcessInfo.processInfo.environment[name],
                  let value = Double(rawValue),
                  value > 0 else {
                return defaultMilliseconds
            }
            return value
        }
    }

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

    func testPerformanceStatisticsComputation() {
        let percentilesExpectation = expectation(description: "Percentile performance")
        let otsuExpectation = expectation(description: "Otsu performance")

        var histogram = [UInt32](repeating: 0, count: 256)
        for i in 10...30 {
            let distance = abs(i - 20)
            histogram[i] = UInt32(max(100, 5000 - (distance * distance * 50)))
        }
        for i in 80...120 {
            let distance = abs(i - 100)
            histogram[i] = UInt32(max(100, 8000 - (distance * distance * 30)))
        }
        for i in 180...220 {
            let distance = abs(i - 200)
            histogram[i] = UInt32(max(50, 3000 - (distance * distance * 20)))
        }

        let percentiles: [Float] = [0.02, 0.98]

        warmUpStatistics(histogram: histogram, percentiles: percentiles)

        let percentilesStartTime = CFAbsoluteTimeGetCurrent()
        calculator.computePercentiles(from: [histogram], percentiles: percentiles) { result in
            let percentilesDuration = (CFAbsoluteTimeGetCurrent() - percentilesStartTime) * 1000

            switch result {
            case .success:
                print("""
                Performance Benchmark - Percentiles:
                  Duration: \(String(format: "%.2f", percentilesDuration))ms
                  Target: < \(String(format: "%.2f", Thresholds.percentilesMilliseconds))ms
                """)

                XCTAssertLessThan(
                    percentilesDuration,
                    Thresholds.percentilesMilliseconds,
                    "Percentile computation should complete within \(String(format: "%.2f", Thresholds.percentilesMilliseconds))ms (actual: \(String(format: "%.2f", percentilesDuration))ms)"
                )
                percentilesExpectation.fulfill()
            case .failure(let error):
                XCTFail("Percentile computation failed: \(error)")
                percentilesExpectation.fulfill()
            }

            let otsuStartTime = CFAbsoluteTimeGetCurrent()
            self.calculator.computeOtsuThreshold(from: [histogram]) { result in
                let otsuDuration = (CFAbsoluteTimeGetCurrent() - otsuStartTime) * 1000

                switch result {
                case .success:
                    print("""
                    Performance Benchmark - Otsu Threshold:
                      Duration: \(String(format: "%.2f", otsuDuration))ms
                      Target: < \(String(format: "%.2f", Thresholds.otsuMilliseconds))ms
                    """)

                    XCTAssertLessThan(
                        otsuDuration,
                        Thresholds.otsuMilliseconds,
                        "Otsu threshold computation should complete within \(String(format: "%.2f", Thresholds.otsuMilliseconds))ms (actual: \(String(format: "%.2f", otsuDuration))ms)"
                    )
                    otsuExpectation.fulfill()
                case .failure(let error):
                    XCTFail("Otsu computation failed: \(error)")
                    otsuExpectation.fulfill()
                }
            }
        }

        wait(for: [percentilesExpectation, otsuExpectation], timeout: 5.0)
    }

    func testPerformanceCombinedStatisticsUnderLoad() {
        let iterations = 10
        let expectations = (0..<iterations).map { expectation(description: "Load test iteration \($0)") }

        var histogram = [UInt32](repeating: 0, count: 256)
        for i in 20...40 {
            histogram[i] = UInt32(4000 - abs(i - 30) * 100)
        }
        for i in 100...140 {
            histogram[i] = UInt32(6000 - abs(i - 120) * 80)
        }

        let percentiles: [Float] = [0.02, 0.98]
        var durations: [Double] = []
        let durationsQueue = DispatchQueue(label: "VolumeStatisticsCalculatorTests.durations")

        warmUpPercentiles(histogram: histogram, percentiles: percentiles)

        for i in 0..<iterations {
            let startTime = CFAbsoluteTimeGetCurrent()

            calculator.computePercentiles(from: [histogram], percentiles: percentiles) { result in
                let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

                switch result {
                case .success:
                    durationsQueue.sync {
                        durations.append(duration)
                    }
                    expectations[i].fulfill()
                case .failure(let error):
                    XCTFail("Iteration \(i) failed: \(error)")
                    expectations[i].fulfill()
                }
            }

            Thread.sleep(forTimeInterval: 0.01)
        }

        wait(for: expectations, timeout: 10.0)

        let capturedDurations = durationsQueue.sync { durations }
        let maxDuration: Double
        let avgDuration: Double
        if capturedDurations.isEmpty {
            maxDuration = 0
            avgDuration = 0
        } else {
            maxDuration = capturedDurations.max() ?? 0
            avgDuration = capturedDurations.reduce(0, +) / Double(capturedDurations.count)
        }

        print("""
        Performance Benchmark - Load Test (\(iterations) iterations):
          Max Duration: \(String(format: "%.2f", maxDuration))ms
          Avg Duration: \(String(format: "%.2f", avgDuration))ms
          Target: max < \(String(format: "%.2f", Thresholds.loadMaxMilliseconds))ms, avg < \(String(format: "%.2f", Thresholds.loadAverageMilliseconds))ms
        """)

        XCTAssertLessThan(
            maxDuration,
            Thresholds.loadMaxMilliseconds,
            "Maximum duration should be under \(String(format: "%.2f", Thresholds.loadMaxMilliseconds))ms (actual: \(String(format: "%.2f", maxDuration))ms)"
        )
        XCTAssertLessThan(
            avgDuration,
            Thresholds.loadAverageMilliseconds,
            "Average duration should be well under target (actual: \(String(format: "%.2f", avgDuration))ms)"
        )
    }

    private func warmUpStatistics(histogram: [UInt32],
                                  percentiles: [Float]) {
        let percentilesWarmUp = expectation(description: "Percentile warm-up")
        calculator.computePercentiles(from: [histogram], percentiles: percentiles) { _ in
            percentilesWarmUp.fulfill()
        }

        let otsuWarmUp = expectation(description: "Otsu warm-up")
        calculator.computeOtsuThreshold(from: [histogram]) { _ in
            otsuWarmUp.fulfill()
        }

        wait(for: [percentilesWarmUp, otsuWarmUp], timeout: 2.0)
    }

    private func warmUpPercentiles(histogram: [UInt32],
                                   percentiles: [Float]) {
        let percentilesWarmUp = expectation(description: "Load test percentile warm-up")
        calculator.computePercentiles(from: [histogram], percentiles: percentiles) { _ in
            percentilesWarmUp.fulfill()
        }

        wait(for: [percentilesWarmUp], timeout: 2.0)
    }
}
