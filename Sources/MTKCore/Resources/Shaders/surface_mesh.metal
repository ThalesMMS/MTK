#include <metal_stdlib>
using namespace metal;

struct SurfaceMeshVertexIn {
    float3 position;
    float3 normal;
    float4 color;
    float3 texturePosition;
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
    float3 normal = normalize(input.normal);
    float3 lightDirection = normalize(-uniforms.lightDirection.xyz);
    float lighting = 0.35 + 0.65 * max(dot(normal, lightDirection), 0.0);
    return float4(input.color.rgb * lighting, input.color.a);
}
