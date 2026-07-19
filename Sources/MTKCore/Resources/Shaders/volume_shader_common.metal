#ifndef volume_shader_common_metal
#define volume_shader_common_metal

#include <metal_stdlib>

using namespace metal;

constexpr sampler sampler3d(coord::normalized,
                            filter::nearest,
                            address::clamp_to_edge);

constexpr sampler sampler2d(coord::normalized,
                            filter::linear,
                            address::clamp_to_edge);

static inline float4 quatInv(const float4 q) {
    return float4(-q.xyz, q.w);
}

[[maybe_unused]] static inline float4 quatMul(const float4 q1, const float4 q2) {
    float scalar = q1.w * q2.w - dot(q1.xyz, q2.xyz);
    float3 vector = cross(q1.xyz, q2.xyz) + q1.w * q2.xyz + q2.w * q1.xyz;
    return float4(vector, scalar);
}

[[maybe_unused]] static inline float3 quatMul(const float4 q, const float3 v) {
    float4 rotated = quatMul(q, float4(v, 0.0f));
    return quatMul(rotated, quatInv(q)).xyz;
}

class Util {
public:
    static float normalize(short value, short minValue, short maxValue)
    {
        if (maxValue <= minValue) {
            return 0.0f;
        }
        float normalized = float(value - minValue) / float(maxValue - minValue);
        return clamp(normalized, 0.0f, 1.0f);
    }

    static float lerp(float a, float b, float w) {
        return a + w * (b - a);
    }

    static float3 lerp(float3 a, float3 b, float w) {
        return a + w * (b - a);
    }

    static float3 calculateLighting(float3 col,
                                    float3 normal,
                                    float3 lightDir,
                                    float3 eyeDir,
                                    float specularIntensity,
                                    float ambientIntensity,
                                    float directionalIntensity)
    {
        const float ambient = clamp(ambientIntensity, 0.0f, 1.0f);
        const float diffuseWeight = 0.7f * clamp(directionalIntensity, 0.0f, 2.0f);
        constexpr float specularPower = 20.0f;

        float lengthSq = dot(normal, normal);
        if (lengthSq <= 1.0e-6f) {
            return ambient * col;
        }

        float3 n = ::normalize(normal);
        float3 l = ::normalize(lightDir);
        float3 v = ::normalize(eyeDir);
        float diffuse = max(dot(n, l), 0.0f);
        float3 halfVector = ::normalize(l + v);
        float specular = pow(max(dot(n, halfVector), 0.0f), specularPower);
        return col * (ambient + diffuseWeight * diffuse) +
               float3(specularIntensity * directionalIntensity * specular);
    }
};

class VR
{
public:
    struct RayInfo {
        float3 startPosition;
        float3 endPosition;
        float3 direction;
        float2 aabbIntersection;
    };

    struct RaymarchInfo {
        RayInfo ray;
        int numSteps;
        float numStepsRecip;
        float stepSize;
    };

    // The raycast path binds a normalized view over the shared 16-bit integer volume.
    // Normalized samples map back into the original signed or unsigned intensity domain here.
    // SNORM aliases -32768 and -32767; preserve -32768 as the padding sentinel.
    static inline float decodeVolumeSample(float sampleValue, bool unsignedVolume) {
        if (unsignedVolume) {
            return sampleValue * 65535.0f;
        }
        return sampleValue <= -1.0f ? -32768.0f : sampleValue * 32767.0f;
    }

    static inline short decodeInt16SampleToShort(float sampleValue) {
        return short(round(clamp(sampleValue, -32768.0f, 32767.0f)));
    }

    static inline float3 sampleCoordinate(texture3d<float, access::sample> volume,
                                          float3 coord)
    {
        const float3 dimension = float3(max(volume.get_width(), 1u),
                                        max(volume.get_height(), 1u),
                                        max(volume.get_depth(), 1u));
        const float3 maxIndex = max(dimension - float3(1.0f), float3(0.0f));
        return (clamp(coord, 0.0f, 1.0f) * maxIndex + float3(0.5f)) / dimension;
    }

    static float sampleTrilinearDensity(texture3d<float, access::sample> volume,
                                        sampler linearSampler,
                                        float3 coord,
                                        bool unsignedVolume)
    {
        const float sampleValue = volume.sample(linearSampler, sampleCoordinate(volume, coord)).r;
        return decodeVolumeSample(sampleValue, unsignedVolume);
    }

    static float3 calGradient(texture3d<float, access::sample> volume,
                              sampler linearSampler,
                              float3 coord,
                              float3 dimension,
                              bool unsignedVolume)
    {
        if (dimension.x < 2.0f || dimension.y < 2.0f || dimension.z < 2.0f) {
            return float3(0.0f);
        }

        float3 invDim = float3(0.0f);
        invDim.x = dimension.x > 1.0f ? 1.0f / (dimension.x - 1.0f) : 0.0f;
        invDim.y = dimension.y > 1.0f ? 1.0f / (dimension.y - 1.0f) : 0.0f;
        invDim.z = dimension.z > 1.0f ? 1.0f / (dimension.z - 1.0f) : 0.0f;

        return calGradientWithStep(volume, linearSampler, coord, invDim, unsignedVolume);
    }

    static float3 calGradientWithStep(texture3d<float, access::sample> volume,
                                      sampler linearSampler,
                                      float3 coord,
                                      float3 invDim,
                                      bool unsignedVolume)
    {
        if (any(invDim <= float3(0.0f))) {
            return float3(0.0f);
        }

        float sxPlus = sampleTrilinearDensity(
            volume, linearSampler, float3(min(coord.x + invDim.x, 1.0f), coord.y, coord.z), unsignedVolume);
        float sxMinus = sampleTrilinearDensity(
            volume, linearSampler, float3(max(coord.x - invDim.x, 0.0f), coord.y, coord.z), unsignedVolume);
        float syPlus = sampleTrilinearDensity(
            volume, linearSampler, float3(coord.x, min(coord.y + invDim.y, 1.0f), coord.z), unsignedVolume);
        float syMinus = sampleTrilinearDensity(
            volume, linearSampler, float3(coord.x, max(coord.y - invDim.y, 0.0f), coord.z), unsignedVolume);
        float szPlus = sampleTrilinearDensity(
            volume, linearSampler, float3(coord.x, coord.y, min(coord.z + invDim.z, 1.0f)), unsignedVolume);
        float szMinus = sampleTrilinearDensity(
            volume, linearSampler, float3(coord.x, coord.y, max(coord.z - invDim.z, 0.0f)), unsignedVolume);

        return float3(sxMinus - sxPlus, syMinus - syPlus, szMinus - szPlus);
    }

    static float2 intersectAABB(float3 rayOrigin,
                                float3 rayDir,
                                float3 boxMin,
                                float3 boxMax)
    {
        float3 tMin = (boxMin - rayOrigin) / rayDir;
        float3 tMax = (boxMax - rayOrigin) / rayDir;
        float3 t1 = min(tMin, tMax);
        float3 t2 = max(tMin, tMax);
        float tNear = max(max(t1.x, t1.y), t1.z);
        float tFar = min(min(t2.x, t2.y), t2.z);
        return float2(tNear, tFar);
    }

    static RaymarchInfo initRayMarch(RayInfo ray, int maxNumSteps)
    {
        RaymarchInfo raymarchInfo;
        raymarchInfo.stepSize = sqrt(3.0f) / maxNumSteps;
        raymarchInfo.numSteps = clamp((int)(abs(ray.aabbIntersection.x - ray.aabbIntersection.y) / raymarchInfo.stepSize), (int)1, maxNumSteps);
        raymarchInfo.numStepsRecip = 1.0f / raymarchInfo.numSteps;
        return raymarchInfo;
    }

    static short getDensity(texture3d<float, access::sample> volume,
                            float3 coord,
                            bool unsignedVolume)
    {
        const float sampleValue = volume.sample(sampler3d, sampleCoordinate(volume, coord)).r;
        return decodeInt16SampleToShort(decodeVolumeSample(sampleValue, unsignedVolume));
    }

    static float getDensityTrilinear(texture3d<float, access::sample> volume,
                                     sampler linearSampler,
                                     float3 coord,
                                     bool unsignedVolume)
    {
        return sampleTrilinearDensity(volume, linearSampler, coord, unsignedVolume);
    }

    static float3 getGradient(texture3d<float, access::sample> gradient, float3 coord)
    {
        return gradient.sample(sampler3d, coord).xyz;
    }

    static float4 getTfColour(texture2d<float, access::sample> tf,
                              float density)
    {
        return tf.sample(sampler2d, float2(clamp(density, 0.0f, 1.0f), 0.0f));
    }

    static float4 getTfColour(texture2d<float, access::sample> tf,
                              float density,
                              float gradientMagnitude,
                              bool use2DTransferFunction)
    {
        const float densityCoord = clamp(density, 0.0f, 1.0f);
        const float gradientCoord = clamp(gradientMagnitude, 0.0f, 1.0f);
        return tf.sample(sampler2d,
                         float2(densityCoord, use2DTransferFunction ? gradientCoord : 0.0f));
    }
};

#endif
