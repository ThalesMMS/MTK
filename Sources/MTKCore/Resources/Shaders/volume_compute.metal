#include <metal_stdlib>
#include "volume_shader_common.metal"
#include "volume_rendering_types.metal"
#include "volume_rendering_helpers.metal"
#include "empty_space_acceleration.metal"

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

    const bool debugDensityEnabled = ((args.optionValue & VolumeCompute::OPTION_DEBUG_DENSITY) != 0);
#if DEBUG
    const uint2 debugCenterPixel = uint2(width / 2, height / 2);
    bool debugDensitySentinelWritten = false;
    bool debugPreBlendSentinelWritten = false;
    if (debugDensityEnabled) {
        args.outputTexture.write(float4(1.0f, 0.0f, 1.0f, 1.0f), gid); // Kernel start
    }
#endif

    // Normalized device coordinates (-1 .. +1).
    const float x = (float(gid.x) + 0.5f) / float(width);
    const float y = (float(height - 1 - gid.y) + 0.5f) / float(height);
    const float2 pixelUV = float2(x, y);
    float3 localNear;
    float3 localFar;
    if (camera.rayBasisValid != 0u) {
        localNear = camera.localNearOrigin.xyz +
                    pixelUV.x * camera.localNearDeltaX.xyz +
                    pixelUV.y * camera.localNearDeltaY.xyz;
        localFar = camera.localFarOrigin.xyz +
                   pixelUV.x * camera.localFarDeltaX.xyz +
                   pixelUV.y * camera.localFarDeltaY.xyz;
    } else {
        const float2 ndc = float2(x * 2.0f - 1.0f,
                                  y * 2.0f - 1.0f);
        const float4 clipNear = float4(ndc, 0.0f, 1.0f);
        const float4 clipFar  = float4(ndc, 1.0f, 1.0f);

        float4 worldNear = camera.inverseViewProjectionMatrix * clipNear;
        float4 worldFar  = camera.inverseViewProjectionMatrix * clipFar;
        worldNear /= worldNear.w;
        worldFar  /= worldFar.w;

        float4 localNear4 = camera.inverseModelMatrix * worldNear;
        float4 localFar4  = camera.inverseModelMatrix * worldFar;
        localNear = (localNear4.xyz / localNear4.w) + float3(0.5f);
        localFar  = (localFar4.xyz / localFar4.w) + float3(0.5f);
    }

    float3 cameraLocal01 = camera.cameraPositionLocal + float3(0.5f);
    float3 rayOrigin = camera.projectionType == 1u ? localNear : cameraLocal01;
    float3 rayDir = VolumeCompute::computeRayDirection(rayOrigin, localFar);
    constant VolumeUniforms& material = args.params.material;
    const bool lightingEnabled = (material.isLightingOn != 0);
    float3 rayDirWorld = float3(0.0f);
    if (lightingEnabled) {
        rayDirWorld = normalize(VolumeCompute::transformDirection(camera.modelMatrix, rayDir));
    }

    float2 intersection = VR::intersectAABB(rayOrigin,
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

    float3 startPos = rayOrigin + rayDir * tEnter;
    float3 endPos   = rayOrigin + rayDir * tExit;

    const float opacityThreshold = clamp(args.params.earlyTerminationThreshold, 0.0f, 0.9999f);
    const float alphaSkipThreshold = opacityThreshold <= 0.85f ? 0.005f : 0.001f;

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

        startPos = rayOrigin + rayDir * tEnter;
        endPos   = rayOrigin + rayDir * tExit;
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

    const bool isDVR = (material.method == 1);
    VolumeCompute::ProjectionState projectionState = VolumeCompute::initProjectionState();
    float4 accumulator = float4(0.0f);
    float debugMaxDensity = 0.0f;
    float debugMaxSampleAlpha = 0.0f;
    const float3 dimension = float3(material.dimX,
                                    material.dimY,
                                    material.dimZ);
    const float3 gradientStep = float3(
        dimension.x > 1.0f ? 1.0f / (dimension.x - 1.0f) : 0.0f,
        dimension.y > 1.0f ? 1.0f / (dimension.y - 1.0f) : 0.0f,
        dimension.z > 1.0f ? 1.0f / (dimension.z - 1.0f) : 0.0f
    );

    const float baseStep = max(march.stepSize, 1.0e-5f);
    int zeroCount = 0;
    constexpr int kZeroRun = 4;
    constexpr int kZeroSkip = 3;
    const bool hasTrimBounds = args.params.trimXMin > 0.0f ||
                               args.params.trimXMax < 1.0f ||
                               args.params.trimYMin > 0.0f ||
                               args.params.trimYMax < 1.0f ||
                               args.params.trimZMin > 0.0f ||
                               args.params.trimZMax < 1.0f;
    const bool hasClipPlanes = any(abs(args.params.clipPlane0.xyz) > float3(1.0e-6f)) ||
                               any(abs(args.params.clipPlane1.xyz) > float3(1.0e-6f)) ||
                               any(abs(args.params.clipPlane2.xyz) > float3(1.0e-6f));
    const bool adaptiveEnabled = ((args.optionValue & VolumeCompute::OPTION_ADAPTIVE) != 0) &&
                                 (args.params.adaptiveGradientThreshold > 1.0e-4f);
    const bool alphaRunSkipEnabled = adaptiveEnabled;
    const float windowMinValue = float(material.voxelMinValue);
    const float windowRange = float(material.voxelMaxValue - material.voxelMinValue);
    const float invWindowRange = windowRange > 0.0f ? 1.0f / windowRange : 0.0f;
    const float datasetMinValue = float(material.datasetMinValue);
    const float datasetRange = float(material.datasetMaxValue - material.datasetMinValue);
    const float invDatasetRange = datasetRange > 0.0f ? 1.0f / datasetRange : 0.0f;
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

        if (hasTrimBounds || hasClipPlanes) {
            VolumeCompute::ClipSampleContext clipContext;
            if (hasTrimBounds) {
                clipContext = VolumeCompute::prepareClipSample(samplePos, args.params);
                if (VolumeCompute::isOutsideTrimBounds(clipContext.orientedCoordinate, args.params)) {
                    distanceTravelled += stepDistance;
                    iteration++;
                    continue;
                }
            } else {
                clipContext.centeredCoordinate = samplePos - float3(0.5f);
                clipContext.orientedCoordinate = samplePos;
            }

            if (hasClipPlanes && VolumeCompute::isClippedByPlanes(clipContext, args.params)) {
                distanceTravelled += stepDistance;
                iteration++;
                continue;
            }
        }

        // MPS-accelerated empty space skipping (if available)
        const bool accelerationEnabled = ((args.optionValue & VolumeCompute::OPTION_USE_ACCELERATION) != 0);
        if (isDVR && accelerationEnabled && args.accelerationTexture.get_width() > 0) {
            uint maxMipLevel = args.accelerationTexture.get_num_mip_levels() - 1;
            bool canSkip = ESS::sampleAccelerationStructure(args.accelerationTexture,
                                                            args,
                                                            samplePos,
                                                            baseStep,
                                                            maxMipLevel,
                                                            args.volumeSampler);
            if (canSkip) {
                // Skip empty region with larger step
                distanceTravelled += stepDistance * 2.0f;
                distanceTravelled = min(distanceTravelled, totalDistance);
                iteration++;
                continue;
            }
        }

        const float huValue = VR::getDensityTrilinear(args.volumeTexture, samplePos);
        const short hu = VR::decodeInt16SampleToShort(huValue);
        float densityWindow = clamp((huValue - windowMinValue) * invWindowRange, 0.0f, 1.0f);
        float densityDataset = clamp((huValue - datasetMinValue) * invDatasetRange, 0.0f, 1.0f);

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

        if (debugDensityEnabled) {
            debugMaxDensity = max(debugMaxDensity, densityWindow);
        }

        if (VolumeCompute::gateDensity(densityWindow, args.params, hu)) {
            distanceTravelled += stepDistance;
            iteration++;
            continue;
        }

        float3 gradient = float3(0.0f);
        const bool need2DTF = (material.use2DTF != 0);
        const bool needsGradientBeforeOpacity = adaptiveEnabled || need2DTF || (!isDVR && lightingEnabled);
        if (needsGradientBeforeOpacity) {
            gradient = VR::calGradientWithStep(args.volumeTexture, samplePos, gradientStep);
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

        if (!isDVR) {
            if (material.method == 2) {
                VolumeCompute::updateMaxIntensity(projectionState,
                                                  densityWindow,
                                                  densityDataset,
                                                  gradient,
                                                  samplePos);
            } else if (material.method == 3) {
                VolumeCompute::updateMinIntensity(projectionState,
                                                  densityWindow,
                                                  densityDataset,
                                                  gradient,
                                                  samplePos);
            } else if (material.method == 4) {
                VolumeCompute::updateAverageIntensity(projectionState,
                                                      densityWindow,
                                                      densityDataset,
                                                      gradient,
                                                      samplePos);
            }

            distanceTravelled += stepDistance;
            distanceTravelled = min(distanceTravelled, totalDistance);
            iteration++;
            continue;
        }

        float gradientMagnitude = 0.0f;
        if (need2DTF) {
            float rawGradMag = length(gradient);
            float gradMin = material.gradientMin;
            float gradMax = material.gradientMax;
            if (gradMax > gradMin) {
                gradientMagnitude = clamp((rawGradMag - gradMin) / (gradMax - gradMin), 0.0f, 1.0f);
            } else {
                gradientMagnitude = 0.0f;
            }
        }

        float4 sampleColour = VolumeCompute::compositeChannels(args,
                                                               args.params,
                                                               densityForColour,
                                                               gradientMagnitude,
                                                               useTransfer);

        if (useTransfer) {
            sampleColour.rgb *= windowIntensity;
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

        if (debugDensityEnabled) {
            debugMaxSampleAlpha = max(debugMaxSampleAlpha, clamp(sampleColour.a, 0.0f, 1.0f));
        }

        if (alphaRunSkipEnabled && sampleColour.a < alphaSkipThreshold) {
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

        if (lightingEnabled) {
            if (!needsGradientBeforeOpacity) {
                gradient = VR::calGradientWithStep(args.volumeTexture, samplePos, gradientStep);
            }
            float lengthSq = dot(gradient, gradient);
            float3 normal = lengthSq > 1.0e-6f
                ? VolumeCompute::transformNormal(camera.inverseModelMatrix, gradient)
                : float3(0.0f);
            float3 eyeDir = (material.isBackwardOn != 0) ? rayDirWorld : -rayDirWorld;
            float3 lightDir = eyeDir;
            sampleColour.rgb = Util::calculateLighting(sampleColour.rgb,
                                                       normal,
                                                       lightDir,
                                                       eyeDir,
                                                       0.3f);
        }

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

    if (!isDVR) {
        const bool useTransfer = (material.useTFProj != 0);
        accumulator = VolumeCompute::finalizeProjection(args,
                                                        args.params,
                                                        projectionState,
                                                        useTransfer);
        if (material.isLightingOn != 0 && projectionState.hit) {
            float3 projectionNormal = VolumeCompute::projectionGradient(projectionState, material.method);
            float lengthSq = dot(projectionNormal, projectionNormal);
            if (lengthSq > 1.0e-6f) {
                projectionNormal = VolumeCompute::transformNormal(camera.inverseModelMatrix,
                                                                  projectionNormal);
                float3 eyeDir = (material.isBackwardOn != 0) ? rayDirWorld : -rayDirWorld;
                float3 lightDir = eyeDir;
                accumulator.rgb = Util::calculateLighting(accumulator.rgb,
                                                          projectionNormal,
                                                          lightDir,
                                                          eyeDir,
                                                          0.3f);
            }
        }
        if (debugDensityEnabled) {
            debugMaxDensity = max(debugMaxDensity,
                                  VolumeCompute::projectionDensityWindow(projectionState, material.method));
            debugMaxSampleAlpha = max(debugMaxSampleAlpha, accumulator.a);
        }
    }

    accumulator = clamp(accumulator, float4(0.0f), float4(1.0f));

    if (debugDensityEnabled) {
        float3 debugRGB = float3(debugMaxDensity, debugMaxSampleAlpha, accumulator.a);
        args.outputTexture.write(float4(debugRGB, 1.0f), gid);
        return;
    }
    args.outputTexture.write(accumulator, gid);
}
