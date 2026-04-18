import Foundation
import Metal
import XCTest

@_spi(Testing) @testable import MTKCore

/// Test-only CPU reference implementations for histogram statistics.
///
/// These helpers intentionally live in the test target so production code does
/// not silently substitute CPU work when GPU setup or execution fails.
enum TestStatisticsHelper {
    static func makeCalculator(device: any MTLDevice,
                               commandQueue: any MTLCommandQueue,
                               library: any MTLLibrary,
                               forcedFailure: VolumeStatisticsCalculator.ForcedFailure? = nil) -> VolumeStatisticsCalculator {
        VolumeStatisticsCalculator(
            device: device,
            commandQueue: commandQueue,
            library: library,
            featureFlags: FeatureFlags.evaluate(for: device),
            debugOptions: VolumeRenderingDebugOptions(),
            forcedFailure: forcedFailure
        )
    }

    static func assertStatisticsFailure<T>(_ result: Result<T, Error>,
                                           equals expected: VolumeStatisticsCalculator.StatisticsError,
                                           file: StaticString = #filePath,
                                           line: UInt = #line) {
        switch result {
        case .success:
            XCTFail("Expected failure \(expected)", file: file, line: line)
        case .failure(let error):
            guard let statisticsError = error as? VolumeStatisticsCalculator.StatisticsError else {
                XCTFail("Expected VolumeStatisticsCalculator.StatisticsError, got \(error)", file: file, line: line)
                return
            }
            XCTAssertEqual(statisticsError, expected, file: file, line: line)
        }
    }

    /// Computes histogram bin indices corresponding to the requested percentiles.
    /// - Parameters:
    ///   - histogram: Array of bin counts where each element is the count for that bin.
    ///   - percentiles: Array of percentile values in the range 0...1; values are clamped to 0...1. A clamped value of 1 maps to the last non-zero bin (or 0 if none exist).
    /// - Returns: An array of bin indices (`UInt32`) matching each input percentile in order.
    /// - Throws:
    ///   - `VolumeStatisticsCalculator.StatisticsError.emptyHistogram` if `histogram` is empty or all bin counts sum to zero.
    ///   - `VolumeStatisticsCalculator.StatisticsError.invalidPercentiles` if `percentiles` is empty.
    static func computePercentilesCPU(from histogram: [UInt32],
                                      percentiles: [Float]) throws -> [UInt32] {
        guard !histogram.isEmpty else {
            throw VolumeStatisticsCalculator.StatisticsError.emptyHistogram
        }

        guard !percentiles.isEmpty else {
            throw VolumeStatisticsCalculator.StatisticsError.invalidPercentiles
        }

        let totalCount = histogram.reduce(0, +)
        guard totalCount > 0 else {
            throw VolumeStatisticsCalculator.StatisticsError.emptyHistogram
        }

        var cumulativeSum: [UInt32] = []
        cumulativeSum.reserveCapacity(histogram.count)
        var runningSum: UInt32 = 0
        for count in histogram {
            runningSum += count
            cumulativeSum.append(runningSum)
        }

        var percentileBins: [UInt32] = []
        percentileBins.reserveCapacity(percentiles.count)

        for percentile in percentiles {
            let clamped = max(0, min(percentile, 1))
            if clamped >= 1 {
                if let lastNonZero = histogram.lastIndex(where: { $0 > 0 }) {
                    percentileBins.append(UInt32(lastNonZero))
                } else {
                    percentileBins.append(0)
                }
                continue
            }

            let threshold = UInt32(Float(totalCount) * clamped)
            var left = 0
            var right = cumulativeSum.count - 1
            var result = UInt32(right)

            while left <= right {
                let mid = (left + right) / 2
                if cumulativeSum[mid] > threshold {
                    result = UInt32(mid)
                    right = mid - 1
                } else {
                    left = mid + 1
                }
            }

            percentileBins.append(result)
        }

        return percentileBins
    }

    /// Computes an Otsu threshold bin index from a histogram by maximizing between-class variance.
    /// 
    /// The histogram is interpreted as bin counts where each element's index is the bin value. If the histogram contains values only in a single bin, that bin index is returned.
    /// - Parameter histogram: Array of bin counts (index = bin).
    /// - Returns: The optimal bin index to use as the Otsu threshold.
    /// - Throws: `VolumeStatisticsCalculator.StatisticsError.emptyHistogram` if `histogram` is empty, the total count is zero, or there are no non-zero bins.
    static func computeOtsuThresholdCPU(from histogram: [UInt32]) throws -> UInt32 {
        guard !histogram.isEmpty else {
            throw VolumeStatisticsCalculator.StatisticsError.emptyHistogram
        }

        let totalCount = histogram.reduce(0, +)
        guard totalCount > 0 else {
            throw VolumeStatisticsCalculator.StatisticsError.emptyHistogram
        }

        guard let firstNonZero = histogram.firstIndex(where: { $0 > 0 }),
              let lastNonZero = histogram.lastIndex(where: { $0 > 0 }) else {
            throw VolumeStatisticsCalculator.StatisticsError.emptyHistogram
        }

        if firstNonZero == lastNonZero {
            return UInt32(firstNonZero)
        }

        var totalMean: Double = 0.0
        for (bin, count) in histogram.enumerated() {
            totalMean += Double(bin) * Double(count)
        }
        totalMean /= Double(totalCount)

        var maxVariance: Double = 0.0
        var optimalThresholdStart = UInt32(firstNonZero)
        var optimalThresholdEnd = UInt32(firstNonZero)

        var backgroundWeight: Double = 0.0
        var backgroundMean: Double = 0.0

        for threshold in 0..<histogram.count {
            backgroundWeight += Double(histogram[threshold])

            if backgroundWeight == 0 {
                continue
            }

            let foregroundWeight = Double(totalCount) - backgroundWeight

            if foregroundWeight == 0 {
                break
            }

            backgroundMean += Double(threshold) * Double(histogram[threshold])
            let currentBackgroundMean = backgroundMean / backgroundWeight
            let currentForegroundMean = (Double(totalCount) * totalMean - backgroundMean) / foregroundWeight

            let variance = backgroundWeight * foregroundWeight *
                (currentBackgroundMean - currentForegroundMean) *
                (currentBackgroundMean - currentForegroundMean)

            let tolerance = max(maxVariance, 1.0) * 1e-6
            if variance > maxVariance + tolerance {
                maxVariance = variance
                optimalThresholdStart = UInt32(threshold)
                optimalThresholdEnd = UInt32(threshold)
            } else if abs(variance - maxVariance) <= tolerance, maxVariance > 0 {
                optimalThresholdEnd = UInt32(threshold)
            }
        }

        return (optimalThresholdStart + optimalThresholdEnd) / 2
    }
}
