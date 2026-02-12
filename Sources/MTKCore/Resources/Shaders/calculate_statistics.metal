//
//  calculate_statistics.metal
//  MTK
//
//  Compute kernels for volume statistics (cumulative sum, percentiles, Otsu).
//

#include <metal_stdlib>
using namespace metal;

namespace {
/// Clamp value to valid range [0, 1]
inline float clamp_percentile(float value) {
    return clamp(value, 0.0f, 1.0f);
}

/// Find bin index where cumulative sum reaches target
inline uint find_percentile_bin(device const uint *cumulativeSum,
                                uint binCount,
                                uint totalCount,
                                float percentile) {
    if (binCount == 0 || totalCount == 0) {
        return 0;
    }

    float clamped = clamp_percentile(percentile);
    uint target = uint(clamped * float(totalCount));

    // Binary search would be more efficient, but linear search is clearer
    // and performance is acceptable for typical bin counts (256-1024)
    for (uint i = 0; i < binCount; ++i) {
        if (cumulativeSum[i] >= target) {
            return i;
        }
    }
    return binCount - 1;
}
}

/// Compute cumulative sum (prefix sum) of histogram using parallel scan.
/// This kernel uses a work-efficient parallel prefix sum algorithm.
/// Input: histogram buffer with counts per bin
/// Output: cumulative sum buffer where output[i] = sum of histogram[0...i]
kernel void computeCumulativeSum(device const uint *histogramBuffer [[buffer(0)]],
                                 device uint *cumulativeSumBuffer [[buffer(1)]],
                                 constant uint &binCount [[buffer(2)]],
                                 threadgroup uint *sharedData [[threadgroup(0)]],
                                 uint tid [[thread_position_in_threadgroup]],
                                 uint threadgroupSize [[threads_per_threadgroup]]) {

    uint bins = max(binCount, 1u);

    // Load histogram data into shared memory
    if (tid < bins) {
        sharedData[tid] = histogramBuffer[tid];
    } else {
        sharedData[tid] = 0;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Parallel prefix sum using Hillis-Steele algorithm
    // This is not the most work-efficient algorithm (O(n log n) operations)
    // but it's simple and works well for typical bin counts (256-1024)
    for (uint stride = 1; stride < bins; stride *= 2) {
        uint previous = 0;
        if (tid >= stride && tid < bins) {
            previous = sharedData[tid - stride];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        if (tid >= stride && tid < bins) {
            sharedData[tid] += previous;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    // Write cumulative sum to output buffer
    if (tid < bins) {
        cumulativeSumBuffer[tid] = sharedData[tid];
    }
}

/// Compute cumulative sum using sequential algorithm (fallback).
/// More efficient for small bin counts or when threadgroup size is limited.
kernel void computeCumulativeSumSequential(device const uint *histogramBuffer [[buffer(0)]],
                                          device uint *cumulativeSumBuffer [[buffer(1)]],
                                          constant uint &binCount [[buffer(2)]]) {

    uint bins = max(binCount, 1u);

    uint cumulative = 0;
    for (uint i = 0; i < bins; ++i) {
        cumulative += histogramBuffer[i];
        cumulativeSumBuffer[i] = cumulative;
    }
}

/// Extract percentile bin indices from cumulative sum.
/// Input: cumulative sum buffer, array of percentiles (e.g., [0.02, 0.98])
/// Output: array of bin indices corresponding to each percentile
kernel void extractPercentiles(device const uint *cumulativeSumBuffer [[buffer(0)]],
                               constant uint &binCount [[buffer(1)]],
                               constant uint &totalCount [[buffer(2)]],
                               constant float *percentiles [[buffer(3)]],
                               constant uint &percentileCount [[buffer(4)]],
                               device uint *percentileBins [[buffer(5)]],
                               uint gid [[thread_position_in_grid]]) {

    if (gid >= percentileCount) {
        return;
    }

    uint bins = max(binCount, 1u);
    float percentile = percentiles[gid];

    percentileBins[gid] = find_percentile_bin(cumulativeSumBuffer,
                                               bins,
                                               totalCount,
                                               percentile);
}

/// Calculate Otsu threshold using inter-class variance maximization.
/// This finds the optimal threshold that separates the histogram into two classes
/// (background and foreground) by maximizing the between-class variance.
/// Input: histogram buffer with counts per bin
/// Output: single bin index representing the optimal Otsu threshold
kernel void calculateOtsuThreshold(device const uint *histogramBuffer [[buffer(0)]],
                                   constant uint &binCount [[buffer(1)]],
                                   constant uint &totalCount [[buffer(2)]],
                                   device uint *otsuThresholdBin [[buffer(3)]]) {

    if (totalCount == 0 || binCount == 0) {
        otsuThresholdBin[0] = 0;
        return;
    }

    uint bins = max(binCount, 1u);
    float totalCountF = float(totalCount);

    // Calculate mean intensity of entire histogram
    float globalMean = 0.0f;
    for (uint i = 0; i < bins; ++i) {
        float probability = float(histogramBuffer[i]) / totalCountF;
        globalMean += float(i) * probability;
    }

    // Find threshold that maximizes between-class variance
    float maxVariance = 0.0f;
    uint optimalThreshold = 0;

    float cumulativeWeight = 0.0f;
    float cumulativeMean = 0.0f;

    for (uint threshold = 0; threshold < bins - 1; ++threshold) {
        float probability = float(histogramBuffer[threshold]) / totalCountF;
        cumulativeWeight += probability;
        cumulativeMean += float(threshold) * probability;

        // Avoid division by zero
        if (cumulativeWeight < 1e-6f || cumulativeWeight > (1.0f - 1e-6f)) {
            continue;
        }

        float backgroundWeight = cumulativeWeight;
        float foregroundWeight = 1.0f - cumulativeWeight;

        float backgroundMean = cumulativeMean / backgroundWeight;
        float foregroundMean = (globalMean - cumulativeMean) / foregroundWeight;

        // Between-class variance: σ²_b = w0 * w1 * (μ1 - μ0)²
        float meanDiff = foregroundMean - backgroundMean;
        float betweenClassVariance = backgroundWeight * foregroundWeight * meanDiff * meanDiff;

        if (betweenClassVariance > maxVariance) {
            maxVariance = betweenClassVariance;
            optimalThreshold = threshold;
        }
    }

    otsuThresholdBin[0] = optimalThreshold;
}
