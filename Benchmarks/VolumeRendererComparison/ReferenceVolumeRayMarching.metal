#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct VolumeUniforms {
    float3 dimensions;
    float stepSize;
    float3 volumeScale;
    float yaw;
    float pitch;
    float zoom;
    float aspect;
    float slicePlaneFraction;
    float showSlicePlane;
    float backgroundMode;
    float padding;
};

vertex VertexOut volumeVertexMain(uint vertexID [[vertex_id]]) {
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = positions[vertexID] * 0.5 + 0.5;
    return out;
}

static float3 rotateVolume(float3 v, float yaw, float pitch) {
    float cy = cos(yaw);
    float sy = sin(yaw);
    float cp = cos(pitch);
    float sp = sin(pitch);

    float3 yRot = float3(cy * v.x + sy * v.z, v.y, -sy * v.x + cy * v.z);
    return float3(yRot.x, cp * yRot.y - sp * yRot.z, sp * yRot.y + cp * yRot.z);
}

static bool intersectBox(float3 origin, float3 direction, float3 halfExtent, thread float &tNear, thread float &tFar) {
    float3 invDirection = 1.0 / direction;
    float3 t0 = (-halfExtent - origin) * invDirection;
    float3 t1 = ( halfExtent - origin) * invDirection;
    float3 tMin = min(t0, t1);
    float3 tMax = max(t0, t1);
    tNear = max(max(tMin.x, tMin.y), tMin.z);
    tFar = min(min(tMax.x, tMax.y), tMax.z);
    return tFar > max(tNear, 0.0);
}

static float transferCoordinate(float hu) {
    return clamp((hu + 1200.0) / 4200.0, 0.0, 1.0);
}

fragment float4 volumeFragmentMain(
    VertexOut in [[stage_in]],
    constant VolumeUniforms &uniforms [[buffer(0)]],
    texture3d<half, access::sample> volumeTexture [[texture(0)]],
    texture2d<float, access::sample> transferTexture [[texture(1)]],
    sampler linearSampler [[sampler(0)]]
) {
    float2 ndc = in.uv * 2.0 - 1.0;
    float3 rayOrigin = rotateVolume(float3(0.0, 0.0, uniforms.zoom), uniforms.yaw, uniforms.pitch);
    float3 rayDirection = normalize(rotateVolume(float3(ndc.x * uniforms.aspect, ndc.y, -1.35), uniforms.yaw, uniforms.pitch));

    float tNear = 0.0;
    float tFar = 0.0;
    float3 volumeScale = max(uniforms.volumeScale, float3(0.001));
    float3 halfExtent = volumeScale * 0.5;
    if (!intersectBox(rayOrigin, rayDirection, halfExtent, tNear, tFar)) {
        return uniforms.backgroundMode > 0.5 ? float4(0.015, 0.018, 0.035, 1.0) : float4(0, 0, 0, 1);
    }

    float t = max(tNear, 0.0);
    float4 accumulated = float4(0.0);
    float3 lightDirection = normalize(float3(-0.45, 0.55, 0.7));
    float3 gradientStep = 1.0 / max(uniforms.dimensions, float3(1.0));

    for (int i = 0; i < 768 && t <= tFar && accumulated.a < 0.96; i++) {
        float3 p = rayOrigin + rayDirection * t;
        float3 texCoord = p / volumeScale + 0.5;
        float hu = float(volumeTexture.sample(linearSampler, texCoord).r);
        float4 tf = transferTexture.sample(linearSampler, float2(transferCoordinate(hu), 0.5));

        if (tf.a > 0.001) {
            float gx = float(volumeTexture.sample(linearSampler, texCoord + float3(gradientStep.x, 0, 0)).r)
                - float(volumeTexture.sample(linearSampler, texCoord - float3(gradientStep.x, 0, 0)).r);
            float gy = float(volumeTexture.sample(linearSampler, texCoord + float3(0, gradientStep.y, 0)).r)
                - float(volumeTexture.sample(linearSampler, texCoord - float3(0, gradientStep.y, 0)).r);
            float gz = float(volumeTexture.sample(linearSampler, texCoord + float3(0, 0, gradientStep.z)).r)
                - float(volumeTexture.sample(linearSampler, texCoord - float3(0, 0, gradientStep.z)).r);
            float3 normal = normalize(float3(gx, gy, gz) + 0.0001);
            float diffuse = clamp(dot(normal, lightDirection) * 0.5 + 0.5, 0.25, 1.0);
            float3 color = tf.rgb * diffuse;

            if (uniforms.showSlicePlane > 0.5) {
                float planeZ = (uniforms.slicePlaneFraction - 0.5) * volumeScale.z;
                float band = uniforms.stepSize * 2.0;
                if (abs(p.z - planeZ) < band) {
                    color = mix(color, float3(0.2, 0.65, 1.0), 0.45);
                    tf.a = max(tf.a, 0.18);
                }
            }

            float alpha = 1.0 - pow(max(1.0 - tf.a, 0.0), uniforms.stepSize * 180.0);
            accumulated.rgb += (1.0 - accumulated.a) * alpha * color;
            accumulated.a += (1.0 - accumulated.a) * alpha;
        }

        t += uniforms.stepSize;
    }

    float3 background = uniforms.backgroundMode > 0.5 ? float3(0.015, 0.018, 0.035) : float3(0.0);
    float3 outputColor = accumulated.rgb + background * (1.0 - accumulated.a);
    return float4(outputColor, 1.0);
}
