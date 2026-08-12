//
//  cpr_compute.metal
//  MTK
//
//  Stretched curved planar reformation. Each output column follows one
//  centerline sample and traverses its in-plane perpendicular direction.
//

#include <metal_stdlib>
#include "../Shaders/volume_shader_common.metal"

using namespace metal;

#ifndef MTK_MPR_INTEGER_TEXTURE_READ
#define MTK_MPR_INTEGER_TEXTURE_READ 0
#endif

struct CPRColumnSample {
    float3 centerTexture;
    float _pad0;
    float3 verticalSpanTexture;
    float _pad1;
};

inline bool cprIsInBounds(float3 position) {
    return all(position >= -1e-6f) && all(position <= 1.0f + 1e-6f);
}

inline uint cprNearestIndex(float coordinate, uint count) {
    uint maxIndex = max(count, 1u) - 1u;
    float centeredIndex = coordinate * float(count) - 0.5f;
    return uint(clamp(round(centeredIndex), 0.0f, float(maxIndex)));
}

#if MTK_MPR_INTEGER_TEXTURE_READ
kernel void computeStretchedCPR(texture3d<short, access::read> volume [[texture(0)]],
                                texture2d<short, access::write> output [[texture(1)]],
                                constant CPRColumnSample *columns [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
#else
kernel void computeStretchedCPR(texture3d<short, access::sample> volume [[texture(0)]],
                                texture2d<short, access::write> output [[texture(1)]],
                                constant CPRColumnSample *columns [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
#endif
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }
    float v = output.get_height() > 1
        ? float(gid.y) / float(output.get_height() - 1)
        : 0.5f;
    float3 position = columns[gid.x].centerTexture
        + (v - 0.5f) * columns[gid.x].verticalSpanTexture;
    if (!cprIsInBounds(position)) {
        output.write(short4(0), gid);
        return;
    }
#if MTK_MPR_INTEGER_TEXTURE_READ
    uint3 index = uint3(cprNearestIndex(position.x, volume.get_width()),
                        cprNearestIndex(position.y, volume.get_height()),
                        cprNearestIndex(position.z, volume.get_depth()));
    short value = volume.read(index).r;
#else
    short value = volume.sample(sampler3d, position).r;
#endif
    output.write(short4(value), gid);
}

#if MTK_MPR_INTEGER_TEXTURE_READ
kernel void computeStretchedCPRUnsigned(texture3d<ushort, access::read> volume [[texture(0)]],
                                        texture2d<ushort, access::write> output [[texture(1)]],
                                        constant CPRColumnSample *columns [[buffer(0)]],
                                        uint2 gid [[thread_position_in_grid]]) {
#else
kernel void computeStretchedCPRUnsigned(texture3d<ushort, access::sample> volume [[texture(0)]],
                                        texture2d<ushort, access::write> output [[texture(1)]],
                                        constant CPRColumnSample *columns [[buffer(0)]],
                                        uint2 gid [[thread_position_in_grid]]) {
#endif
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }
    float v = output.get_height() > 1
        ? float(gid.y) / float(output.get_height() - 1)
        : 0.5f;
    float3 position = columns[gid.x].centerTexture
        + (v - 0.5f) * columns[gid.x].verticalSpanTexture;
    if (!cprIsInBounds(position)) {
        output.write(ushort4(0), gid);
        return;
    }
#if MTK_MPR_INTEGER_TEXTURE_READ
    uint3 index = uint3(cprNearestIndex(position.x, volume.get_width()),
                        cprNearestIndex(position.y, volume.get_height()),
                        cprNearestIndex(position.z, volume.get_depth()));
    ushort value = volume.read(index).r;
#else
    ushort value = volume.sample(sampler3d, position).r;
#endif
    output.write(ushort4(value), gid);
}
