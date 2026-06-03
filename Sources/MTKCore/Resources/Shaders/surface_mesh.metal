#include <metal_stdlib>
using namespace metal;

struct SurfaceMeshVertexIn {
    float3 position;
    float3 normal;
    float4 color;
    float3 texturePosition;
    float4 shadingControls;
    float4 renderFlags;
};

struct SurfaceMeshUniforms {
    float4x4 viewProjectionMatrix;
    float4 lightDirection;
    float4 cropMin;
    float4 cropMax;
    float4 clipPlane0;
    float4 clipPlane1;
    float4 clipPlane2;
};

struct SurfaceMeshVertexOut {
    float4 position [[position]];
    float3 normal;
    float4 color;
    float3 texturePosition;
    float4 shadingControls;
    float4 renderFlags;
};

vertex SurfaceMeshVertexOut surface_mesh_vertex(
    uint vertexID [[vertex_id]],
    const device SurfaceMeshVertexIn *vertices [[buffer(0)]],
    constant SurfaceMeshUniforms &uniforms [[buffer(1)]]
) {
    SurfaceMeshVertexIn input = vertices[vertexID];
    SurfaceMeshVertexOut output;
    output.position = uniforms.viewProjectionMatrix * float4(input.position, 1.0);
    output.normal = normalize(input.normal);
    output.color = input.color;
    output.texturePosition = input.texturePosition;
    output.shadingControls = input.shadingControls;
    output.renderFlags = input.renderFlags;
    return output;
}

fragment float4 surface_mesh_fragment(
    SurfaceMeshVertexOut input [[stage_in]],
    constant SurfaceMeshUniforms &uniforms [[buffer(1)]]
) {
    if (any(input.texturePosition < uniforms.cropMin.xyz) ||
        any(input.texturePosition > uniforms.cropMax.xyz)) {
        discard_fragment();
    }
    float3 centeredTexturePosition = input.texturePosition - float3(0.5f);
    float4 planes[3] = { uniforms.clipPlane0, uniforms.clipPlane1, uniforms.clipPlane2 };
    for (uint index = 0; index < 3; ++index) {
        float3 planeNormal = planes[index].xyz;
        if (all(planeNormal == float3(0.0f))) {
            continue;
        }
        if (dot(centeredTexturePosition, planeNormal) + planes[index].w > 0.0f) {
            discard_fragment();
        }
    }
    if (input.renderFlags.x < 0.5f) {
        return input.color;
    }

    float3 normal = normalize(input.normal);
    float3 lightDirection = normalize(-uniforms.lightDirection.xyz);
    float ambient = clamp(input.shadingControls.x, 0.0f, 1.0f);
    float diffuseWeight = clamp(input.shadingControls.y, 0.0f, 2.0f);
    float specularWeight = clamp(input.shadingControls.z, 0.0f, 1.0f);
    float shininess = clamp(input.shadingControls.w, 1.0f, 128.0f);
    float diffuse = max(dot(normal, lightDirection), 0.0f);
    float3 viewDirection = float3(0.0f, 0.0f, 1.0f);
    float3 halfVector = normalize(lightDirection + viewDirection);
    float specular = pow(max(dot(normal, halfVector), 0.0f), shininess);
    float3 shaded = input.color.rgb * (ambient + diffuseWeight * diffuse) +
        float3(specularWeight * specular);
    return float4(clamp(shaded, 0.0f, 1.0f), input.color.a);
}
