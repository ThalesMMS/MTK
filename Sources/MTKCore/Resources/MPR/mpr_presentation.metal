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
    float viewportZoom;
    float viewportPanX;
    float viewportPanY;
    float _pad1;
};

struct MPRLabelmapOverlayUniforms {
    float opacity;
    float3 _pad0;
    float3 originTexture;
    float _pad1;
    float3 axisUTexture;
    float _pad2;
    float3 axisVTexture;
    float _pad3;
    int flipHorizontal;
    int flipVertical;
    float viewportZoom;
    float viewportPanX;
    float viewportPanY;
    float _pad4;
};

namespace {
inline float normalizeWindow(int value, constant MPRPresentationUniforms& uniforms) {
    int lower = min(uniforms.windowMin, uniforms.windowMax);
    int upper = max(uniforms.windowMin, uniforms.windowMax);
    float span = max(float(upper - lower), 1.0f);
    float normalized = clamp((float(value) - float(lower)) / span, 0.0f, 1.0f);
    return uniforms.invert != 0 ? 1.0f - normalized : normalized;
}

inline float2 normalizedCoordinates(uint2 gid, uint width, uint height) {
    return float2(width > 1 ? float(gid.x) / float(width - 1) : 0.0f,
                  height > 1 ? float(gid.y) / float(height - 1) : 0.0f);
}

inline float2 inverseViewportTransform(float2 outputUV, float zoom, float2 pan) {
    float safeZoom = max(zoom, 1.0f);
    return float2(0.5f) + (outputUV - float2(0.5f) - pan) / safeZoom;
}

inline bool isInUnitSquare(float2 position) {
    return all(position >= 0.0f) && all(position <= 1.0f);
}

inline float2 sourceCoordinates(float2 outputUV,
                                int flipHorizontal,
                                int flipVertical,
                                float viewportZoom,
                                float2 viewportPan) {
    float2 sourceUV = inverseViewportTransform(outputUV, viewportZoom, viewportPan);
    if (!isInUnitSquare(sourceUV)) {
        return sourceUV;
    }
    
    if (flipHorizontal != 0) {
        sourceUV.x = 1.0f - sourceUV.x;
    }
    if (flipVertical != 0) {
        sourceUV.y = 1.0f - sourceUV.y;
    }
    return sourceUV;
}

inline float2 sourceCoordinates(uint2 outputGid,
                                uint width,
                                uint height,
                                constant MPRPresentationUniforms& uniforms) {
    return sourceCoordinates(normalizedCoordinates(outputGid, width, height),
                             uniforms.flipHorizontal,
                             uniforms.flipVertical,
                             uniforms.viewportZoom,
                             float2(uniforms.viewportPanX, uniforms.viewportPanY));
}

inline float2 sourceCoordinates(uint2 outputGid,
                                uint width,
                                uint height,
                                constant MPRLabelmapOverlayUniforms& uniforms) {
    return sourceCoordinates(normalizedCoordinates(outputGid, width, height),
                             uniforms.flipHorizontal,
                             uniforms.flipVertical,
                             uniforms.viewportZoom,
                             float2(uniforms.viewportPanX, uniforms.viewportPanY));
}

inline uint2 nearestPixel(float2 uv, uint width, uint height) {
    return uint2(uint(round(clamp(uv.x, 0.0f, 1.0f) * float(max(width, 1u) - 1u))),
                 uint(round(clamp(uv.y, 0.0f, 1.0f) * float(max(height, 1u) - 1u))));
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

inline bool isInUnitCube(float3 position) {
    return all(position >= 0.0f) && all(position <= 1.0f);
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

    float2 sourceUV = sourceCoordinates(gid,
                                        outputTexture.get_width(),
                                        outputTexture.get_height(),
                                        uniforms);
    if (!isInUnitSquare(sourceUV)) {
        outputTexture.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
        return;
    }

    uint2 sourceGid = nearestPixel(sourceUV, inputTexture.get_width(), inputTexture.get_height());
    int value = int(inputTexture.read(sourceGid).r);
    if (uniforms.bitShift > 0) {
        value >>= uniforms.bitShift;
    }
    float normalized = normalizeWindow(value, uniforms);
    outputTexture.write(presentationColor(normalized, colormapTexture, uniforms), gid);
}

kernel void mprCompositeLabelmapOverlay(texture2d<float, access::read> inputTexture      [[texture(0)]],
                                        texture2d<float, access::write> outputTexture    [[texture(1)]],
                                        texture3d<ushort, access::sample> labelmapTexture [[texture(2)]],
                                        texture2d<float, access::read> colorLUTTexture    [[texture(3)]],
                                        constant MPRLabelmapOverlayUniforms& uniforms     [[buffer(0)]],
                                        uint2 gid                                         [[thread_position_in_grid]]) {
    uint width = outputTexture.get_width();
    uint height = outputTexture.get_height();
    if (gid.x >= width || gid.y >= height) {
        return;
    }

    float4 base = inputTexture.read(gid);
    float opacity = clamp(uniforms.opacity, 0.0f, 1.0f);
    if (opacity <= 0.0f) {
        outputTexture.write(base, gid);
        return;
    }

    float2 sampleUV = sourceCoordinates(gid, width, height, uniforms);
    if (!isInUnitSquare(sampleUV)) {
        outputTexture.write(base, gid);
        return;
    }
    
    float3 labelmapPosition = uniforms.originTexture
                            + sampleUV.x * uniforms.axisUTexture
                            + sampleUV.y * uniforms.axisVTexture;

    if (!isInUnitCube(labelmapPosition)) {
        outputTexture.write(base, gid);
        return;
    }

    constexpr sampler labelmapSampler(coord::normalized,
                                      address::clamp_to_edge,
                                      filter::nearest);
    ushort label = labelmapTexture.sample(labelmapSampler, labelmapPosition).r;
    if (label == 0) {
        outputTexture.write(base, gid);
        return;
    }

    uint labelIndex = uint(label);
    uint lutX = labelIndex & 255u;
    uint lutY = labelIndex >> 8u;
    if (lutX >= colorLUTTexture.get_width() || lutY >= colorLUTTexture.get_height()) {
        outputTexture.write(base, gid);
        return;
    }

    float4 overlay = colorLUTTexture.read(uint2(lutX, lutY));
    float alpha = clamp(overlay.a * opacity, 0.0f, 1.0f);
    if (alpha <= 0.0f) {
        outputTexture.write(base, gid);
        return;
    }

    float3 rgb = mix(base.rgb, overlay.rgb, alpha);
    float outAlpha = base.a + alpha * (1.0f - base.a);
    outputTexture.write(float4(rgb, outAlpha), gid);
}

kernel void mprPresentationUnsigned(texture2d<ushort, access::read> inputTexture  [[texture(0)]],
                                    texture2d<float, access::write> outputTexture [[texture(1)]],
                                    texture2d<float, access::sample> colormapTexture [[texture(2)]],
                                    constant MPRPresentationUniforms& uniforms    [[buffer(0)]],
                                    uint2 gid                                     [[thread_position_in_grid]]) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    float2 sourceUV = sourceCoordinates(gid,
                                        outputTexture.get_width(),
                                        outputTexture.get_height(),
                                        uniforms);
    if (!isInUnitSquare(sourceUV)) {
        outputTexture.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
        return;
    }

    uint2 sourceGid = nearestPixel(sourceUV, inputTexture.get_width(), inputTexture.get_height());
    int value = int(inputTexture.read(sourceGid).r);
    if (uniforms.bitShift > 0) {
        value >>= uniforms.bitShift;
    }
    float normalized = normalizeWindow(value, uniforms);
    outputTexture.write(presentationColor(normalized, colormapTexture, uniforms), gid);
}
