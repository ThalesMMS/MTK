//
//  empty_space_compute.metal
//  MTK
//
//  Compute kernels for building min-max mipmaps and cached visibility pyramids
//  used in empty space skipping during volumetric ray marching. These kernels
//  replace the previous MPS-based approach that incorrectly attempted 2D texture
//  views from 3D textures.
//
//  Thales Matheus Mendonca Santos — February 2026
//

#include <metal_stdlib>
using namespace metal;

/// Build the base mip level (level 0) of the min-max pyramid.
///
/// For each voxel in the source 3D volume, normalizes the intensity value
/// to [0, 1] and writes it to both the R (min) and G (max) channels of
/// the destination rg16Float texture. At the base level, each voxel's
/// min and max are identical (the voxel's own normalized intensity).
kernel void computeMinMaxBase(texture3d<short, access::read> source [[texture(0)]],
                              texture3d<half, access::write> destination [[texture(1)]],
                              constant int &dataMin [[buffer(0)]],
                              constant int &dataMax [[buffer(1)]],
                              uint3 gid [[thread_position_in_grid]])
{
    uint width = source.get_width();
    uint height = source.get_height();
    uint depth = source.get_depth();

    if (gid.x >= width || gid.y >= height || gid.z >= depth) {
        return;
    }

    short rawValue = source.read(gid).r;
    float range = max(float(dataMax - dataMin), 1.0f);
    float normalized = clamp(float(int(rawValue) - dataMin) / range, 0.0f, 1.0f);

    // Store (min, max) = (normalized, normalized) at base level
    destination.write(half4(half(normalized), half(normalized), 0.0h, 0.0h), gid);
}

/// Build the base mip level (level 0) of the min-max pyramid for unsigned 16-bit sources.
///
/// Same as `computeMinMaxBase`, but reads `r16Uint` data as unsigned values.
kernel void computeMinMaxBaseUnsigned(texture3d<ushort, access::read> source [[texture(0)]],
                                      texture3d<half, access::write> destination [[texture(1)]],
                                      constant int &dataMin [[buffer(0)]],
                                      constant int &dataMax [[buffer(1)]],
                                      uint3 gid [[thread_position_in_grid]])
{
    uint width = source.get_width();
    uint height = source.get_height();
    uint depth = source.get_depth();

    if (gid.x >= width || gid.y >= height || gid.z >= depth) {
        return;
    }

    ushort rawValue = source.read(gid).r;
    float range = max(float(dataMax - dataMin), 1.0f);
    float normalized = clamp(float(int(rawValue) - dataMin) / range, 0.0f, 1.0f);

    destination.write(half4(half(normalized), half(normalized), 0.0h, 0.0h), gid);
}

/// Downsample one level of the min-max pyramid.
///
/// Reads a 2x2x2 block from the source mip level and computes the proper
/// min (minimum of all R values) and max (maximum of all G values) for the
/// destination mip level. This preserves correct min-max semantics unlike
/// bilinear filtering which would average the values.
///
/// `apronVoxels` widens the window by that many source texels on every side. The
/// raycaster (#1692) decides a block is empty from this pyramid and then jumps the ray
/// over the whole block, so the block's min/max has to bound every density the raycaster
/// could have sampled *inside* it — which is not the same set as the voxels the block
/// owns. Two separate reasons, one voxel each:
///
///   * the volume is read through a linear sampler, so a sample taken just inside a face
///     interpolates the neighbouring block's voxel;
///   * `VR::sampleCoordinate` spreads [0,1] over `dim - 1` voxel *centres*, while
///     `ESS::sampleAccelerationStructureAtLevel` indexes blocks by `floor(coord * dim)`.
///     The two conventions drift by up to a voxel across the axis.
///
/// One voxel of apron at the first downsample covers both, and it stays one voxel at
/// every coarser level: a level-1 texel that already spans `[2g-1, 2g+2]` makes its
/// level-2 parent span `[4g-1, 4g+4]`, the level-3 block `[8b-1, 8b+8]`. Applying the
/// apron once is therefore both sufficient and far cheaper than dilating level 0, which
/// would cost 27 reads for every voxel of the volume.
kernel void computeMinMaxDownsample(texture3d<half, access::read> source [[texture(0)]],
                                    texture3d<half, access::write> destination [[texture(1)]],
                                    constant int &apronVoxels [[buffer(0)]],
                                    uint3 gid [[thread_position_in_grid]])
{
    uint dstWidth = destination.get_width();
    uint dstHeight = destination.get_height();
    uint dstDepth = destination.get_depth();

    if (gid.x >= dstWidth || gid.y >= dstHeight || gid.z >= dstDepth) {
        return;
    }

    int3 srcBase = int3(gid) * 2;
    int3 srcLast = int3(int(source.get_width()) - 1,
                        int(source.get_height()) - 1,
                        int(source.get_depth()) - 1);
    int apron = max(apronVoxels, 0);

    half minVal = half(1.0h);
    half maxVal = half(0.0h);

    // Read the 2x2x2 block plus its apron from source, clamping at edges
    for (int dz = -apron; dz < 2 + apron; dz++) {
        for (int dy = -apron; dy < 2 + apron; dy++) {
            for (int dx = -apron; dx < 2 + apron; dx++) {
                uint3 coord = uint3(clamp(srcBase + int3(dx, dy, dz), int3(0), srcLast));
                half2 minMax = source.read(coord).rg;
                minVal = min(minVal, minMax.r);
                maxVal = max(maxVal, minMax.g);
            }
        }
    }

    destination.write(half4(minVal, maxVal, 0.0h, 0.0h), gid);
}

/// Bake transfer-function visibility for one min-max mip level.
///
/// The ray marcher consumes the resulting r8Unorm pyramid with one discrete read per
/// hierarchy level. Transfer-function evaluation therefore runs only when the cached
/// visibility signature changes, rather than for every ray step.
kernel void computeEmptySpaceVisibility(
    texture3d<half, access::read> minMaxSource [[texture(0)]],
    texture3d<half, access::write> visibilityDestination [[texture(1)]],
    texture2d<float, access::sample> transferTextureCh1 [[texture(2)]],
    texture2d<float, access::sample> transferTextureCh2 [[texture(3)]],
    texture2d<float, access::sample> transferTextureCh3 [[texture(4)]],
    texture2d<float, access::sample> transferTextureCh4 [[texture(5)]],
    constant float4 &channelWeights [[buffer(0)]],
    constant float &opacityThreshold [[buffer(1)]],
    constant float4 &intensityParameters [[buffer(2)]],
    constant float2 &densityRange [[buffer(3)]],
    constant int2 &gateRange [[buffer(4)]],
    constant int &useHuGate [[buffer(5)]],
    device atomic_uint &containsTransparentBlocks [[buffer(6)]],
    constant uint &collectSkippingFlag [[buffer(7)]],
    uint3 gid [[thread_position_in_grid]])
{
    const uint width = visibilityDestination.get_width();
    const uint height = visibilityDestination.get_height();
    const uint depth = visibilityDestination.get_depth();
    if (gid.x >= width || gid.y >= height || gid.z >= depth) {
        return;
    }

    const half2 minMaxHalf = minMaxSource.read(gid).rg;
    const float lo = float(minMaxHalf.r);
    const float hi = float(minMaxHalf.g);
    constexpr sampler transferSampler(coord::normalized,
                                      address::clamp_to_edge,
                                      filter::linear);

    bool transparent = true;
    const uint sampleCount = lo >= hi ? 1 : 5;
    const float samplePositions[5] = {0.0f, 0.25f, 0.5f, 0.75f, 1.0f};
    for (uint sampleIndex = 0; sampleIndex < sampleCount && transparent; ++sampleIndex) {
        const float density = mix(lo, hi, samplePositions[sampleIndex]);
        const float huValue = intensityParameters.x + density * intensityParameters.y;
        const float densityWindow = clamp((huValue - intensityParameters.z) * intensityParameters.w,
                                          0.0f,
                                          1.0f);
        if (densityWindow <= densityRange.x || densityWindow > densityRange.y) {
            continue;
        }
        if (useHuGate != 0 && (huValue < float(gateRange.x) || huValue > float(gateRange.y))) {
            continue;
        }

        const float2 coordinate = float2(density, 0.5f);
        float combinedAlpha = 0.0f;
        if (channelWeights.x > 0.0001f) {
            combinedAlpha += transferTextureCh1.sample(transferSampler, coordinate).a * channelWeights.x;
        }
        if (channelWeights.y > 0.0001f) {
            combinedAlpha += transferTextureCh2.sample(transferSampler, coordinate).a * channelWeights.y;
        }
        if (channelWeights.z > 0.0001f) {
            combinedAlpha += transferTextureCh3.sample(transferSampler, coordinate).a * channelWeights.z;
        }
        if (channelWeights.w > 0.0001f) {
            combinedAlpha += transferTextureCh4.sample(transferSampler, coordinate).a * channelWeights.w;
        }
        if (clamp(combinedAlpha, 0.0f, 1.0f) * densityWindow > opacityThreshold) {
            transparent = false;
        }
    }

    visibilityDestination.write(half4(transparent ? 1.0h : 0.0h), gid);
    if (collectSkippingFlag != 0 && transparent) {
        atomic_store_explicit(&containsTransparentBlocks, 1u, memory_order_relaxed);
    }
}
