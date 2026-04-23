//
//  mpr_presentation.metal
//  MTK
//
//  Window/level presentation for raw MPR intensity textures.
//

#include <metal_stdlib>

using namespace metal;

struct MPRPresentationUniforms {
    int windowMin;
    int windowMax;
    int invert;
    int useColormap;
    int flipHorizontal;
    int flipVertical;
    int bitShift;
    int _pad0;
};

namespace {
inline float normalizeWindow(int value, constant MPRPresentationUniforms& uniforms) {
    int lower = min(uniforms.windowMin, uniforms.windowMax);
    int upper = max(uniforms.windowMin, uniforms.windowMax);
    float span = max(float(upper - lower), 1.0f);
    float normalized = clamp((float(value) - float(lower)) / span, 0.0f, 1.0f);
    return uniforms.invert != 0 ? 1.0f - normalized : normalized;
}

inline uint2 outputCoordinates(uint2 gid,
                               uint width,
                               uint height,
                               constant MPRPresentationUniforms& uniforms) {
    uint2 outputGid = gid;
    if (uniforms.flipHorizontal != 0) {
        outputGid.x = width - 1 - gid.x;
    }
    if (uniforms.flipVertical != 0) {
        outputGid.y = height - 1 - gid.y;
    }
    return outputGid;
}

inline float4 presentationColor(float normalized,
                                texture2d<float, access::sample> colormap,
                                constant MPRPresentationUniforms& uniforms) {
    if (uniforms.useColormap != 0) {
        constexpr sampler colormapSampler(coord::normalized,
                                          address::clamp_to_edge,
                                          filter::linear);
        float4 color = colormap.sample(colormapSampler, float2(normalized, 0.5f));
        return float4(color.rgb, color.a);
    }
    return float4(normalized, normalized, normalized, 1.0f);
}
}

kernel void mprPresentation(texture2d<short, access::read> inputTexture      [[texture(0)]],
                            texture2d<float, access::write> outputTexture    [[texture(1)]],
                            texture2d<float, access::sample> colormapTexture [[texture(2)]],
                            constant MPRPresentationUniforms& uniforms       [[buffer(0)]],
                            uint2 gid                                        [[thread_position_in_grid]]) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    int value = int(inputTexture.read(gid).r);
    if (uniforms.bitShift > 0) {
        value >>= uniforms.bitShift;
    }
    float normalized = normalizeWindow(value, uniforms);
    uint2 outputGid = outputCoordinates(gid,
                                        outputTexture.get_width(),
                                        outputTexture.get_height(),
                                        uniforms);
    outputTexture.write(presentationColor(normalized, colormapTexture, uniforms), outputGid);
}

kernel void mprPresentationUnsigned(texture2d<ushort, access::read> inputTexture  [[texture(0)]],
                                    texture2d<float, access::write> outputTexture [[texture(1)]],
                                    texture2d<float, access::sample> colormapTexture [[texture(2)]],
                                    constant MPRPresentationUniforms& uniforms    [[buffer(0)]],
                                    uint2 gid                                     [[thread_position_in_grid]]) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    int value = int(inputTexture.read(gid).r);
    if (uniforms.bitShift > 0) {
        value >>= uniforms.bitShift;
    }
    float normalized = normalizeWindow(value, uniforms);
    uint2 outputGid = outputCoordinates(gid,
                                        outputTexture.get_width(),
                                        outputTexture.get_height(),
                                        uniforms);
    outputTexture.write(presentationColor(normalized, colormapTexture, uniforms), outputGid);
}
