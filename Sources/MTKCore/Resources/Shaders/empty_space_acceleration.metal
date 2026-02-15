#ifndef empty_space_acceleration_metal
#define empty_space_acceleration_metal

#include <metal_stdlib>
#include "../MPR/Shared.metal"
#include "volume_rendering_types.metal"

using namespace metal;

namespace ESS {

/// Calculate appropriate mip level for acceleration structure sampling based on ray step size
/// Larger steps sample coarser mip levels for faster rejection of large empty regions
[[maybe_unused]] static inline uint calculateMipLevel(float stepSize,
                                                      uint maxMipLevel)
{
    // Map step size to mip level: larger steps -> higher mip levels
    // stepSize typically ranges from ~0.001 to 0.1 for volume rendering
    // Scale by 100 to map [0.001, 0.1] -> [0.1, 10], then log2 gives [-3.3, 3.3].
    // After max(..., 1.0) and floor, this yields mip levels 0-3 for typical step sizes.
    float mipFloat = log2(max(stepSize * 100.0f, 1.0f));
    uint mipLevel = uint(floor(mipFloat));
    return min(mipLevel, maxMipLevel);
}

/// Sample min-max values from acceleration structure at specified position and mip level
/// Returns float2(min, max) normalized intensity values for the region
[[maybe_unused]] static inline float2 sampleMinMaxPyramid(texture3d<half, access::sample> accelerationTexture,
                                                          float3 texCoordinate,
                                                          uint mipLevel,
                                                          sampler textureSampler)
{
    // Sample acceleration structure at requested mip level
    // rg16Float stores (min, max) as half-precision floats
    half2 minMaxHalf = accelerationTexture.sample(textureSampler,
                                                   texCoordinate,
                                                   level(mipLevel)).rg;

    return float2(minMaxHalf);
}

/// Check if transfer function would produce any visible opacity for the given intensity range
/// Returns true if the region is completely transparent (can skip sampling)
[[maybe_unused]] static inline bool isTransparentInRange(texture2d<float, access::sample> transferTexture,
                                                         float2 intensityRange,
                                                         float opacityThreshold)
{
    // Be conservative: if *any* sample in the intensity interval can produce opacity above
    // the visibility threshold, we must NOT skip. Endpoint-only sampling can miss interior peaks.

    // Degenerate range: treat as a single sample.
    if (intensityRange.x >= intensityRange.y) {
        float alpha = VR::getTfColour(transferTexture, intensityRange.x).a;
        return alpha < opacityThreshold;
    }

    // Sample endpoints + interior points (cheap and conservative enough for typical TFs).
    // Early-out as soon as we detect visible opacity.
    const float t0 = 0.0f;
    const float t1 = 0.25f;
    const float t2 = 0.5f;
    const float t3 = 0.75f;
    const float t4 = 1.0f;

    const float lo = intensityRange.x;
    const float hi = intensityRange.y;

    float alpha0 = VR::getTfColour(transferTexture, mix(lo, hi, t0)).a;
    if (alpha0 >= opacityThreshold) { return false; }
    float alpha1 = VR::getTfColour(transferTexture, mix(lo, hi, t1)).a;
    if (alpha1 >= opacityThreshold) { return false; }
    float alpha2 = VR::getTfColour(transferTexture, mix(lo, hi, t2)).a;
    if (alpha2 >= opacityThreshold) { return false; }
    float alpha3 = VR::getTfColour(transferTexture, mix(lo, hi, t3)).a;
    if (alpha3 >= opacityThreshold) { return false; }
    float alpha4 = VR::getTfColour(transferTexture, mix(lo, hi, t4)).a;
    if (alpha4 >= opacityThreshold) { return false; }

    return true;
}

/// Main acceleration structure sampling function
/// Returns true if the region can be skipped (empty space), false if sampling is needed
[[maybe_unused]] static inline bool sampleAccelerationStructure(texture3d<half, access::sample> accelerationTexture,
                                                                constant RenderingArguments& args,
                                                                float3 texCoordinate,
                                                                float stepSize,
                                                                uint maxMipLevel,
                                                                sampler textureSampler)
{
    // Calculate appropriate mip level based on step size
    uint mipLevel = calculateMipLevel(stepSize, maxMipLevel);

    // Sample min-max values from pyramid
    float2 minMaxRange = sampleMinMaxPyramid(accelerationTexture,
                                             texCoordinate,
                                             mipLevel,
                                             textureSampler);

    // Use early termination threshold as opacity cutoff
    constant RenderingParameters& params = args.params;
    float opacityThreshold = clamp(params.earlyTerminationThreshold, 0.001f, 0.9999f);

    // Check each active channel to see if any would produce visible opacity
    float4 channelWeights = params.intensityRatio;

    // Channel 1
    if (channelWeights.x > 0.0001f) {
        if (!isTransparentInRange(args.transferTextureCh1, minMaxRange, opacityThreshold)) {
            return false; // This channel has visible content, must sample
        }
    }

    // Channel 2
    if (channelWeights.y > 0.0001f) {
        if (!isTransparentInRange(args.transferTextureCh2, minMaxRange, opacityThreshold)) {
            return false;
        }
    }

    // Channel 3
    if (channelWeights.z > 0.0001f) {
        if (!isTransparentInRange(args.transferTextureCh3, minMaxRange, opacityThreshold)) {
            return false;
        }
    }

    // Channel 4
    if (channelWeights.w > 0.0001f) {
        if (!isTransparentInRange(args.transferTextureCh4, minMaxRange, opacityThreshold)) {
            return false;
        }
    }

    // All channels are transparent in this region, can skip sampling
    return true;
}

/// Simplified acceleration structure check for single-channel rendering
/// Returns true if the region can be skipped (empty space)
[[maybe_unused]] static inline bool canSkipRegion(texture3d<half, access::sample> accelerationTexture,
                                                  texture2d<float, access::sample> transferTexture,
                                                  float3 texCoordinate,
                                                  float stepSize,
                                                  float opacityThreshold,
                                                  uint maxMipLevel,
                                                  sampler textureSampler)
{
    uint mipLevel = calculateMipLevel(stepSize, maxMipLevel);
    float2 minMaxRange = sampleMinMaxPyramid(accelerationTexture,
                                             texCoordinate,
                                             mipLevel,
                                             textureSampler);

    return isTransparentInRange(transferTexture, minMaxRange, opacityThreshold);
}

} // namespace ESS

#endif // empty_space_acceleration_metal
