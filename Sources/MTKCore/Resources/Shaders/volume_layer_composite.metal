#include <metal_stdlib>

using namespace metal;

struct VolumeLayerCompositeUniforms {
    float overlayOpacity;
    uint blendMode;
    uint2 padding;
};

kernel void volume_layer_composite(texture2d<float, access::read> baseTexture [[texture(0)]],
                                   texture2d<float, access::read> overlayTexture [[texture(1)]],
                                   texture2d<float, access::write> destinationTexture [[texture(2)]],
                                   constant VolumeLayerCompositeUniforms& uniforms [[buffer(0)]],
                                   uint2 gid [[thread_position_in_grid]])
{
    const uint width = destinationTexture.get_width();
    const uint height = destinationTexture.get_height();
    if (gid.x >= width || gid.y >= height) {
        return;
    }

    const float4 base = clamp(baseTexture.read(gid), float4(0.0f), float4(1.0f));
    float4 overlay = clamp(overlayTexture.read(gid), float4(0.0f), float4(1.0f));
    const float opacity = clamp(uniforms.overlayOpacity, 0.0f, 1.0f);
    overlay.rgb *= opacity;
    overlay.a *= opacity;

    float4 outColor;
    if (uniforms.blendMode == 1u) {
        outColor.rgb = min(base.rgb + overlay.rgb, float3(1.0f));
        outColor.a = min(base.a + overlay.a, 1.0f);
    } else {
        const float oneMinusOverlayAlpha = 1.0f - overlay.a;
        outColor.rgb = overlay.rgb + base.rgb * oneMinusOverlayAlpha;
        outColor.a = overlay.a + base.a * oneMinusOverlayAlpha;
    }

    destinationTexture.write(clamp(outColor, float4(0.0f), float4(1.0f)), gid);
}
