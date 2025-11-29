#ifndef volume_rendering_helpers_metal
#define volume_rendering_helpers_metal

#include <metal_stdlib>
#include "../MPR/Shared.metal"
#include "volume_rendering_types.metal"

using namespace metal;

namespace VolumeCompute {

enum VolumeFilter : uint {
    VolumeFilterLinear   = 0,
    VolumeFilterCubic    = 1,
    VolumeFilterLanczos2 = 2,
};

constant uint kToneSampleCount = 2551u;
constant float kToneLookupScale = 2550.0f;
[[maybe_unused]] constant ushort OPTION_ADAPTIVE = 1u << 2;
[[maybe_unused]] constant ushort OPTION_DEBUG_DENSITY = 1u << 3;

// ---------- Sampling filters (Phase 4) ----------

[[maybe_unused]] static inline float catmullRomWeight(float x) {
    x = fabs(x);
    return (x <= 1.0f)
        ? (1.5f * x - 2.5f) * x * x + 1.0f
        : ((-0.5f * x + 2.5f) * x - 4.0f) * x + 2.0f;
}

[[maybe_unused]] static inline float lanczos2Weight(float x) {
    x = fabs(x);
    if (x >= 2.0f) return 0.0f;
    if (x < 1.0e-5f) return 1.0f;
    const float pix = 3.14159265f * x;
    return (sin(pix) / pix) * (sin(0.5f * pix) / (0.5f * pix));
}

[[maybe_unused]] static inline float sampleCubic(texture3d<float, access::sample> tex,
                                                 sampler smp,
                                                 float3 uvw)
{
    float3 dim = float3(tex.get_width(), tex.get_height(), tex.get_depth());
    float3 pos = uvw * dim - 0.5f;
    int3 base = int3(floor(pos));
    float3 t = pos - float3(base);

    float wx[4];
    float wy[4];
    float wz[4];
    for (int i = 0; i < 4; ++i) {
        wx[i] = catmullRomWeight((float(i - 1) - t.x));
        wy[i] = catmullRomWeight((float(i - 1) - t.y));
        wz[i] = catmullRomWeight((float(i - 1) - t.z));
    }

    float accum = 0.0f;
    float weightSum = 0.0f;
    for (int dz = 0; dz < 4; ++dz)
    for (int dy = 0; dy < 4; ++dy)
    for (int dx = 0; dx < 4; ++dx) {
        int3 p = clamp(base + int3(dx - 1, dy - 1, dz - 1), int3(0), int3(dim) - 1);
        float3 tc = (float3(p) + 0.5f) / dim;
        float w = wx[dx] * wy[dy] * wz[dz];
        accum += w * tex.sample(smp, tc).r;
        weightSum += w;
    }
    return (weightSum != 0.0f) ? accum / weightSum : accum;
}

[[maybe_unused]] static inline float sampleLanczos2(texture3d<float, access::sample> tex,
                                                   sampler smp,
                                                   float3 uvw)
{
    float3 dim = float3(tex.get_width(), tex.get_height(), tex.get_depth());
    float3 pos = uvw * dim;
    int3 base = int3(floor(pos));
    float3 t = pos - float3(base);

    float wx[4];
    float wy[4];
    float wz[4];
    for (int i = 0; i < 4; ++i) {
        wx[i] = lanczos2Weight((float(i - 1) - t.x));
        wy[i] = lanczos2Weight((float(i - 1) - t.y));
        wz[i] = lanczos2Weight((float(i - 1) - t.z));
    }

    float accum = 0.0f;
    float weightSum = 0.0f;
    for (int dz = 0; dz < 4; ++dz)
    for (int dy = 0; dy < 4; ++dy)
    for (int dx = 0; dx < 4; ++dx) {
        int3 p = clamp(base + int3(dx - 1, dy - 1, dz - 1), int3(0), int3(dim) - 1);
        float3 tc = (float3(p) + 0.5f) / dim;
        float w = wx[dx] * wy[dy] * wz[dz];
        accum += w * tex.sample(smp, tc).r;
        weightSum += w;
    }
    return (weightSum != 0.0f) ? accum / weightSum : accum;
}

[[maybe_unused]] static inline float sampleDensity(texture3d<float, access::sample> volume,
                                                   sampler smp,
                                                   float3 coord,
                                                   constant VolumeUniforms& uniforms)
{
    switch ((VolumeFilter)uniforms.samplingMethod) {
        case VolumeFilterCubic:
            return sampleCubic(volume, smp, coord);
        case VolumeFilterLanczos2:
            return sampleLanczos2(volume, smp, coord);
        default:
            return VR::getDensity(volume, coord);
    }
}

[[maybe_unused]] static inline float3 computeRayDirection(float3 cameraLocal01,
                                                          float3 pixelLocal01)
{
    return normalize(pixelLocal01 - cameraLocal01);
}

// Gradient with physical spacing scaling
[[maybe_unused]] static inline float3 computeSpacingAwareGradient(texture3d<float, access::sample> volume,
                                                                  float3 coord,
                                                                  float3 dimension,
                                                                  float3 spacing)
{
    float3 g = VR::calGradient(volume, coord, dimension);
    // Avoid division by zero
    float sx = spacing.x > 1.0e-6 ? spacing.x : 1.0f;
    float sy = spacing.y > 1.0e-6 ? spacing.y : 1.0f;
    float sz = spacing.z > 1.0e-6 ? spacing.z : 1.0f;
    g.x /= sx;
    g.y /= sy;
    g.z /= sz;
    return g;
}

// Adaptive step size based on gradient magnitude
[[maybe_unused]] static inline float computeAdaptiveStepScale(float gradMag,
                                                              constant RenderingParameters& params)
{
    float scale = 1.0f;
    if (params.adaptiveGradientScale > 0.0f) {
        scale = 1.0f / (1.0f + gradMag * params.adaptiveGradientScale);
    }
    // Expand step in flat regions when enabled
    if (params.adaptiveFlatBoost > 1.0f &&
        params.adaptiveFlatThreshold > 0.0f &&
        gradMag <= params.adaptiveFlatThreshold) {
        scale = max(scale, params.adaptiveFlatBoost);
    }
    scale = clamp(scale, params.adaptiveStepMinScale, params.adaptiveStepMaxScale);
    return scale;
}

// Selects per-mode early-exit threshold; falls back to params.earlyTerminationThreshold
[[maybe_unused]] static inline float getEarlyExitThreshold(constant VolumeUniforms& material,
                                                           constant RenderingParameters& params)
{
    // method: 1=FTB, 2=MIP, 3=MinIP, 4=AvgIP
    if (material.method == 2 || material.method == 3) {
        return clamp(material.earlyExitMIP, 0.0f, 0.9999f);
    }
    if (material.method == 4) {
        return clamp(material.earlyExitAvgIP, 0.0f, 0.9999f);
    }
    return clamp(material.earlyExitFTB, 0.0f, 0.9999f);
}

// Determines whether to skip empty space based on alpha and optional gates
[[maybe_unused]] static inline bool shouldSkipEmptySpace(float sampleAlpha,
                                                         float gradientMagnitude,
                                                         constant RenderingParameters& params)
{
    if (sampleAlpha >= params.zeroRunThreshold) {
        return false;
    }
    if (params.emptySpaceGradientThreshold > 0.0f &&
        gradientMagnitude > params.emptySpaceGradientThreshold) {
        return false;
    }
    // Optional density gate currently unused (reserved field)
    return true;
}

[[maybe_unused]] static inline bool shouldSkipByOccupancy(constant RenderingParameters& params,
                                                          float3 texCoord,
                                                          texture3d<half, access::sample> occupancyTexture)
{
    // Placeholder stub: occupancy/min-max skipping not yet wired to resources.
    if (params.material.occupancySkipEnabled == 0 && params.material.minMaxSkipEnabled == 0) {
        return false;
    }
    if (!occupancyTexture.get_width()) { return false; }
    float3 tc = clamp(texCoord, float3(0.0f), float3(1.0f));
    float2 minMax = (float2)occupancyTexture.sample(sampler3d, tc).rg;
    float densityThreshold = params.emptySpaceDensityThreshold;

    if (params.material.occupancySkipEnabled != 0 && minMax.y < densityThreshold) {
        return true;
    }
    if (params.material.minMaxSkipEnabled != 0 && (minMax.y - minMax.x) < 1.0e-4f) {
        return true;
    }
    return false;
}

/// Transform world coordinates (mm, LPS) to texture coordinates [0,1]^3 using SCTC matrix
[[maybe_unused]] static inline float3 worldToTexture(float3 worldPos,
                                                     constant CameraUniforms& camera)
{
    float4 worldPos4 = float4(worldPos, 1.0f);
    float4 texPos4 = camera.worldToTextureMatrix * worldPos4;
    return texPos4.xyz / texPos4.w;
}

/// Transform texture coordinates [0,1]^3 to world coordinates (mm, LPS) using inverse SCTC
[[maybe_unused]] static inline float3 textureToWorld(float3 texPos,
                                                     constant CameraUniforms& camera)
{
    float4 texPos4 = float4(texPos, 1.0f);
    float4 worldPos4 = camera.textureToWorldMatrix * texPos4;
    return worldPos4.xyz / worldPos4.w;
}

static inline float4 sampleTransfer(texture2d<float, access::sample> transfer,
                                    float density,
                                    float gradientMag,
                                    bool useTransfer,
                                    bool useDualParameterTF)
{
    if (!useTransfer) {
        return float4(density, density, density, density);
    }
    if (useDualParameterTF) {
        return VR::getTfColour(transfer, density, gradientMag);
    }
    return VR::getTfColour(transfer, density);
}

static inline float sampleTone(device float *toneBuffer,
                               float density)
{
    if (toneBuffer == nullptr) {
        return 1.0f;
    }
    float lookup = clamp(density * kToneLookupScale, 0.0f, float(kToneSampleCount - 1));
    uint index = (uint)round(lookup);
    return clamp(toneBuffer[index], 0.0f, 1.0f);
}

[[maybe_unused]] static inline bool gateDensity(float density,
                                                constant RenderingParameters& params,
                                                short hu)
{
    constant VolumeUniforms& uniforms = params.material;
    if (uniforms.method == 2 || uniforms.method == 3 || uniforms.method == 4) {
        if (density < uniforms.densityFloor || density > uniforms.densityCeil) {
            return true;
        }
        if (uniforms.useHuGate != 0 &&
            (hu < uniforms.gateHuMin || hu > uniforms.gateHuMax)) {
            return true;
        }
    }
    return false;
}

static inline float4 sampleChannel(texture2d<float, access::sample> transfer,
                                   device float *toneBuffer,
                                   float density,
                                   float gradientMag,
                                   bool useTransfer,
                                   bool useDualParameterTF,
                                   float weight)
{
    if (weight <= 0.0001f) {
        return float4(0.0f);
    }
    float tone = sampleTone(toneBuffer, density);
    float4 colour = sampleTransfer(transfer, density, gradientMag, useTransfer, useDualParameterTF);
    colour.rgb *= weight;
    colour.a = clamp(colour.a * weight * tone, 0.0f, 1.0f);
    return clamp(colour, float4(0.0f), float4(1.0f));
}

[[maybe_unused]] static inline float4 compositeChannels(constant RenderingArguments& args,
                                                        constant RenderingParameters& params,
                                                        float density,
                                                        float gradientMag,
                                                        bool useTransfer)
{
    const float4 weights = params.intensityRatio;
    const bool useDualTF = (params.material.dualParameterTFEnabled != 0);

    float4 channels[4];
    channels[0] = sampleChannel(args.transferTextureCh1, args.toneBufferCh1, density, gradientMag, useTransfer, useDualTF, weights.x);
    channels[1] = sampleChannel(args.transferTextureCh2, args.toneBufferCh2, density, gradientMag, useTransfer, useDualTF, weights.y);
    channels[2] = sampleChannel(args.transferTextureCh3, args.toneBufferCh3, density, gradientMag, useTransfer, useDualTF, weights.z);
    channels[3] = sampleChannel(args.transferTextureCh4, args.toneBufferCh4, density, gradientMag, useTransfer, useDualTF, weights.w);

    float alpha = 0.0f;
    float3 premult = float3(0.0f);

    for (uint i = 0; i < 4; ++i) {
        const float channelAlpha = channels[i].a;
        if (channelAlpha <= 0.0f) {
            continue;
        }
        const float3 channelColor = clamp(channels[i].rgb, float3(0.0f), float3(1.0f));
        premult += channelColor * channelAlpha;
        alpha = clamp(alpha + channelAlpha, 0.0f, 1.0f);
        if (alpha >= 0.9999f) {
            alpha = 0.9999f;
        }
    }

    if (alpha <= 1e-5f) {
        return float4(0.0f);
    }

    float3 colour = premult / max(alpha, 1e-5f);
    colour = clamp(colour, float3(0.0f), float3(1.0f));
    return float4(colour, clamp(alpha, 0.0f, 1.0f));
}

struct ClipSampleContext {
    float3 centeredCoordinate;
    float3 orientedCoordinate;
};

static inline float4 normalizeQuaternionSafe(float4 q) {
    float lenSq = dot(q, q);
    if (lenSq <= 1.0e-8f) {
        return float4(0.0f, 0.0f, 0.0f, 1.0f);
    }
    float invLen = rsqrt(lenSq);
    return q * invLen;
}

[[maybe_unused]] static inline ClipSampleContext prepareClipSample(float3 texCoordinate,
                                                                   constant RenderingParameters &params)
{
    ClipSampleContext context;
    context.centeredCoordinate = texCoordinate - float3(0.5f);
    float4 clipQuaternion = normalizeQuaternionSafe(params.clipBoxQuaternion);
    float4 clipQuaternionInv = quatInv(clipQuaternion);
    float3 rotated = quatMul(clipQuaternionInv, context.centeredCoordinate);
    context.orientedCoordinate = rotated + float3(0.5f);
    return context;
}

[[maybe_unused]] static inline bool isOutsideTrimBounds(float3 orientedCoordinate,
                                                        constant RenderingParameters &params)
{
    return orientedCoordinate.x < params.trimXMin || orientedCoordinate.x > params.trimXMax ||
           orientedCoordinate.y < params.trimYMin || orientedCoordinate.y > params.trimYMax ||
           orientedCoordinate.z < params.trimZMin || orientedCoordinate.z > params.trimZMax;
}

[[maybe_unused]] static inline bool isClippedByPlanes(thread const ClipSampleContext &context,
                                                      constant RenderingParameters &params)
{
    float4 planes[3] = { params.clipPlane0, params.clipPlane1, params.clipPlane2 };
    for (uint i = 0; i < 3; ++i) {
        float3 normal = planes[i].xyz;
        if (all(normal == float3(0.0f))) {
            continue;
        }
        float signedDistance = dot(context.centeredCoordinate, normal) + planes[i].w;
        if (signedDistance > 0.0f) {
            return true;
        }
    }
    return false;
}

} 

#endif
