#include <metal_stdlib>
#include "../MPR/Shared.metal"
#include "volume_rendering_types.metal"
#include "volume_rendering_helpers.metal"

using namespace metal;

kernel void volume_compute(constant RenderingArguments& args [[buffer(0)]],
                           constant CameraUniforms& camera          [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]])
{
    const uint width  = args.outputTexture.get_width();
    const uint height = args.outputTexture.get_height();

    if (gid.x >= width || gid.y >= height) {
        return;
    }

#if DEBUG
    const bool debugDensityEnabled = ((args.optionValue & VolumeCompute::OPTION_DEBUG_DENSITY) != 0);
    const uint2 debugCenterPixel = uint2(width / 2, height / 2);
    bool debugDensitySentinelWritten = false;
    bool debugPreBlendSentinelWritten = false;
    if (debugDensityEnabled) {
        args.outputTexture.write(float4(1.0f, 0.0f, 1.0f, 1.0f), gid); // Kernel start
    }
#endif

    // Coordenadas de dispositivo normalizadas (-1 .. +1).
    const float x = (float(gid.x) + 0.5f) / float(width);
    const float y = (float(height - 1 - gid.y) + 0.5f) / float(height);
    const float2 ndc = float2(x * 2.0f - 1.0f,
                              y * 2.0f - 1.0f);

    const float4 clipNear = float4(ndc, 0.0f, 1.0f);
    const float4 clipFar  = float4(ndc, 1.0f, 1.0f);

    float4 worldNear = camera.inverseViewProjectionMatrix * clipNear;
    float4 worldFar  = camera.inverseViewProjectionMatrix * clipFar;
    worldNear /= worldNear.w;
    worldFar  /= worldFar.w;

    // Map world positions to texture space using precomputed SCTC matrix
    float4 texFar4  = camera.worldToTextureMatrix * worldFar;
    float3 texFar   = texFar4.xyz / texFar4.w;
    float3 cameraTex = (camera.worldToTextureMatrix * float4(camera.cameraPositionLocal, 1.0)).xyz;

    float3 rayDir = VolumeCompute::computeRayDirection(cameraTex, texFar);

    float2 intersection = VR::intersectAABB(cameraTex,
                                            rayDir,
                                            float3(0.0f),
                                            float3(1.0f));
    float tEnter = max(intersection.x, 0.0f);
    float tExit  = intersection.y;

#if DEBUG
    if (debugDensityEnabled) {
        args.outputTexture.write(float4(0.0f, 1.0f, 0.0f, 1.0f), gid); // After intersectBox
    }
#endif

    if (!(tExit > tEnter)) {
        args.outputTexture.write(float4(0.0f), gid);
        return;
    }

    float3 startPos = cameraTex + rayDir * tEnter;
    float3 endPos   = cameraTex + rayDir * tExit;

    constant VolumeUniforms& material = args.params.material;
    const float opacityThreshold = VolumeCompute::getEarlyExitThreshold(material, args.params);

    const int maxSteps = max(material.renderingQuality, 1);
    const float baseStepForJitter = sqrt(3.0f) / float(maxSteps);
    const float jitterParam = clamp(args.params.jitterAmount, 0.0f, 1.0f);
    if (jitterParam > 0.0f) {
        float jitterSeed = dot(float2(gid), float2(12.9898f, 78.233f)) + float(camera.frameIndex);
        float jitterNoise = fract(sin(jitterSeed) * 43758.5453f);
        float availableDistance = max(1.0e-5f, abs(tExit - tEnter));
        float jitterDistance = min(baseStepForJitter * jitterParam * jitterNoise,
                                   availableDistance * 0.99f);

        if (material.isBackwardOn != 0) {
            tExit = max(tExit - jitterDistance, tEnter);
        } else {
            tEnter = min(tEnter + jitterDistance, tExit);
        }

        startPos = cameraTex + rayDir * tEnter;
        endPos   = cameraTex + rayDir * tExit;
    }

    VR::RayInfo ray;
    if (material.isBackwardOn != 0) {
        ray.startPosition = endPos;
        ray.endPosition   = startPos;
        ray.direction     = -rayDir;
        ray.aabbIntersection = float2(tExit, tEnter);
    } else {
        ray.startPosition = startPos;
        ray.endPosition   = endPos;
        ray.direction     = rayDir;
        ray.aabbIntersection = float2(tEnter, tExit);
    }

    VR::RaymarchInfo march = VR::initRayMarch(ray, maxSteps);
    if (march.numSteps <= 0) {
#if DEBUG
        if (debugDensityEnabled) {
            args.outputTexture.write(float4(1.0f, 0.0f, 0.0f, 1.0f), gid); // Ray march init failure
        }
#endif
        args.outputTexture.write(float4(0.0f), gid);
        return;
    }

    half4 accumulator = half4(0.0h);
    float debugMaxDensity = 0.0f;
    float debugMaxSampleAlpha = 0.0f;
    const float3 dimension = float3(material.dimX,
                                    material.dimY,
                                    material.dimZ);
    const bool isMIP = (material.method == 2);
    const bool isMinIP = (material.method == 3);
    float mipMaxSeen = 0.0f;
    float mipMinSeen = 1.0f;
    constexpr float kMipEarlyStop = 0.999f;   // stop when remaining samples cannot improve
    constexpr float kMinIpEarlyStop = 0.001f; // stop when already near floor

    const float baseStep = max(march.stepSize, 1.0e-5f);
    int zeroCount = 0;
    const int kZeroRun = max((int)args.params.zeroRunLength, 1);
    const int kZeroSkip = max((int)args.params.zeroSkipDistance, 1);
    // zeroRunThreshold handled inside shouldSkipEmptySpace; adaptive flag unused
    const float totalDistance = max(length(ray.endPosition - ray.startPosition), baseStep);
    float distanceTravelled = 0.0f;
    int iteration = 0;
    const int maxIterations = max(march.numSteps * 4, march.numSteps + 16);

    float prevDensityDataset = 0.0f;

    while (distanceTravelled < totalDistance && iteration < maxIterations) {
        float stepDistance = baseStep;
        const float t = (totalDistance > 0.0f)
            ? distanceTravelled / totalDistance
            : 0.0f;
        const float3 samplePos = Util::lerp(ray.startPosition,
                                            ray.endPosition,
                                            t);

        if (samplePos.x < 0.0f || samplePos.x > 1.0f ||
            samplePos.y < 0.0f || samplePos.y > 1.0f ||
            samplePos.z < 0.0f || samplePos.z > 1.0f) {
            break;
        }

        VolumeCompute::ClipSampleContext clipContext = VolumeCompute::prepareClipSample(samplePos, args.params);
        if (VolumeCompute::isOutsideTrimBounds(clipContext.orientedCoordinate, args.params) ||
            VolumeCompute::isClippedByPlanes(clipContext, args.params)) {
            distanceTravelled += stepDistance;
            iteration++;
            continue;
        }

        float hu = VolumeCompute::sampleDensity(args.volumeTexture,
                                                args.volumeSampler,
                                                samplePos,
                                                material);
        // Optional pre-TF blur to reduce wood-grain/banding at low step counts.
        if (args.params.preTFBlurRadius > 0.0f) {
            const float r = args.params.preTFBlurRadius;
            float weight = 1.0f;
            float accum = hu;
            const float3 offsets[6] = {
                float3( r, 0, 0), float3(-r, 0, 0),
                float3(0,  r, 0), float3(0, -r, 0),
                float3(0, 0,  r), float3(0, 0, -r)
            };
            for (uint o = 0; o < 6; ++o) {
                float3 coord = clamp(samplePos + offsets[o], float3(0.0f), float3(1.0f));
                accum += VolumeCompute::sampleDensity(args.volumeTexture,
                                                      args.volumeSampler,
                                                      coord,
                                                      material);
                weight += 1.0f;
            }
            hu = accum / weight;
        }
        const float windowMin = (float)material.voxelMinValue;
        const float windowMax = (float)material.voxelMaxValue;
        const float dataMin = (float)material.datasetMinValue;
        const float dataMax = (float)material.datasetMaxValue;

        half densityWindow = (half)Util::normalize(hu, windowMin, windowMax);
        half densityDataset = (half)Util::normalize(hu, dataMin, dataMax);

        densityWindow = clamp(densityWindow, 0.0h, 1.0h);
        densityDataset = clamp(densityDataset, 0.0h, 1.0h);

#if DEBUG
        if (debugDensityEnabled && !debugDensitySentinelWritten) {
            args.outputTexture.write(float4(0.0f, 0.5f, 1.0f, 1.0f), gid); // After VR::getDensity
            debugDensitySentinelWritten = true;
        }
        if (debugDensityEnabled && all(gid == debugCenterPixel)) {
            printf("[DensityDebug] iter=%u tEnter=%.6f tExit=%.6f numSteps=%d hu=%d window=%.6f dataset=%.6f\n",
                   uint(iteration),
                   tEnter,
                   tExit,
                   march.numSteps,
                   int(hu),
                   densityWindow,
                   densityDataset);
        }
#endif

        debugMaxDensity = max(debugMaxDensity, (float)densityWindow);

        if (VolumeCompute::gateDensity(densityWindow, args.params, hu)) {
            distanceTravelled += stepDistance;
            iteration++;
            continue;
        }

        const bool useTransfer = (material.useTFProj != 0 || material.method == 1);
        const float densityForColour = useTransfer ? (float)densityDataset : (float)densityWindow;
        const half windowIntensity = densityWindow;

        // Gradient / adaptive step precomputation
        const float3 spacing = float3(args.params.spacingX, args.params.spacingY, args.params.spacingZ);
        const bool needGradient = (material.isLightingOn != 0) || (args.params.adaptiveGradientScale > 0.0f) || (args.params.emptySpaceGradientThreshold > 0.0f) || (material.dualParameterTFEnabled != 0);
        float3 gradient = float3(0.0f);
        float gradientMagnitude = 0.0f;
        if (needGradient) {
            gradient = VolumeCompute::computeSpacingAwareGradient(args.volumeTexture, samplePos, dimension, spacing);
            if (material.gradientSmoothness > 0.0f) {
                float smooth = clamp(material.gradientSmoothness, 0.0f, 1.0f);
                gradient *= (1.0f - smooth);
            }
            gradientMagnitude = length(gradient);
        }

        // Adaptive step sizing (edge-aware and flat-region boost)
        {
            float scale = VolumeCompute::computeAdaptiveStepScale(gradientMagnitude, args.params);
            stepDistance = baseStep * scale;
            stepDistance = max(stepDistance, args.params.minStepNormalized);
        }

        half4 sampleColour = (half4)VolumeCompute::compositeChannels(args,
                                                               args.params,
                                                               densityForColour,
                                                               gradientMagnitude,
                                                               useTransfer);

        if (useTransfer) {
            sampleColour.rgb *= windowIntensity;
        }

        if (material.isLightingOn != 0) {
            float lengthSq = dot(gradient, gradient);
            half3 normal = lengthSq > 1.0e-6f ? (half3)normalize(gradient) : half3(0.0h);
            float3 eyeDirF = (material.isBackwardOn != 0) ? ray.direction : -ray.direction;
            float3 lightDirF = normalize(cameraTex - samplePos);
            half3 eyeDir = (half3)eyeDirF;
            half3 lightDir = (half3)lightDirF;
            sampleColour.rgb = Util::calculateLighting(sampleColour.rgb,
                                                       normal,
                                                       lightDir,
                                                       eyeDir,
                                                       0.3h);

            if (material.lightOcclusionEnabled != 0) {
                float occlusion = 1.0f;
                float probeStep = max(baseStep * 2.0f, 1.0e-4f);
                float3 probePos = samplePos;
                const int kProbeSteps = 4;
                for (int i = 0; i < kProbeSteps; ++i) {
                    probePos += (lightDirF * probeStep);
                    if (any(probePos < 0.0f) || any(probePos > 1.0f)) { break; }
                    float dProbe = VolumeCompute::sampleDensity(args.volumeTexture,
                                                                args.volumeSampler,
                                                                probePos,
                                                                material);
                    float atten = exp(-material.lightOcclusionStrength * dProbe);
                    occlusion *= atten;
                }
                sampleColour.rgb *= (half)clamp(occlusion, 0.0f, 1.0f);
            }
        }

        const half densityFloor = (half)clamp(args.params.material.densityFloor, 0.0f, 1.0f);
        if (densityWindow <= densityFloor) {
            sampleColour.a = 0.0h;
        }

        if (useTransfer) {
            sampleColour.a *= densityWindow;
        } else {
            sampleColour.a = densityWindow;
        }

        debugMaxSampleAlpha = max(debugMaxSampleAlpha, (float)clamp(sampleColour.a, 0.0h, 1.0h));

        // Empty-space skipping with optional gradient gating
        if (VolumeCompute::shouldSkipEmptySpace((float)sampleColour.a, gradientMagnitude, args.params) ||
            VolumeCompute::shouldSkipByOccupancy(args.params, samplePos, args.occupancyTexture)) {
            zeroCount++;
            if (zeroCount >= kZeroRun) {
                distanceTravelled += baseStep * float(kZeroSkip);
                distanceTravelled = min(distanceTravelled, totalDistance);
                zeroCount = 0;
            }
            distanceTravelled += stepDistance;
            distanceTravelled = min(distanceTravelled, totalDistance);
            iteration++;
            continue;
        }
        zeroCount = 0;

        const half alpha = clamp(sampleColour.a, 0.0h, 1.0h);
        const half3 premultColor = sampleColour.rgb * alpha;

#if DEBUG
        if (debugDensityEnabled && !debugPreBlendSentinelWritten) {
            args.outputTexture.write(float4(1.0f, 0.5f, 0.0f, 1.0f), gid); // Before blend FTB
            debugPreBlendSentinelWritten = true;
        }
#endif

        // Optional pre-integrated TF blend with previous density
        if (useTransfer && material.usePreIntegratedTF != 0) {
            half4 prevColour = (half4)VolumeCompute::compositeChannels(args,
                                                                       args.params,
                                                                       prevDensityDataset,
                                                                       gradientMagnitude,
                                                                       useTransfer);
            sampleColour = (sampleColour + prevColour) * 0.5h;
        }

        if (material.isBackwardOn != 0) {
            const half oneMinusSampleAlpha = 1.0h - alpha;
            accumulator.rgb = premultColor + oneMinusSampleAlpha * accumulator.rgb;
            accumulator.a = alpha + oneMinusSampleAlpha * accumulator.a;
        } else {
            const half oneMinusAccumAlpha = 1.0h - accumulator.a;
            accumulator.rgb += premultColor * oneMinusAccumAlpha;
            accumulator.a += alpha * oneMinusAccumAlpha;
        }

        // MIP/MinIP early break: once bound is reached, remaining steps cannot improve the result
        if (isMIP) {
            mipMaxSeen = max(mipMaxSeen, (float)alpha);
            if (mipMaxSeen >= kMipEarlyStop) {
                break;
            }
        } else if (isMinIP) {
            mipMinSeen = min(mipMinSeen, (float)alpha);
            if (mipMinSeen <= kMinIpEarlyStop) {
                break;
            }
        }

        if (accumulator.a > opacityThreshold) {
            break;
        }

        distanceTravelled += stepDistance;
        distanceTravelled = min(distanceTravelled, totalDistance);
        iteration++;
        prevDensityDataset = (float)densityDataset;
    }

    accumulator = clamp(accumulator, half4(0.0h), half4(1.0h));

    if ((args.optionValue & VolumeCompute::OPTION_DEBUG_DENSITY) != 0) {
        float3 debugRGB = float3(debugMaxDensity, debugMaxSampleAlpha, (float)accumulator.a);
        args.outputTexture.write(float4(debugRGB, 1.0f), gid);
        return;
    }
    args.outputTexture.write((float4)accumulator, gid);
}
