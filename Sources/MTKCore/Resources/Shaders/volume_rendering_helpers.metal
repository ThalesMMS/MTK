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
[[maybe_unused]] constant int SHADOW_OFF = 0;
[[maybe_unused]] constant int SHADOW_HARD = 1;
[[maybe_unused]] constant int SHADOW_SOFT = 2;

[[maybe_unused]] static inline float3 computeRayDirection(float3 cameraLocal01,
                                                          float3 pixelLocal01)
{
    return normalize(pixelLocal01 - cameraLocal01);
}

[[maybe_unused]] static inline float3 transformPoint(float4x4 matrix,
                                                     float3 point)
{
    float4 transformed = matrix * float4(point, 1.0f);
    return transformed.xyz / transformed.w;
}

[[maybe_unused]] static inline float3 transformDirection(float4x4 matrix,
                                                         float3 direction)
{
    return (matrix * float4(direction, 0.0f)).xyz;
}

[[maybe_unused]] static inline float3 transformNormal(float4x4 inverseModelMatrix,
                                                      float3 normal)
{
    float3 transformed = float3(dot(inverseModelMatrix[0].xyz, normal),
                                dot(inverseModelMatrix[1].xyz, normal),
                                dot(inverseModelMatrix[2].xyz, normal));
    float lengthSq = dot(transformed, transformed);
    return lengthSq > 1.0e-6f ? normalize(transformed) : float3(0.0f);
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

    if (weights.y <= 0.0001f &&
        weights.z <= 0.0001f &&
        weights.w <= 0.0001f) {
        if (weights.x >= 0.9999f && args.toneBufferCh1 == nullptr) {
            return sampleTransfer(args.transferTextureCh1,
                                  density,
                                  gradient,
                                  useTransfer);
        }
        return sampleChannel(args.transferTextureCh1,
                             args.toneBufferCh1,
                             density,
                             gradient,
                             useTransfer,
                             weights.x);
    }

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

[[maybe_unused]] static inline bool isInsideUnitVolume(float3 position)
{
    return all(position >= float3(0.0f)) && all(position <= float3(1.0f));
}

[[maybe_unused]] static inline float shadowSampleAlpha(constant RenderingArguments& args,
                                                       float3 position,
                                                       float windowMinValue,
                                                       float invWindowRange)
{
    const float huValue = VR::getDensityTrilinear(args.volumeTexture, position);
    const short hu = VR::decodeInt16SampleToShort(huValue);
    const float densityWindow = clamp((huValue - windowMinValue) * invWindowRange, 0.0f, 1.0f);
    if (gateDensity(densityWindow, args.params, hu)) {
        return 0.0f;
    }
    const float densityFloor = clamp(args.params.material.densityFloor, 0.0f, 1.0f);
    if (densityWindow <= densityFloor) {
        return 0.0f;
    }
    return densityWindow;
}

[[maybe_unused]] static inline float accumulateShadowOpacity(constant RenderingArguments& args,
                                                             float3 samplePosition,
                                                             float3 shadowDirection,
                                                             float stepDistance,
                                                             int stepCount,
                                                             float windowMinValue,
                                                             float invWindowRange,
                                                             float opacityScale)
{
    if (dot(shadowDirection, shadowDirection) <= 1.0e-6f) {
        return 0.0f;
    }

    const float3 direction = normalize(shadowDirection);
    float3 position = samplePosition + direction * stepDistance * 1.5f;
    float accumulated = 0.0f;

    for (int step = 0; step < stepCount; ++step) {
        if (!isInsideUnitVolume(position)) {
            break;
        }

        const float alpha = clamp(shadowSampleAlpha(args,
                                                    position,
                                                    windowMinValue,
                                                    invWindowRange) * opacityScale,
                                  0.0f,
                                  1.0f);
        accumulated += (1.0f - accumulated) * alpha;
        if (accumulated > 0.95f) {
            break;
        }
        position += direction * stepDistance;
    }

    return clamp(accumulated, 0.0f, 1.0f);
}

[[maybe_unused]] static inline float hardShadowVisibility(constant RenderingArguments& args,
                                                          float3 samplePosition,
                                                          float3 shadowDirection,
                                                          float baseStep,
                                                          float windowMinValue,
                                                          float invWindowRange)
{
    // Hard shadows use a thresholded opacity cut so occluders produce a crisp attenuation step.
    const float localAlpha = shadowSampleAlpha(args,
                                               samplePosition,
                                               windowMinValue,
                                               invWindowRange);
    const float occlusion = accumulateShadowOpacity(args,
                                                    samplePosition,
                                                    shadowDirection,
                                                    baseStep * 2.0f,
                                                    8,
                                                    windowMinValue,
                                                    invWindowRange,
                                                    0.45f);
    const float effectiveOcclusion = max(occlusion, localAlpha * 0.35f);
    return effectiveOcclusion > 0.12f ? 0.35f : 1.0f;
}

[[maybe_unused]] static inline float softShadowVisibility(constant RenderingArguments& args,
                                                          float3 samplePosition,
                                                          float3 shadowDirection,
                                                          float baseStep,
                                                          float windowMinValue,
                                                          float invWindowRange)
{
    // Soft shadows average neighboring shadow rays and apply continuous absorption.
    if (dot(shadowDirection, shadowDirection) <= 1.0e-6f) {
        return 1.0f;
    }

    const float3 direction = normalize(shadowDirection);
    const float3 referenceAxis = abs(direction.z) < 0.9f ? float3(0.0f, 0.0f, 1.0f)
                                                         : float3(0.0f, 1.0f, 0.0f);
    const float3 tangent = normalize(cross(referenceAxis, direction));
    const float3 bitangent = normalize(cross(direction, tangent));
    const float spread = 0.35f;
    float occlusion = 0.0f;
    const float localAlpha = shadowSampleAlpha(args,
                                               samplePosition,
                                               windowMinValue,
                                               invWindowRange);

    occlusion += accumulateShadowOpacity(args,
                                         samplePosition,
                                         direction,
                                         baseStep * 2.0f,
                                         8,
                                         windowMinValue,
                                         invWindowRange,
                                         0.28f);
    occlusion += accumulateShadowOpacity(args,
                                         samplePosition,
                                         normalize(direction + tangent * spread),
                                         baseStep * 2.0f,
                                         8,
                                         windowMinValue,
                                         invWindowRange,
                                         0.28f);
    occlusion += accumulateShadowOpacity(args,
                                         samplePosition,
                                         normalize(direction - bitangent * spread),
                                         baseStep * 2.0f,
                                         8,
                                         windowMinValue,
                                         invWindowRange,
                                         0.28f);

    const float averageOcclusion = max(occlusion / 3.0f, localAlpha * 0.22f);
    return clamp(exp(-averageOcclusion * 1.6f), 0.45f, 1.0f);
}

[[maybe_unused]] static inline float shadowVisibility(constant RenderingArguments& args,
                                                      float3 samplePosition,
                                                      float3 shadowDirection,
                                                      float baseStep,
                                                      float windowMinValue,
                                                      float invWindowRange)
{
    if (args.params.material.shadowMode == SHADOW_OFF) {
        return 1.0f;
    }

    const int shadowMode = args.params.material.shadowMode;
    if (shadowMode == SHADOW_HARD) {
        return hardShadowVisibility(args,
                                    samplePosition,
                                    shadowDirection,
                                    baseStep,
                                    windowMinValue,
                                    invWindowRange);
    }
    if (shadowMode == SHADOW_SOFT) {
        return softShadowVisibility(args,
                                    samplePosition,
                                    shadowDirection,
                                    baseStep,
                                    windowMinValue,
                                    invWindowRange);
    }
    return 1.0f;
}

[[maybe_unused]] static inline float3 calculateShadowedLighting(float3 color,
                                                                float3 normal,
                                                                float3 lightDirection,
                                                                float3 eyeDirection,
                                                                float specularIntensity,
                                                                float ambientIntensity,
                                                                float directionalIntensity,
                                                                float shadow)
{
    const float ambient = clamp(ambientIntensity, 0.0f, 1.0f);
    const float directional = clamp(directionalIntensity, 0.0f, 2.0f);
    const float diffuseWeight = 0.7f * directional * shadow;
    constexpr float specularPower = 20.0f;

    float lengthSq = dot(normal, normal);
    if (lengthSq <= 1.0e-6f) {
        return ambient * color;
    }

    float3 n = normalize(normal);
    float3 l = normalize(lightDirection);
    float3 v = normalize(eyeDirection);
    float diffuse = max(dot(n, l), 0.0f);
    float3 halfVector = normalize(l + v);
    float specular = pow(max(dot(n, halfVector), 0.0f), specularPower);
    return color * (ambient + diffuseWeight * diffuse) +
           float3(specularIntensity * directional * shadow * specular);
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
