//
//  empty_space_compute.metal
//  MTK
//
//  Compute kernels for building min-max mipmap acceleration structures used in
//  empty space skipping during volumetric ray marching. These kernels replace
//  the previous MPS-based approach that incorrectly attempted 2D texture views
//  from 3D textures.
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
kernel void computeMinMaxDownsample(texture3d<half, access::read> source [[texture(0)]],
                                    texture3d<half, access::write> destination [[texture(1)]],
                                    uint3 gid [[thread_position_in_grid]])
{
    uint dstWidth = destination.get_width();
    uint dstHeight = destination.get_height();
    uint dstDepth = destination.get_depth();

    if (gid.x >= dstWidth || gid.y >= dstHeight || gid.z >= dstDepth) {
        return;
    }

    uint3 srcBase = gid * 2;
    uint srcWidth = source.get_width();
    uint srcHeight = source.get_height();
    uint srcDepth = source.get_depth();

    half minVal = half(1.0h);
    half maxVal = half(0.0h);

    // Read 2x2x2 block from source, clamping at edges
    for (uint dz = 0; dz < 2; dz++) {
        for (uint dy = 0; dy < 2; dy++) {
            for (uint dx = 0; dx < 2; dx++) {
                uint3 coord = uint3(
                    min(srcBase.x + dx, srcWidth - 1),
                    min(srcBase.y + dy, srcHeight - 1),
                    min(srcBase.z + dz, srcDepth - 1)
                );
                half2 minMax = source.read(coord).rg;
                minVal = min(minVal, minMax.r);
                maxVal = max(maxVal, minMax.g);
            }
        }
    }

    destination.write(half4(minVal, maxVal, 0.0h, 0.0h), gid);
}
