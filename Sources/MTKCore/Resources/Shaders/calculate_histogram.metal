//
//  calculate_histogram.metal
//  MTK
//
//  Compute kernels for volume histograms, adapted from Acto3D.
//

#include <metal_stdlib>
using namespace metal;

namespace {
inline uint histogram_bin(float value, uint binCount) {
    if (binCount <= 1) {
        return 0;
    }
    float clamped = clamp(value, 0.0f, 1.0f);
    float scaled = clamped * float(binCount - 1);
    return min(uint(round(scaled)), binCount - 1);
}

inline float normalize_density(short value, short minValue, short maxValue) {
    float numerator = float(value - minValue);
    float denominator = max(float(maxValue - minValue), 1.0f);
    return clamp(numerator / denominator, 0.0f, 1.0f);
}
}

kernel void computeHistogramThreadgroup(texture3d<short, access::read> inputTexture [[texture(0)]],
                                        constant uint8_t &channelCount [[buffer(0)]],
                                        constant uint &binCount [[buffer(1)]],
                                        constant short &voxelMin [[buffer(2)]],
                                        constant short &voxelMax [[buffer(3)]],
                                        device atomic_uint *histogramBuffer [[buffer(4)]],
                                        threadgroup atomic_uint *localHistogram [[threadgroup(0)]],
                                        uint3 gid [[thread_position_in_grid]],
                                        uint threadIndex [[thread_index_in_threadgroup]],
                                        uint3 threadsPerThreadgroup [[threads_per_threadgroup]]) {
    uint width = inputTexture.get_width();
    uint height = inputTexture.get_height();
    uint depth = inputTexture.get_depth();

    uint limitedChannelCount = max(1u, min(uint(channelCount), 4u));
    uint bins = max(binCount, 1u);

    if (limitedChannelCount == 0 || bins == 0) {
        return;
    }

    uint totalBins = bins * limitedChannelCount;
    uint threadgroupSize = max(threadsPerThreadgroup.x * threadsPerThreadgroup.y * threadsPerThreadgroup.z, 1u);

    for (uint index = threadIndex; index < totalBins; index += threadgroupSize) {
        atomic_store_explicit(&localHistogram[index], 0, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (gid.x < width && gid.y < height && gid.z < depth) {
        short raw = inputTexture.read(uint3(gid)).r;
        float normalized = normalize_density(raw, voxelMin, voxelMax);
        uint bin = histogram_bin(normalized, bins);
        for (uint channel = 0; channel < limitedChannelCount; ++channel) {
            atomic_fetch_add_explicit(&localHistogram[channel * bins + bin], 1, memory_order_relaxed);
        }
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint index = threadIndex; index < totalBins; index += threadgroupSize) {
        uint count = atomic_load_explicit(&localHistogram[index], memory_order_relaxed);
        if (count > 0) {
            // Use relaxed memory order for performance. For histogram calculations,
            // the exact order of atomic operations is not critical, only that they are atomic.
            // This avoids unnecessary synchronization overhead.
            atomic_fetch_add_explicit(&histogramBuffer[index], count, memory_order_relaxed);
        }
    }
}

kernel void computeHistogramLegacy(texture3d<short, access::read> inputTexture [[texture(0)]],
                                   constant uint8_t &channelCount [[buffer(0)]],
                                   constant uint &binCount [[buffer(1)]],
                                   constant short &voxelMin [[buffer(2)]],
                                   constant short &voxelMax [[buffer(3)]],
                                   device atomic_uint *histogramBuffer [[buffer(4)]],
                                   uint3 gid [[thread_position_in_grid]]) {

    uint width = inputTexture.get_width();
    uint height = inputTexture.get_height();
    uint depth = inputTexture.get_depth();

    if (gid.x >= width || gid.y >= height || gid.z >= depth) {
        return;
    }

    uint limitedChannelCount = max(1u, min(uint(channelCount), 4u));
    uint bins = max(binCount, 1u);

    if (limitedChannelCount == 0 || bins == 0) {
        return;
    }

    short raw = inputTexture.read(uint3(gid)).r;
    float normalized = normalize_density(raw, voxelMin, voxelMax);
    uint bin = histogram_bin(normalized, bins);

    for (uint channel = 0; channel < limitedChannelCount; ++channel) {
        atomic_fetch_add_explicit(&histogramBuffer[channel * bins + bin], 1, memory_order_relaxed);
    }
}
