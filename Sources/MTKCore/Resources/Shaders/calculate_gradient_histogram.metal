//
//  calculate_gradient_histogram.metal
//  MTK
//
//  Compute kernels for 2D gradient-intensity histograms.
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

inline float normalize_value(short value, short minValue, short maxValue) {
    float numerator = float(value - minValue);
    float denominator = max(float(maxValue - minValue), 1.0f);
    return clamp(numerator / denominator, 0.0f, 1.0f);
}

inline float normalize_gradient(float gradMagnitude, float minGrad, float maxGrad) {
    float numerator = gradMagnitude - minGrad;
    float denominator = max(maxGrad - minGrad, 1.0f);
    return clamp(numerator / denominator, 0.0f, 1.0f);
}

inline float3 compute_gradient(texture3d<short, access::read> volume,
                               uint3 coord,
                               uint3 dimension) {
    if (dimension.x < 2 || dimension.y < 2 || dimension.z < 2) {
        return float3(0.0f);
    }

    uint3 xPlus = uint3(min(coord.x + 1, dimension.x - 1), coord.y, coord.z);
    uint3 xMinus = uint3(max(int(coord.x) - 1, 0), coord.y, coord.z);

    uint3 yPlus = uint3(coord.x, min(coord.y + 1, dimension.y - 1), coord.z);
    uint3 yMinus = uint3(coord.x, max(int(coord.y) - 1, 0), coord.z);

    uint3 zPlus = uint3(coord.x, coord.y, min(coord.z + 1, dimension.z - 1));
    uint3 zMinus = uint3(coord.x, coord.y, max(int(coord.z) - 1, 0));

    float sxPlus = float(volume.read(xPlus).r);
    float sxMinus = float(volume.read(xMinus).r);

    float syPlus = float(volume.read(yPlus).r);
    float syMinus = float(volume.read(yMinus).r);

    float szPlus = float(volume.read(zPlus).r);
    float szMinus = float(volume.read(zMinus).r);

    return float3(sxMinus - sxPlus, syMinus - syPlus, szMinus - szPlus);
}
}

kernel void computeGradientHistogramThreadgroup(texture3d<short, access::read> inputTexture [[texture(0)]],
                                                constant uint &intensityBinCount [[buffer(0)]],
                                                constant uint &gradientBinCount [[buffer(1)]],
                                                constant short &voxelMin [[buffer(2)]],
                                                constant short &voxelMax [[buffer(3)]],
                                                constant float &gradientMin [[buffer(4)]],
                                                constant float &gradientMax [[buffer(5)]],
                                                device atomic_uint *histogramBuffer [[buffer(6)]],
                                                threadgroup atomic_uint *localHistogram [[threadgroup(0)]],
                                                uint3 gid [[thread_position_in_grid]],
                                                uint threadIndex [[thread_index_in_threadgroup]],
                                                uint3 threadsPerThreadgroup [[threads_per_threadgroup]]) {
    uint width = inputTexture.get_width();
    uint height = inputTexture.get_height();
    uint depth = inputTexture.get_depth();

    uint intensityBins = max(intensityBinCount, 1u);
    uint gradientBins = max(gradientBinCount, 1u);

    if (intensityBins == 0 || gradientBins == 0) {
        return;
    }

    uint totalBins = intensityBins * gradientBins;
    uint threadgroupSize = max(threadsPerThreadgroup.x * threadsPerThreadgroup.y * threadsPerThreadgroup.z, 1u);

    for (uint index = threadIndex; index < totalBins; index += threadgroupSize) {
        atomic_store_explicit(&localHistogram[index], 0, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (gid.x < width && gid.y < height && gid.z < depth) {
        short raw = inputTexture.read(uint3(gid)).r;
        float normalizedIntensity = normalize_value(raw, voxelMin, voxelMax);

        float3 gradient = compute_gradient(inputTexture, gid, uint3(width, height, depth));
        float gradMagnitude = length(gradient);
        float normalizedGradient = normalize_gradient(gradMagnitude, gradientMin, gradientMax);

        uint intensityBin = histogram_bin(normalizedIntensity, intensityBins);
        uint gradientBin = histogram_bin(normalizedGradient, gradientBins);
        uint binIndex = intensityBin * gradientBins + gradientBin;

        atomic_fetch_add_explicit(&localHistogram[binIndex], 1, memory_order_relaxed);
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint index = threadIndex; index < totalBins; index += threadgroupSize) {
        uint count = atomic_load_explicit(&localHistogram[index], memory_order_relaxed);
        if (count > 0) {
            atomic_fetch_add_explicit(&histogramBuffer[index], count, memory_order_relaxed);
        }
    }
}

kernel void computeGradientHistogramLegacy(texture3d<short, access::read> inputTexture [[texture(0)]],
                                           constant uint &intensityBinCount [[buffer(0)]],
                                           constant uint &gradientBinCount [[buffer(1)]],
                                           constant short &voxelMin [[buffer(2)]],
                                           constant short &voxelMax [[buffer(3)]],
                                           constant float &gradientMin [[buffer(4)]],
                                           constant float &gradientMax [[buffer(5)]],
                                           device atomic_uint *histogramBuffer [[buffer(6)]],
                                           uint3 gid [[thread_position_in_grid]]) {

    uint width = inputTexture.get_width();
    uint height = inputTexture.get_height();
    uint depth = inputTexture.get_depth();

    if (gid.x >= width || gid.y >= height || gid.z >= depth) {
        return;
    }

    uint intensityBins = max(intensityBinCount, 1u);
    uint gradientBins = max(gradientBinCount, 1u);

    if (intensityBins == 0 || gradientBins == 0) {
        return;
    }

    short raw = inputTexture.read(uint3(gid)).r;
    float normalizedIntensity = normalize_value(raw, voxelMin, voxelMax);

    float3 gradient = compute_gradient(inputTexture, gid, uint3(width, height, depth));
    float gradMagnitude = length(gradient);
    float normalizedGradient = normalize_gradient(gradMagnitude, gradientMin, gradientMax);

    uint intensityBin = histogram_bin(normalizedIntensity, intensityBins);
    uint gradientBin = histogram_bin(normalizedGradient, gradientBins);
    uint binIndex = intensityBin * gradientBins + gradientBin;

    atomic_fetch_add_explicit(&histogramBuffer[binIndex], 1, memory_order_relaxed);
}
