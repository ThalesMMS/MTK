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
                                    float specularIntensity)
    {
        constexpr float ambient = 0.2f;
        constexpr float diffuseWeight = 0.7f;
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
        return col * (ambient + diffuseWeight * diffuse) + float3(specularIntensity * specular);
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

    // Keep the decode step explicit so future packed/encoded volume formats can
    // add conversion logic without touching all sampling call sites.
    static inline float decodeInt16Sample(float sampleValue) {
        return sampleValue;
    }

    static inline short decodeInt16SampleToShort(float sampleValue) {
        return short(clamp(sampleValue, -32768.0f, 32767.0f));
    }

    static float sampleTrilinearDensity(texture3d<short, access::sample> volume,
                                        float3 coord)
    {
        uint3 maxIndex = uint3(max(volume.get_width(), 1u) - 1u,
                               max(volume.get_height(), 1u) - 1u,
                               max(volume.get_depth(), 1u) - 1u);
        float3 voxelCoord = clamp(coord, 0.0f, 1.0f) * float3(maxIndex);
        uint3 baseIndex = uint3(floor(voxelCoord));
        uint3 nextIndex = min(baseIndex + uint3(1u), maxIndex);
        float3 weight = voxelCoord - float3(baseIndex);

        float c000 = decodeInt16Sample(float(volume.read(uint3(baseIndex.x, baseIndex.y, baseIndex.z)).r));
        float c100 = decodeInt16Sample(float(volume.read(uint3(nextIndex.x, baseIndex.y, baseIndex.z)).r));
        float c010 = decodeInt16Sample(float(volume.read(uint3(baseIndex.x, nextIndex.y, baseIndex.z)).r));
        float c110 = decodeInt16Sample(float(volume.read(uint3(nextIndex.x, nextIndex.y, baseIndex.z)).r));
        float c001 = decodeInt16Sample(float(volume.read(uint3(baseIndex.x, baseIndex.y, nextIndex.z)).r));
        float c101 = decodeInt16Sample(float(volume.read(uint3(nextIndex.x, baseIndex.y, nextIndex.z)).r));
        float c011 = decodeInt16Sample(float(volume.read(uint3(baseIndex.x, nextIndex.y, nextIndex.z)).r));
        float c111 = decodeInt16Sample(float(volume.read(uint3(nextIndex.x, nextIndex.y, nextIndex.z)).r));

        float c00 = mix(c000, c100, weight.x);
        float c10 = mix(c010, c110, weight.x);
        float c01 = mix(c001, c101, weight.x);
        float c11 = mix(c011, c111, weight.x);
        float c0 = mix(c00, c10, weight.y);
        float c1 = mix(c01, c11, weight.y);
        return mix(c0, c1, weight.z);
    }

    static float3 calGradient(texture3d<short, access::sample> volume,
                              float3 coord,
                              float3 dimension)
    {
        if (dimension.x < 2.0f || dimension.y < 2.0f || dimension.z < 2.0f) {
            return float3(0.0f);
        }

        float3 invDim = float3(0.0f);
        invDim.x = dimension.x > 1.0f ? 1.0f / (dimension.x - 1.0f) : 0.0f;
        invDim.y = dimension.y > 1.0f ? 1.0f / (dimension.y - 1.0f) : 0.0f;
        invDim.z = dimension.z > 1.0f ? 1.0f / (dimension.z - 1.0f) : 0.0f;

        return calGradientWithStep(volume, coord, invDim);
    }

    static float3 calGradientWithStep(texture3d<short, access::sample> volume,
                                      float3 coord,
                                      float3 invDim)
    {
        if (any(invDim <= float3(0.0f))) {
            return float3(0.0f);
        }

        float sxPlus = sampleTrilinearDensity(volume, float3(min(coord.x + invDim.x, 1.0f), coord.y, coord.z));
        float sxMinus = sampleTrilinearDensity(volume, float3(max(coord.x - invDim.x, 0.0f), coord.y, coord.z));
        float syPlus = sampleTrilinearDensity(volume, float3(coord.x, min(coord.y + invDim.y, 1.0f), coord.z));
        float syMinus = sampleTrilinearDensity(volume, float3(coord.x, max(coord.y - invDim.y, 0.0f), coord.z));
        float szPlus = sampleTrilinearDensity(volume, float3(coord.x, coord.y, min(coord.z + invDim.z, 1.0f)));
        float szMinus = sampleTrilinearDensity(volume, float3(coord.x, coord.y, max(coord.z - invDim.z, 0.0f)));

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

    static short getDensity(texture3d<short, access::sample> volume, float3 coord)
    {
        return decodeInt16SampleToShort(volume.sample(sampler3d, coord).r);
    }

    static float getDensityTrilinear(texture3d<short, access::sample> volume, float3 coord)
    {
        return sampleTrilinearDensity(volume, coord);
    }

    static float3 getGradient(texture3d<float, access::sample> gradient, float3 coord)
    {
        return gradient.sample(sampler3d, coord).xyz;
    }

    static float4 getTfColour(texture2d<float, access::sample> tf,
                              float density)
    {
        return getTfColour(tf, density, 0.0f);
    }

    static float4 getTfColour(texture2d<float, access::sample> tf,
                              float density,
                              float gradientMagnitude)
    {
        const float densityCoord = clamp(density, 0.0f, 1.0f);
        const float gradientCoord = clamp(gradientMagnitude, 0.0f, 1.0f);
        const uint tfHeight = tf.get_height();

        if (tfHeight <= 1u) {
            return tf.sample(sampler2d, float2(densityCoord, 0.0f));
        }

        return tf.sample(sampler2d, float2(densityCoord, gradientCoord));
    }
};

#endif
