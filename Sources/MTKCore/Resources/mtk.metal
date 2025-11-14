// Based on: https://github.com/mlavik1/UnityVolumeRendering (ported to Metal/SceneKit)
// Additions by Thales: gating for projections, optional TF on projections,
// real dimension for gradient magnitude, and minor fixes.

#include <metal_stdlib>
#include "MPR/Shared.metal"

using namespace metal;

// Deve casar byte-a-byte com VolumeCubeMaterial.Uniforms (Swift).
struct Uniforms {
    int   isLightingOn;
    int   isBackwardOn;

    int   method;              // 0=surf, 1=dvr, 2=mip, 3=minip, 4=avg
    int   renderingQuality;

    int   voxelMinValue;
    int   voxelMaxValue;
    int   datasetMinValue;
    int   datasetMaxValue;

    // Gating (projections)
    float densityFloor;
    float densityCeil;
    int   gateHuMin; int gateHuMax; int useHuGate;

    // Dimensão real do volume (para gradiente correto)
    int   dimX;
    int   dimY;
    int   dimZ;

    int   useTFProj;           // aplica TF nas projeções?

    // padding/alinhamento
    int   _pad0;
    int   _pad1;
    int   _pad2;
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

// --------------------------- Surface Rendering ---------------------------

FragmentOut
surface_rendering(VertexOut in,
                  SCNSceneBuffer scn_frame,
                  NodeBuffer scn_node,
                  int quality,
                  short windowMin, short windowMax,
                  short dataMin, short dataMax,
                  bool isLightingOn,
                  float3 dimension,   // NOVO: dimensão real
                  texture3d<short, access::sample> volume,
                  texture2d<float, access::sample> transferColor)
{
    FragmentOut out;

    VR::RayInfo ray = VR::getRayFront2Back(in.localPosition, scn_node, scn_frame);
    VR::RaymarchInfo raymarch = VR::initRayMarch(ray, quality);
    float3 lightDir = normalize(Unity::ObjSpaceViewDir(float4(0.0f), scn_node, scn_frame));

    // pequeno jitter para reduzir banding
    ray.startPosition = ray.startPosition + (2.0 * ray.direction / raymarch.numSteps);

    float4 col = float4(0);
    for (int iStep = 0; iStep < raymarch.numSteps; iStep++)
    {
        const float t = iStep * raymarch.numStepsRecip;
        const float3 currPos = Util::lerp(ray.startPosition, ray.endPosition, t);

        if (currPos.x < 0 || currPos.x >= 1 ||
            currPos.y < 0 || currPos.y > 1 ||
            currPos.z < 0 || currPos.z > 1)
            continue;

        short hu = VR::getDensity(volume, currPos);
        float densityWindow = Util::normalize(hu, windowMin, windowMax);

        if (densityWindow > 0.2f) // limiar de superfície (ajustável no futuro)
        {
            float3 gradient = VR::calGradient(volume, currPos, dimension);
            float3 normal = normalize(gradient);
            float densityDataset = Util::normalize(hu, dataMin, dataMax);
            col = VR::getTfColour(transferColor, clamp(densityDataset, 0.0f, 1.0f));
            if (isLightingOn)
                col.rgb = Util::calculateLighting(col.rgb, normal, lightDir, ray.direction, 0.15f);
            col.a = 1;
            break;
        }
    }

    out.color = col;
    return out;
}

// --------------------------- Direct Volume Rendering ---------------------------

FragmentOut
direct_volume_rendering(VertexOut in,
                        SCNSceneBuffer scn_frame,
                        NodeBuffer scn_node,
                        int quality,
                        int windowMinValue, int windowMaxValue,
                        int dataMinValue, int dataMaxValue,
                        bool isLightingOn, bool isBackwardOn,
                        float3 dimension,   // NOVO: dimensão real
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
            currPos.y < 0 || currPos.y > 1 ||
            currPos.z < 0 || currPos.z > 1)
            break;

        short hu = VR::getDensity(dicom, currPos);
        float densityWindow = Util::normalize(hu,
                                              (short)windowMinValue,
                                              (short)windowMaxValue);
        float densityDataset = Util::normalize(hu,
                                               (short)dataMinValue,
                                               (short)dataMaxValue);

        densityWindow = clamp(densityWindow, 0.0f, 1.0f);
        float4 src = VR::getTfColour(tfTable, clamp(densityDataset, 0.0f, 1.0f));
        float3 gradient = VR::calGradient(dicom, currPos, dimension);
        float3 normal   = normalize(gradient);
        float3 direction = isBackwardOn ? ray.direction : -ray.direction;

        if (isLightingOn)
            src.rgb = Util::calculateLighting(src.rgb, normal, lightDir, direction, 0.3f);

        if (densityWindow < 0.1f)
            src.a = 0.0f;
        else
            src.a *= densityWindow;

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

// --------------------------- Projections (MIP / MinIP / AIP) ---------------------------

FragmentOut
maximum_intensity_projection(VertexOut in,
                             SCNSceneBuffer scn_frame,
                             NodeBuffer scn_node,
                             int quality,
                             short windowMin, short windowMax,
                             short dataMin, short dataMax,
                             float densityFloor, float densityCeil,
                             float3 dimension,
                             bool useTFProj,
                             int gateHuMin, int gateHuMax, int useHuGate,
                             texture3d<short, access::sample> volume,
                             texture2d<float, access::sample> tfTable)
{
    FragmentOut out;
    VR::RayInfo ray = VR::getRayBack2Front(in.localPosition, scn_node, scn_frame);
    VR::RaymarchInfo raymarch = VR::initRayMarch(ray, quality);

    float maxDensityWindow = 0.0f;
    float maxDensityDataset = 0.0f;
    bool  hit = false;

    for (int iStep = 0; iStep < raymarch.numSteps; iStep++)
    {
        const float t = iStep * raymarch.numStepsRecip;
        const float3 currPos = Util::lerp(ray.startPosition, ray.endPosition, t);

        if (currPos.x < -1e-6 || currPos.x > 1+1e-6 ||
            currPos.y < -1e-6 || currPos.y > 1+1e-6 ||
            currPos.z < -1e-6 || currPos.z > 1+1e-6)
            break;

        short hu = VR::getDensity(volume, currPos);
        float densityWindow = Util::normalize(hu, windowMin, windowMax);
        float densityDataset = Util::normalize(hu, dataMin, dataMax);
        densityWindow = clamp(densityWindow, 0.0f, 1.0f);
        densityDataset = clamp(densityDataset, 0.0f, 1.0f);

        bool pass;
        if (useHuGate != 0) {
            pass = (hu >= gateHuMin) && (hu <= gateHuMax);
        } else {
            pass = (densityWindow >= densityFloor) && (densityWindow <= densityCeil);
        }
        if (!pass) continue;

        if (densityWindow > maxDensityWindow) {
            maxDensityWindow = densityWindow;
            maxDensityDataset = densityDataset;
        }
        hit = true;
    }

    float valWindow = hit ? maxDensityWindow : 0.0f;
    float valDataset = hit ? maxDensityDataset : 0.0f;
    out.color = useTFProj ? VR::getTfColour(tfTable, valDataset) : float4(valWindow);
    return out;
}

FragmentOut
minimum_intensity_projection(VertexOut in,
                             SCNSceneBuffer scn_frame,
                             NodeBuffer scn_node,
                             int quality,
                             short windowMin, short windowMax,
                             short dataMin, short dataMax,
                             float densityFloor, float densityCeil,
                             float3 dimension,
                             bool useTFProj,
                             int gateHuMin, int gateHuMax, int useHuGate,
                             texture3d<short, access::sample> volume,
                             texture2d<float, access::sample> tfTable)
{
    FragmentOut out;

    VR::RayInfo ray = VR::getRayBack2Front(in.localPosition, scn_node, scn_frame);
   VR::RaymarchInfo raymarch = VR::initRayMarch(ray, quality);

    float minDensityWindow = 1.0f;
    float minDensityDataset = 1.0f;
    bool  hit = false;

    for (int iStep = 0; iStep < raymarch.numSteps; iStep++)
    {
        const float t = iStep * raymarch.numStepsRecip;
        const float3 currPos = Util::lerp(ray.startPosition, ray.endPosition, t);

        if (currPos.x < -1e-6 || currPos.x > 1+1e-6 ||
            currPos.y < -1e-6 || currPos.y > 1+1e-6 ||
            currPos.z < -1e-6 || currPos.z > 1+1e-6)
            break;

        short hu = VR::getDensity(volume, currPos);
        float densityWindow = Util::normalize(hu, windowMin, windowMax);
        float densityDataset = Util::normalize(hu, dataMin, dataMax);
        densityWindow = clamp(densityWindow, 0.0f, 1.0f);
        densityDataset = clamp(densityDataset, 0.0f, 1.0f);
        bool pass;
        if (useHuGate != 0) {
            pass = (hu >= gateHuMin) && (hu <= gateHuMax);
        } else {
            pass = (densityWindow >= densityFloor) && (densityWindow <= densityCeil);
        }
        if (!pass) continue;

        if (densityWindow < minDensityWindow) {
            minDensityWindow = densityWindow;
            minDensityDataset = densityDataset;
        }
        hit = true;
    }

    float valWindow = hit ? minDensityWindow : 0.0f;
    float valDataset = hit ? minDensityDataset : 0.0f;
    out.color = useTFProj ? VR::getTfColour(tfTable, valDataset) : float4(valWindow);
    return out;
}

FragmentOut
average_intensity_projection(VertexOut in,
                             SCNSceneBuffer scn_frame,
                             NodeBuffer scn_node,
                             int quality,
                             short windowMin, short windowMax,
                             short dataMin, short dataMax,
                             float densityFloor, float densityCeil,
                             float3 dimension,
                             bool useTFProj,
                             int gateHuMin, int gateHuMax, int useHuGate,
                             texture3d<short, access::sample> volume,
                             texture2d<float, access::sample> tfTable)
{
    FragmentOut out;

    VR::RayInfo ray = VR::getRayBack2Front(in.localPosition, scn_node, scn_frame);
    VR::RaymarchInfo raymarch = VR::initRayMarch(ray, quality);

    float accWindow = 0.0f;
    float accDataset = 0.0f;
    int   cnt = 0;

    for (int iStep = 0; iStep < raymarch.numSteps; iStep++)
    {
        const float t = iStep * raymarch.numStepsRecip;
        const float3 currPos = Util::lerp(ray.startPosition, ray.endPosition, t);

        if (currPos.x < -1e-6 || currPos.x > 1+1e-6 ||
            currPos.y < -1e-6 || currPos.y > 1+1e-6 ||
            currPos.z < -1e-6 || currPos.z > 1+1e-6)
            break;

        short hu = VR::getDensity(volume, currPos);
        float densityWindow = Util::normalize(hu, windowMin, windowMax);
        float densityDataset = Util::normalize(hu, dataMin, dataMax);
        densityWindow = clamp(densityWindow, 0.0f, 1.0f);
        densityDataset = clamp(densityDataset, 0.0f, 1.0f);
        bool pass;
        if (useHuGate != 0) {
            pass = (hu >= gateHuMin) && (hu <= gateHuMax);
        } else {
            pass = (densityWindow >= densityFloor) && (densityWindow <= densityCeil);
        }
        if (!pass) continue;

        accWindow += densityWindow;
        accDataset += densityDataset;
        cnt += 1;
    }

    float valWindow = (cnt > 0) ? (accWindow / float(cnt)) : 0.0f;
    float valDataset = (cnt > 0) ? (accDataset / float(cnt)) : 0.0f;
    out.color = useTFProj ? VR::getTfColour(tfTable, valDataset) : float4(valWindow);
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
    int  datasetMin   = uniforms.datasetMinValue;
    int  datasetMax   = uniforms.datasetMaxValue;
    bool isLightingOn = (uniforms.isLightingOn != 0);
    bool isBackwardOn = (uniforms.isBackwardOn != 0);

    float3 dim = float3(uniforms.dimX, uniforms.dimY, uniforms.dimZ);

    switch (uniforms.method)
    {
        case 0: // Surface
            return surface_rendering(in, scn_frame, scn_node,
                                     quality,
                                     (short)minValue, (short)maxValue,
                                     (short)datasetMin, (short)datasetMax,
                                     isLightingOn,
                                     dim,
                                     dicom, transferColor);

        case 1: // DVR
            return direct_volume_rendering(in, scn_frame, scn_node,
                                           quality,
                                           minValue, maxValue,
                                           datasetMin, datasetMax,
                                           isLightingOn, isBackwardOn,
                                           dim,
                                           dicom, transferColor);

        case 2: // MIP
            return maximum_intensity_projection(in, scn_frame, scn_node,
                                                quality,
                                                (short)minValue, (short)maxValue,
                                                (short)datasetMin, (short)datasetMax,
                                                uniforms.densityFloor, uniforms.densityCeil,
                                                dim,
                                                (uniforms.useTFProj != 0),
                                                uniforms.gateHuMin, uniforms.gateHuMax, uniforms.useHuGate,
                                                dicom, transferColor);

        case 3: // MinIP
            return minimum_intensity_projection(in, scn_frame, scn_node,
                                                quality,
                                                (short)minValue, (short)maxValue,
                                                (short)datasetMin, (short)datasetMax,
                                                uniforms.densityFloor, uniforms.densityCeil,
                                                dim,
                                                (uniforms.useTFProj != 0),
                                                uniforms.gateHuMin, uniforms.gateHuMax, uniforms.useHuGate,
                                                dicom, transferColor);

        case 4: // AIP (Mean)
            return average_intensity_projection(in, scn_frame, scn_node,
                                                quality,
                                                (short)minValue, (short)maxValue,
                                                (short)datasetMin, (short)datasetMax,
                                                uniforms.densityFloor, uniforms.densityCeil,
                                                dim,
                                                (uniforms.useTFProj != 0),
                                                uniforms.gateHuMin, uniforms.gateHuMax, uniforms.useHuGate,
                                                dicom, transferColor);
        default:
            // fallback para MIP
            return maximum_intensity_projection(in, scn_frame, scn_node,
                                                quality,
                                                (short)minValue, (short)maxValue,
                                                (short)datasetMin, (short)datasetMax,
                                                uniforms.densityFloor, uniforms.densityCeil,
                                                dim,
                                                (uniforms.useTFProj != 0),
                                                uniforms.gateHuMin, uniforms.gateHuMax, uniforms.useHuGate,
                                                dicom, transferColor);
    }
}
