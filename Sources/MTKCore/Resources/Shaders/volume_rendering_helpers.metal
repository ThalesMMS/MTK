#ifndef volume_rendering_helpers_metal
#define volume_rendering_helpers_metal

#include <metal_stdlib>
#include "volume_shader_common.metal"
#include "volume_rendering_types.metal"

using namespace metal;

namespace VolumeCompute {

constant uint kToneSampleCount = 2551u;
constant float kToneLookupScale = 2550.0f;
[[maybe_unused]] constant ushort OPTION_ADAPTIVE = 1u << 2;
[[maybe_unused]] constant ushort OPTION_DEBUG_DENSITY = 1u << 3;
[[maybe_unused]] constant ushort OPTION_USE_ACCELERATION = 1u << 4;

[[maybe_unused]] static inline float3 computeRayDirection(float3 cameraLocal01,
                                                          float3 pixelLocal01)
{
    return normalize(pixelLocal01 - cameraLocal01);
}

static inline float4 sampleTransfer(texture2d<float, access::sample> transfer,
                                    float density,
                                    float gradient,
                                    bool useTransfer)
{
    if (!useTransfer) {
        return float4(density, density, density, density);
    }
    return VR::getTfColour(transfer, density, gradient);
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
    if (uniforms.useHuGate != 0 &&
        (hu < uniforms.gateHuMin || hu > uniforms.gateHuMax)) {
        return true;
    }
    if (density < uniforms.densityFloor || density > uniforms.densityCeil) {
        return true;
    }
    return false;
}

static inline float4 sampleChannel(texture2d<float, access::sample> transfer,
                                   device float *toneBuffer,
                                   float density,
                                   float gradient,
                                   bool useTransfer,
                                   float weight)
{
    if (weight <= 0.0001f) {
        return float4(0.0f);
    }
    float tone = sampleTone(toneBuffer, density);
    float4 colour = sampleTransfer(transfer, density, gradient, useTransfer);
    colour.rgb *= weight;
    colour.a = clamp(colour.a * weight * tone, 0.0f, 1.0f);
    return clamp(colour, float4(0.0f), float4(1.0f));
}

[[maybe_unused]] static inline float4 compositeChannels(constant RenderingArguments& args,
                                                        constant RenderingParameters& params,
                                                        float density,
                                                        float gradient,
                                                        bool useTransfer)
{
    const float4 weights = params.intensityRatio;

    float4 channels[4];
    channels[0] = sampleChannel(args.transferTextureCh1, args.toneBufferCh1, density, gradient, useTransfer, weights.x);
    channels[1] = sampleChannel(args.transferTextureCh2, args.toneBufferCh2, density, gradient, useTransfer, weights.y);
    channels[2] = sampleChannel(args.transferTextureCh3, args.toneBufferCh3, density, gradient, useTransfer, weights.z);
    channels[3] = sampleChannel(args.transferTextureCh4, args.toneBufferCh4, density, gradient, useTransfer, weights.w);

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

struct ProjectionState {
    float maxDensityWindow;
    float maxDensityDataset;
    float minDensityWindow;
    float minDensityDataset;
    float sumDensityWindow;
    float sumDensityDataset;
    float3 selectedGradient;
    float3 summedGradient;
    float3 selectedPosition;
    float3 summedPosition;
    uint sampleCount;
    bool hit;
};

[[maybe_unused]] static inline ProjectionState initProjectionState()
{
    ProjectionState state;
    state.maxDensityWindow = 0.0f;
    state.maxDensityDataset = 0.0f;
    state.minDensityWindow = 1.0f;
    state.minDensityDataset = 1.0f;
    state.sumDensityWindow = 0.0f;
    state.sumDensityDataset = 0.0f;
    state.selectedGradient = float3(0.0f);
    state.summedGradient = float3(0.0f);
    state.selectedPosition = float3(0.5f);
    state.summedPosition = float3(0.0f);
    state.sampleCount = 0u;
    state.hit = false;
    return state;
}

[[maybe_unused]] static inline void updateMaxIntensity(thread ProjectionState& state,
                                                       float densityWindow,
                                                       float densityDataset,
                                                       float3 gradient,
                                                       float3 samplePos)
{
    if (!state.hit || densityWindow > state.maxDensityWindow) {
        state.maxDensityWindow = densityWindow;
        state.maxDensityDataset = densityDataset;
        state.selectedGradient = gradient;
        state.selectedPosition = samplePos;
    }
    state.hit = true;
}

[[maybe_unused]] static inline void updateMinIntensity(thread ProjectionState& state,
                                                       float densityWindow,
                                                       float densityDataset,
                                                       float3 gradient,
                                                       float3 samplePos)
{
    if (!state.hit || densityWindow < state.minDensityWindow) {
        state.minDensityWindow = densityWindow;
        state.minDensityDataset = densityDataset;
        state.selectedGradient = gradient;
        state.selectedPosition = samplePos;
    }
    state.hit = true;
}

[[maybe_unused]] static inline void updateAverageIntensity(thread ProjectionState& state,
                                                           float densityWindow,
                                                           float densityDataset,
                                                           float3 gradient,
                                                           float3 samplePos)
{
    state.sumDensityWindow += densityWindow;
    state.sumDensityDataset += densityDataset;
    state.summedGradient += gradient;
    state.summedPosition += samplePos;
    state.sampleCount += 1u;
    state.hit = true;
}

[[maybe_unused]] static inline float projectionDensityWindow(thread const ProjectionState& state,
                                                             int method)
{
    if (!state.hit) {
        return 0.0f;
    }
    if (method == 2) {
        return state.maxDensityWindow;
    }
    if (method == 3) {
        return state.minDensityWindow;
    }
    if (method == 4 && state.sampleCount > 0u) {
        return state.sumDensityWindow / float(state.sampleCount);
    }
    return 0.0f;
}

[[maybe_unused]] static inline float projectionDensityDataset(thread const ProjectionState& state,
                                                              int method)
{
    if (!state.hit) {
        return 0.0f;
    }
    if (method == 2) {
        return state.maxDensityDataset;
    }
    if (method == 3) {
        return state.minDensityDataset;
    }
    if (method == 4 && state.sampleCount > 0u) {
        return state.sumDensityDataset / float(state.sampleCount);
    }
    return 0.0f;
}

[[maybe_unused]] static inline float3 projectionGradient(thread const ProjectionState& state,
                                                         int method)
{
    if (!state.hit) {
        return float3(0.0f);
    }
    if (method == 4 && state.sampleCount > 0u) {
        return state.summedGradient / float(state.sampleCount);
    }
    return state.selectedGradient;
}

[[maybe_unused]] static inline float3 projectionPosition(thread const ProjectionState& state,
                                                         int method)
{
    if (!state.hit) {
        return float3(0.5f);
    }
    if (method == 4 && state.sampleCount > 0u) {
        return state.summedPosition / float(state.sampleCount);
    }
    return state.selectedPosition;
}

[[maybe_unused]] static inline float4 finalizeProjection(constant RenderingArguments& args,
                                                         constant RenderingParameters& params,
                                                         thread const ProjectionState& state,
                                                         bool useTransfer)
{
    const int method = params.material.method;
    const float densityWindow = projectionDensityWindow(state, method);
    const float densityDataset = projectionDensityDataset(state, method);

    if (!state.hit) {
        return float4(0.0f);
    }
    if (!useTransfer) {
        return float4(densityWindow);
    }
    return compositeChannels(args,
                             params,
                             densityDataset,
                             0.0f,
                             true);
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
