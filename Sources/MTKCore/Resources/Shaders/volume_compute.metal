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

    float4 localFar4  = camera.inverseModelMatrix * worldFar;
    float3 localFar   = (localFar4.xyz / localFar4.w) + float3(0.5f);

    float3 cameraLocal01 = camera.cameraPositionLocal + float3(0.5f);
    float3 rayDir = VolumeCompute::computeRayDirection(cameraLocal01, localFar);

    float2 intersection = VR::intersectAABB(cameraLocal01,
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

    float3 startPos = cameraLocal01 + rayDir * tEnter;
    float3 endPos   = cameraLocal01 + rayDir * tExit;

    constant VolumeUniforms& material = args.params.material;
    const float opacityThreshold = clamp(args.params.earlyTerminationThreshold, 0.0f, 0.9999f);

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

        startPos = cameraLocal01 + rayDir * tEnter;
        endPos   = cameraLocal01 + rayDir * tExit;
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

    float4 accumulator = float4(0.0f);
    float debugMaxDensity = 0.0f;
    float debugMaxSampleAlpha = 0.0f;
    const float3 dimension = float3(material.dimX,
                                    material.dimY,
                                    material.dimZ);

    const float baseStep = max(march.stepSize, 1.0e-5f);
    int zeroCount = 0;
    constexpr int kZeroRun = 4;
    constexpr int kZeroSkip = 3;
    const bool adaptiveEnabled = ((args.optionValue & VolumeCompute::OPTION_ADAPTIVE) != 0) &&
                                 (args.params.adaptiveGradientThreshold > 1.0e-4f);
    const float totalDistance = max(length(ray.endPosition - ray.startPosition), baseStep);
    float distanceTravelled = 0.0f;
    int iteration = 0;
    const int maxIterations = max(march.numSteps * 4, march.numSteps + 16);

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

        const short hu = VR::getDensity(args.volumeTexture, samplePos);
        const short windowMin = (short)material.voxelMinValue;
        const short windowMax = (short)material.voxelMaxValue;
        const short dataMin = (short)material.datasetMinValue;
        const short dataMax = (short)material.datasetMaxValue;

        float densityWindow = Util::normalize(hu, windowMin, windowMax);
        float densityDataset = Util::normalize(hu, dataMin, dataMax);

        densityWindow = clamp(densityWindow, 0.0f, 1.0f);
        densityDataset = clamp(densityDataset, 0.0f, 1.0f);

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

        debugMaxDensity = max(debugMaxDensity, densityWindow);

        if (VolumeCompute::gateDensity(densityWindow, args.params, hu)) {
            distanceTravelled += stepDistance;
            iteration++;
            continue;
        }

        float3 gradient = float3(0.0f);
        if (adaptiveEnabled || material.isLightingOn != 0) {
            gradient = VR::calGradient(args.volumeTexture, samplePos, dimension);
        }

        if (adaptiveEnabled) {
            float gradMagnitude = length(gradient);
            float threshold = max(args.params.adaptiveGradientThreshold, 1.0e-4f);
            float normalizedGradient = clamp(gradMagnitude / threshold, 0.0f, 1.0f);
            float adaptFactor = mix(2.0f, 0.5f, normalizedGradient);
            stepDistance = baseStep * adaptFactor;
        }

        const bool useTransfer = (material.useTFProj != 0 || material.method == 1);
        const float densityForColour = useTransfer ? densityDataset : densityWindow;
        const float windowIntensity = densityWindow;
        float4 sampleColour = VolumeCompute::compositeChannels(args,
                                                               args.params,
                                                               densityForColour,
                                                               useTransfer);

        if (useTransfer) {
            sampleColour.rgb *= windowIntensity;
        }

        if (material.isLightingOn != 0) {
            float lengthSq = dot(gradient, gradient);
            float3 normal = lengthSq > 1.0e-6f ? normalize(gradient) : float3(0.0f);
            float3 eyeDir = (material.isBackwardOn != 0) ? ray.direction : -ray.direction;
            float3 lightDir = normalize(cameraLocal01 - samplePos);
            sampleColour.rgb = Util::calculateLighting(sampleColour.rgb,
                                                       normal,
                                                       lightDir,
                                                       eyeDir,
                                                       0.3f);
        }

        const float densityFloor = clamp(args.params.material.densityFloor, 0.0f, 1.0f);
        if (densityWindow <= densityFloor) {
            sampleColour.a = 0.0f;
        }

        if (useTransfer) {
            sampleColour.a *= densityWindow;
        } else {
            sampleColour.a = densityWindow;
        }

        debugMaxSampleAlpha = max(debugMaxSampleAlpha, clamp(sampleColour.a, 0.0f, 1.0f));

        if (sampleColour.a < 0.001f) {
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

        const float alpha = clamp(sampleColour.a, 0.0f, 1.0f);
        const float3 premultColor = sampleColour.rgb * alpha;

#if DEBUG
        if (debugDensityEnabled && !debugPreBlendSentinelWritten) {
            args.outputTexture.write(float4(1.0f, 0.5f, 0.0f, 1.0f), gid); // Before blend FTB
            debugPreBlendSentinelWritten = true;
        }
#endif

        if (material.isBackwardOn != 0) {
            const float oneMinusSampleAlpha = 1.0f - alpha;
            accumulator.rgb = premultColor + oneMinusSampleAlpha * accumulator.rgb;
            accumulator.a = alpha + oneMinusSampleAlpha * accumulator.a;
        } else {
            const float oneMinusAccumAlpha = 1.0f - accumulator.a;
            accumulator.rgb += premultColor * oneMinusAccumAlpha;
            accumulator.a += alpha * oneMinusAccumAlpha;
        }

        if (accumulator.a > opacityThreshold) {
            break;
        }

        distanceTravelled += stepDistance;
        distanceTravelled = min(distanceTravelled, totalDistance);
        iteration++;
    }

    accumulator = clamp(accumulator, float4(0.0f), float4(1.0f));

    if ((args.optionValue & VolumeCompute::OPTION_DEBUG_DENSITY) != 0) {
        float3 debugRGB = float3(debugMaxDensity, debugMaxSampleAlpha, accumulator.a);
        args.outputTexture.write(float4(debugRGB, 1.0f), gid);
        return;
    }
    args.outputTexture.write(accumulator, gid);
}
