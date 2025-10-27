// Based on: https://github.com/mlavik1/UnityVolumeRendering (ported to Metal/SceneKit)
// Additions by Thales: gating for projections, optional TF on projections,
// real dimension for gradient magnitude, and minor fixes.

#include <metal_stdlib>
#include "../MPR/Shared.metal"

using namespace metal;

// Deve casar byte-a-byte com VolumeCubeMaterial.Uniforms (Swift).
struct Uniforms {
    int   isLightingOn;
    int   isBackwardOn;

    int   method;              // 0=dvr, 1=mip, 2=minip, 3=avg
    int   renderingQuality;

    int   voxelMinValue;
    int   voxelMaxValue;

    // Gating (projections)
    float densityFloor;
    float densityCeil;
    int   gateHuMin; int gateHuMax; int useHuGate;

    // Dimensão real do volume (para gradiente correto)
    int   dimX;
    int   dimY;
    int   dimZ;
    int   useTFProj;           // aplica TF nas projeções?

    float tfCoordMin;
    float tfCoordMax;
    int   _pad0;
    int   _pad1;
};

struct VertexIn {
    float3 position  [[attribute(SCNVertexSemanticPosition)]];
    float3 normal    [[attribute(SCNVertexSemanticNormal)]];
    float4 color     [[attribute(SCNVertexSemanticColor)]];
    float2 uv        [[attribute(SCNVertexSemanticTexcoord0)]];
};

struct VertexOut {
    float4 position [[position]];
    float3 localPosition;
    float3 normal;
    float2 uv;
};

struct FragmentOut {
    float4 color [[color(0)]];
    // float depth [[depth(any)]]; // opcional no futuro
};

vertex VertexOut
volume_vertex(VertexIn in [[stage_in]],
              constant NodeBuffer& scn_node [[buffer(1)]])
{
    VertexOut out;
    out.position      = Unity::ObjectToClipPos(float4(in.position, 1.0f), scn_node);
    out.uv            = in.uv;
    out.normal        = Unity::ObjectToWorldNormal(in.normal, scn_node);
    out.localPosition = in.position;
    return out;
}

// --------------------------- Direct Volume Rendering ---------------------------

FragmentOut
direct_volume_rendering(VertexOut in,
                        SCNSceneBuffer scn_frame,
                        NodeBuffer scn_node,
                        int quality, int minValue, int maxValue,
                        bool isLightingOn, bool isBackwardOn,
                        float3 dimension,   // NOVO: dimensão real
                        float tfCoordMin,
                        float tfCoordMax,
                        texture3d<short, access::sample> dicom,
                        texture2d<float, access::sample> tfTable)
{
    FragmentOut out;

    VR::RayInfo ray = isBackwardOn
        ? VR::getRayBack2Front(in.localPosition, scn_node, scn_frame)
        : VR::getRayFront2Back(in.localPosition, scn_node, scn_frame);

    VR::RaymarchInfo raymarch = VR::initRayMarch(ray, quality);
    float3 lightDir = normalize(Unity::ObjSpaceViewDir(float4(0.0f), scn_node, scn_frame));

    // pequeno jitter
    ray.startPosition = ray.startPosition + (2 * ray.direction / raymarch.numSteps);

    float4 col = float4(0.0f);
    int zeroCount = 0;
    constexpr int ZRUN = 4;
    constexpr int ZSKIP = 3;
    for (int iStep = 0; iStep < raymarch.numSteps; iStep++)
    {
        const float t = iStep * raymarch.numStepsRecip;
        const float3 currPos = Util::lerp(ray.startPosition, ray.endPosition, t);

        if (currPos.x < 0 || currPos.x >= 1 ||
            currPos.y < 0 || currPos.y >= 1 ||
            currPos.z < 0 || currPos.z >= 1)
            break;

        short hu = VR::getDensity(dicom, currPos);
        float density = Util::normalize(hu, (short)minValue, (short)maxValue);

        float tfCoord = mix(tfCoordMin, tfCoordMax, density);
        float3 gradient = VR::calGradient(dicom, currPos, dimension);
        float3 normal   = normalize(gradient);
        float gradientMagnitude = 0.0f;
        const float intensitySpan = float(maxValue - minValue);
        if (intensitySpan > 0.0f) {
            gradientMagnitude = clamp(length(gradient) / intensitySpan, 0.0f, 1.0f);
        }
        float4 src = VR::getTfColour(tfTable,
                                     clamp(tfCoord, 0.0f, 1.0f),
                                     gradientMagnitude);
        float3 direction = isBackwardOn ? ray.direction : -ray.direction;

        if (isLightingOn)
            src.rgb = Util::calculateLighting(src.rgb, normal, lightDir, direction, 0.3f);

        if (density < 0.1f)
            src.a = 0.0f;

        // Empty-space skipping (transparência consecutiva)
        if (src.a < 0.001f) {
            zeroCount++;
            if (zeroCount >= ZRUN) {
                iStep += ZSKIP;
                zeroCount = 0;
                continue;
            }
        } else {
            zeroCount = 0;
        }

        if (isBackwardOn) {
            col.rgb = src.a * src.rgb + (1.0f - src.a) * col.rgb;
            col.a   = src.a + (1.0f - src.a) * col.a;
        } else {
            src.rgb *= src.a;
            col = (1.0f - col.a) * src + col;
        }

        if (col.a > 1)
            break;
    }

    out.color = col;
    return out;
}

// --------------------------- Entry Point ---------------------------

fragment FragmentOut
volume_fragment(VertexOut in [[stage_in]],
                constant SCNSceneBuffer& scn_frame [[buffer(0)]],
                constant NodeBuffer& scn_node [[buffer(1)]],
                constant Uniforms& uniforms [[buffer(4)]],
                texture3d<short, access::sample> dicom [[texture(0)]],
                texture2d<float, access::sample>  transferColor [[texture(3)]])
{
    int  quality      = uniforms.renderingQuality;
    int  minValue     = uniforms.voxelMinValue;
    int  maxValue     = uniforms.voxelMaxValue;
    bool isLightingOn = (uniforms.isLightingOn != 0);
    bool isBackwardOn = (uniforms.isBackwardOn != 0);

    float3 dim = float3(uniforms.dimX, uniforms.dimY, uniforms.dimZ);
    float tfCoordMin = uniforms.tfCoordMin;
    float tfCoordMax = uniforms.tfCoordMax;

    return direct_volume_rendering(in, scn_frame, scn_node,
                                   quality, minValue, maxValue,
                                   isLightingOn, isBackwardOn,
                                   dim,
                                   tfCoordMin,
                                   tfCoordMax,
                                   dicom, transferColor);
}
