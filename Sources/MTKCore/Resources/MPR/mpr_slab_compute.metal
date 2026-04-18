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
#include "Shared.metal"

using namespace metal;

struct MPRSlabUniforms {
    int   voxelMinValue;
    int   voxelMaxValue;
    int   blendMode;     // 0=single, 1=MIP, 2=MinIP, 3=Mean
    int   numSteps;      // >=1; 1 => MPR fino (thin slice)
    int   flipVertical;  // 1 => invert UV.y coordinate
    float slabHalf;      // half thickness in [0,1] normalized space
    float2 _pad0;

    float3 planeOrigin;  // plane origin in [0,1]^3 volume space
    float  _pad1;
    float3 planeX;       // U axis of plane (width in [0,1] space)
    float  _pad2;
    float3 planeY;       // V axis of plane (height in [0,1] space)
    float  _pad3;
};

namespace {
/// Sample density from volume and normalize to [0,1] using HU min/max
inline float sampleDensity01(texture3d<short, access::sample> volume,
                             float3 position,
                             short minValue,
                             short maxValue) {
    short hu = volume.sample(sampler3d, position).r;
    return Util::normalize(hu, minValue, maxValue);
}

/// Sample unsigned density from volume and normalize to [0,1].
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

/// Convert normalized unsigned density back to the original voxel range.
inline ushort denormalizeUnsigned(float density, uint minValue, uint maxValue) {
    float clampedDensity = clamp(density, 0.0f, 1.0f);
    float value = float(minValue) + clampedDensity * float(maxValue - minValue);
    return ushort(round(clamp(value, 0.0f, 65535.0f)));
}

/// Check if position is within volume bounds [0,1]^3
inline bool isInBounds(float3 position) {
    return all(position >= -1e-6f) && all(position <= 1.0f + 1e-6f);
}
}

/// Main compute kernel for MPR slab generation
/// Generates a 2D MPR slice by sampling 3D volume along specified plane
/// Supports thin slices (single sample) and thick slabs (MIP/MinIP/Mean)
kernel void computeMPRSlab(texture3d<short, access::sample> volume   [[texture(0)]],
                           texture2d<short, access::write> output    [[texture(1)]],
                           constant MPRSlabUniforms& uniforms        [[buffer(0)]],
                           uint2 gid                                 [[thread_position_in_grid]]) {

    uint width = output.get_width();
    uint height = output.get_height();

    // Out of bounds check
    if (gid.x >= width || gid.y >= height) {
        return;
    }

    // Convert pixel coordinates to normalized UV [0,1]
    float u = float(gid.x) / float(width - 1);
    float v = float(gid.y) / float(height - 1);

    // Apply vertical flip if requested
    if (uniforms.flipVertical != 0) {
        v = 1.0f - v;
    }

    // Calculate position on MPR plane in volume space [0,1]^3
    float3 planePosition = uniforms.planeOrigin
                         + u * uniforms.planeX
                         + v * uniforms.planeY;

    // Check if base position is within volume bounds
    if (!isInBounds(planePosition)) {
        // Write black for out-of-bounds pixels
        output.write(short4(0, 0, 0, 0), gid);
        return;
    }

    short minVal = short(uniforms.voxelMinValue);
    short maxVal = short(uniforms.voxelMaxValue);

    // Thin slice mode (single sample) OR explicit single blend mode
    if (uniforms.numSteps <= 1 || uniforms.slabHalf <= 0.0f || uniforms.blendMode == 0) {
        float density = sampleDensity01(volume, planePosition, minVal, maxVal);
        // Convert back to HU range for output
        short hu = minVal + short(density * float(maxVal - minVal));
        output.write(short4(hu, hu, hu, 0), gid);
        return;
    }

    // Thick slab mode: sample along plane normal
    float3 normal = normalize(cross(uniforms.planeX, uniforms.planeY));
    int steps = max(2, uniforms.numSteps);
    float invStepsMinusOne = 1.0f / float(steps - 1);
    float slabSpan = 2.0f * uniforms.slabHalf;

    // Accumulation variables for different blend modes
    float maxDensity = 0.0f;
    float minDensity = 1.0f;
    float sumDensity = 0.0f;
    int validSamples = 0;

    // Sample along normal direction within slab thickness
    for (int i = 0; i < steps; ++i) {
        // Map step index to [-slabHalf, +slabHalf] range
        float normalizedIndex = float(i) * invStepsMinusOne;
        float offset = (normalizedIndex - 0.5f) * slabSpan;
        float3 samplePosition = planePosition + offset * normal;

        // Skip out-of-bounds samples
        if (!isInBounds(samplePosition)) {
            continue;
        }

        float density = sampleDensity01(volume, samplePosition, minVal, maxVal);

        // Update accumulation based on blend mode
        maxDensity = max(maxDensity, density);
        minDensity = min(minDensity, density);
        sumDensity += density;
        validSamples++;
    }

    // Calculate final value based on blend mode
    float finalDensity = 0.0f;
    switch (uniforms.blendMode) {
        case 1: // MIP (Maximum Intensity Projection)
            finalDensity = maxDensity;
            break;
        case 2: // MinIP (Minimum Intensity Projection)
            finalDensity = (validSamples > 0) ? minDensity : 0.0f;
            break;
        case 3: // Mean (Average Intensity)
            finalDensity = (validSamples > 0) ? (sumDensity / float(validSamples)) : 0.0f;
            break;
        default: // Fallback to single sample
            finalDensity = sampleDensity01(volume, planePosition, minVal, maxVal);
            break;
    }

    // Convert normalized density back to HU range
    short hu = minVal + short(finalDensity * float(maxVal - minVal));
    output.write(short4(hu, hu, hu, 0), gid);
}

/// Main compute kernel for unsigned 16-bit MPR slab generation.
kernel void computeMPRSlabUnsigned(texture3d<ushort, access::sample> volume [[texture(0)]],
                                   texture2d<ushort, access::write> output  [[texture(1)]],
                                   constant MPRSlabUniforms& uniforms       [[buffer(0)]],
                                   uint2 gid                                [[thread_position_in_grid]]) {

    uint width = output.get_width();
    uint height = output.get_height();

    if (gid.x >= width || gid.y >= height) {
        return;
    }

    float u = float(gid.x) / float(width - 1);
    float v = float(gid.y) / float(height - 1);

    if (uniforms.flipVertical != 0) {
        v = 1.0f - v;
    }

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
