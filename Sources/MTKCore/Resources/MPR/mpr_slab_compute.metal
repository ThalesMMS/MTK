//
//  mpr_slab_compute.metal
//  MTK
//
//  GPU-accelerated MPR slab generation using Metal compute shaders.
//  Samples 3D volume along MPR plane with configurable slab thickness
//  and blend modes (single, MIP, MinIP, mean).
//
//  Thales Matheus Mendonça Santos — February 2026
//

#include <metal_stdlib>
#include "../Shaders/volume_shader_common.metal"

using namespace metal;

#ifndef MTK_MPR_INTEGER_TEXTURE_READ
#define MTK_MPR_INTEGER_TEXTURE_READ 0
#endif

struct MPRSlabUniforms {
    int voxelMinValue;
    int voxelMaxValue;
    int blendMode;
    int numSteps;
    float slabHalf;
    float3 _pad0;

    float3 planeOrigin;
    float _pad1;
    float3 planeX;
    float _pad2;
    float3 planeY;
    float _pad3;
};

namespace {
#if MTK_MPR_INTEGER_TEXTURE_READ
inline uint nearestSampleIndex(float coordinate, uint count) {
    uint maxIndex = max(count, 1u) - 1u;
    float centeredIndex = coordinate * float(count) - 0.5f;
    float roundedIndex = centeredIndex >= 0.0f
        ? floor(centeredIndex + 0.5f)
        : ceil(centeredIndex - 0.5f);
    return uint(clamp(roundedIndex, 0.0f, float(maxIndex)));
}

inline uint3 nearestSampleIndex3D(texture3d<short, access::read> volume,
                                  float3 position) {
    return uint3(nearestSampleIndex(position.x, volume.get_width()),
                 nearestSampleIndex(position.y, volume.get_height()),
                 nearestSampleIndex(position.z, volume.get_depth()));
}

inline uint3 nearestSampleIndex3DUnsigned(texture3d<ushort, access::read> volume,
                                          float3 position) {
    return uint3(nearestSampleIndex(position.x, volume.get_width()),
                 nearestSampleIndex(position.y, volume.get_height()),
                 nearestSampleIndex(position.z, volume.get_depth()));
}

inline float sampleDensity01(texture3d<short, access::read> volume,
                             float3 position,
                             short minValue,
                             short maxValue) {
    short hu = volume.read(nearestSampleIndex3D(volume, position)).r;
    return Util::normalize(hu, minValue, maxValue);
}

inline float sampleDensity01Unsigned(texture3d<ushort, access::read> volume,
                                     float3 position,
                                     uint minValue,
                                     uint maxValue) {
    ushort raw = volume.read(nearestSampleIndex3DUnsigned(volume, position)).r;
    if (maxValue <= minValue) {
        return 0.0f;
    }

    float range = float(maxValue - minValue);
    return clamp((float(raw) - float(minValue)) / range, 0.0f, 1.0f);
}
#else
inline float sampleDensity01(texture3d<short, access::sample> volume,
                             float3 position,
                             short minValue,
                             short maxValue) {
    short hu = volume.sample(sampler3d, position).r;
    return Util::normalize(hu, minValue, maxValue);
}

inline float sampleDensity01Unsigned(texture3d<ushort, access::sample> volume,
                                     float3 position,
                                     uint minValue,
                                     uint maxValue) {
    ushort raw = volume.sample(sampler3d, position).r;
    if (maxValue <= minValue) {
        return 0.0f;
    }

    float range = float(maxValue - minValue);
    return clamp((float(raw) - float(minValue)) / range, 0.0f, 1.0f);
}
#endif

inline ushort denormalizeUnsigned(float density, uint minValue, uint maxValue) {
    float clampedDensity = clamp(density, 0.0f, 1.0f);
    float value = float(minValue) + clampedDensity * float(maxValue - minValue);
    return ushort(round(clamp(value, 0.0f, 65535.0f)));
}

inline bool isInBounds(float3 position) {
    return all(position >= -1e-6f) && all(position <= 1.0f + 1e-6f);
}
}

#if MTK_MPR_INTEGER_TEXTURE_READ
kernel void computeMPRSlab(texture3d<short, access::read> volume     [[texture(0)]],
                           texture2d<short, access::write> output    [[texture(1)]],
                           constant MPRSlabUniforms& uniforms        [[buffer(0)]],
                           uint2 gid                                 [[thread_position_in_grid]]) {
#else
kernel void computeMPRSlab(texture3d<short, access::sample> volume   [[texture(0)]],
                           texture2d<short, access::write> output    [[texture(1)]],
                           constant MPRSlabUniforms& uniforms        [[buffer(0)]],
                           uint2 gid                                 [[thread_position_in_grid]]) {
#endif

    uint width = output.get_width();
    uint height = output.get_height();

    if (gid.x >= width || gid.y >= height) {
        return;
    }

    float u = width > 1 ? float(gid.x) / float(width - 1) : 0.0f;
    float v = height > 1 ? float(gid.y) / float(height - 1) : 0.0f;

    float3 planePosition = uniforms.planeOrigin
                         + u * uniforms.planeX
                         + v * uniforms.planeY;

    if (!isInBounds(planePosition)) {
        output.write(short4(0, 0, 0, 0), gid);
        return;
    }

    short minVal = short(uniforms.voxelMinValue);
    short maxVal = short(uniforms.voxelMaxValue);

    if (uniforms.numSteps <= 1 || uniforms.slabHalf <= 0.0f || uniforms.blendMode == 0) {
        float density = sampleDensity01(volume, planePosition, minVal, maxVal);
        short hu = minVal + short(density * float(maxVal - minVal));
        output.write(short4(hu, hu, hu, 0), gid);
        return;
    }

    float3 normal = normalize(cross(uniforms.planeX, uniforms.planeY));
    int steps = max(2, uniforms.numSteps);
    float invStepsMinusOne = 1.0f / float(steps - 1);
    float slabSpan = 2.0f * uniforms.slabHalf;

    float maxDensity = 0.0f;
    float minDensity = 1.0f;
    float sumDensity = 0.0f;
    int validSamples = 0;

    for (int i = 0; i < steps; ++i) {
        float normalizedIndex = float(i) * invStepsMinusOne;
        float offset = (normalizedIndex - 0.5f) * slabSpan;
        float3 samplePosition = planePosition + offset * normal;

        if (!isInBounds(samplePosition)) {
            continue;
        }

        float density = sampleDensity01(volume, samplePosition, minVal, maxVal);

        maxDensity = max(maxDensity, density);
        minDensity = min(minDensity, density);
        sumDensity += density;
        validSamples++;
    }

    float finalDensity = 0.0f;
    switch (uniforms.blendMode) {
    case 1:
        finalDensity = maxDensity;
        break;
    case 2:
        finalDensity = (validSamples > 0) ? minDensity : 0.0f;
        break;
    case 3:
        finalDensity = (validSamples > 0) ? (sumDensity / float(validSamples)) : 0.0f;
        break;
    default:
        finalDensity = sampleDensity01(volume, planePosition, minVal, maxVal);
        break;
    }

    short hu = minVal + short(finalDensity * float(maxVal - minVal));
    output.write(short4(hu, hu, hu, 0), gid);
}

#if MTK_MPR_INTEGER_TEXTURE_READ
kernel void computeMPRSlabUnsigned(texture3d<ushort, access::read> volume [[texture(0)]],
                                   texture2d<ushort, access::write> output  [[texture(1)]],
                                   constant MPRSlabUniforms& uniforms       [[buffer(0)]],
                                   uint2 gid                                [[thread_position_in_grid]]) {
#else
kernel void computeMPRSlabUnsigned(texture3d<ushort, access::sample> volume [[texture(0)]],
                                   texture2d<ushort, access::write> output  [[texture(1)]],
                                   constant MPRSlabUniforms& uniforms       [[buffer(0)]],
                                   uint2 gid                                [[thread_position_in_grid]]) {
#endif

    uint width = output.get_width();
    uint height = output.get_height();

    if (gid.x >= width || gid.y >= height) {
        return;
    }

    float u = width > 1 ? float(gid.x) / float(width - 1) : 0.0f;
    float v = height > 1 ? float(gid.y) / float(height - 1) : 0.0f;

    float3 planePosition = uniforms.planeOrigin
                         + u * uniforms.planeX
                         + v * uniforms.planeY;

    if (!isInBounds(planePosition)) {
        output.write(ushort4(0, 0, 0, 0), gid);
        return;
    }

    uint minVal = uint(max(uniforms.voxelMinValue, 0));
    uint maxVal = uint(max(max(uniforms.voxelMaxValue, uniforms.voxelMinValue), 0));

    if (uniforms.numSteps <= 1 || uniforms.slabHalf <= 0.0f || uniforms.blendMode == 0) {
        float density = sampleDensity01Unsigned(volume, planePosition, minVal, maxVal);
        ushort value = denormalizeUnsigned(density, minVal, maxVal);
        output.write(ushort4(value, value, value, 0), gid);
        return;
    }

    float3 normal = normalize(cross(uniforms.planeX, uniforms.planeY));
    int steps = max(2, uniforms.numSteps);
    float invStepsMinusOne = 1.0f / float(steps - 1);
    float slabSpan = 2.0f * uniforms.slabHalf;

    float maxDensity = 0.0f;
    float minDensity = 1.0f;
    float sumDensity = 0.0f;
    int validSamples = 0;

    for (int i = 0; i < steps; ++i) {
        float normalizedIndex = float(i) * invStepsMinusOne;
        float offset = (normalizedIndex - 0.5f) * slabSpan;
        float3 samplePosition = planePosition + offset * normal;

        if (!isInBounds(samplePosition)) {
            continue;
        }

        float density = sampleDensity01Unsigned(volume, samplePosition, minVal, maxVal);
        maxDensity = max(maxDensity, density);
        minDensity = min(minDensity, density);
        sumDensity += density;
        validSamples++;
    }

    float finalDensity = 0.0f;
    switch (uniforms.blendMode) {
    case 1:
        finalDensity = maxDensity;
        break;
    case 2:
        finalDensity = (validSamples > 0) ? minDensity : 0.0f;
        break;
    case 3:
        finalDensity = (validSamples > 0) ? (sumDensity / float(validSamples)) : 0.0f;
        break;
    default:
        finalDensity = sampleDensity01Unsigned(volume, planePosition, minVal, maxVal);
        break;
    }

    ushort value = denormalizeUnsigned(finalDensity, minVal, maxVal);
    output.write(ushort4(value, value, value, 0), gid);
}
