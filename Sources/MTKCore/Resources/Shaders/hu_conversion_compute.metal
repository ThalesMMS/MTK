//
//  hu_conversion_compute.metal
//  MTK
//
//  Slice upload kernels for Hounsfield unit conversion into private 3D textures.
//

#include <metal_stdlib>
using namespace metal;

struct HUConversionParams {
    float slope;
    float intercept;
    int minClamp;
    int maxClamp;
    uint sliceIndex;
    uint sliceWidth;
    uint sliceHeight;
    uint _padding;
};

kernel void convertHUSlice(constant short *inputBuffer [[buffer(0)]],
                           texture3d<short, access::write> destination [[texture(0)]],
                           constant HUConversionParams &params [[buffer(1)]],
                           uint3 gid [[thread_position_in_grid]])
{
    if (gid.x >= params.sliceWidth || gid.y >= params.sliceHeight) {
        return;
    }

    uint sourceIndex = gid.y * params.sliceWidth + gid.x;
    int rawValue = int(inputBuffer[sourceIndex]);
    float converted = float(rawValue) * params.slope + params.intercept;
    int clampedValue = clamp(int(round(converted)), params.minClamp, params.maxClamp);
    short outputValue = short(clamp(clampedValue, int(SHRT_MIN), int(SHRT_MAX)));

    destination.write(short4(outputValue, 0, 0, 0), uint3(gid.x, gid.y, params.sliceIndex));
}

kernel void convertHUSliceUnsigned(constant ushort *inputBuffer [[buffer(0)]],
                                   texture3d<short, access::write> destination [[texture(0)]],
                                   constant HUConversionParams &params [[buffer(1)]],
                                   uint3 gid [[thread_position_in_grid]])
{
    if (gid.x >= params.sliceWidth || gid.y >= params.sliceHeight) {
        return;
    }

    uint sourceIndex = gid.y * params.sliceWidth + gid.x;
    int rawValue = int(inputBuffer[sourceIndex]);
    float converted = float(rawValue) * params.slope + params.intercept;
    int clampedValue = clamp(int(round(converted)), params.minClamp, params.maxClamp);
    short outputValue = short(clamp(clampedValue, int(SHRT_MIN), int(SHRT_MAX)));

    destination.write(short4(outputValue, 0, 0, 0), uint3(gid.x, gid.y, params.sliceIndex));
}
