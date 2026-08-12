#include <metal_stdlib>

using namespace metal;

struct PresentationVertexOut {
    float4 position [[position]];
    float2 textureCoordinate;
};

vertex PresentationVertexOut presentation_vertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[] = {
        float2(-1.0f, -1.0f),
        float2(3.0f, -1.0f),
        float2(-1.0f, 3.0f)
    };
    constexpr float2 textureCoordinates[] = {
        float2(0.0f, 1.0f),
        float2(2.0f, 1.0f),
        float2(0.0f, -1.0f)
    };

    PresentationVertexOut output;
    output.position = float4(positions[vertexID], 0.0f, 1.0f);
    output.textureCoordinate = textureCoordinates[vertexID];
    return output;
}

fragment float4 presentation_linear_fragment(
    PresentationVertexOut input [[stage_in]],
    texture2d<float, access::sample> sourceTexture [[texture(0)]]) {
    constexpr sampler linearSampler(coord::normalized,
                                    address::clamp_to_edge,
                                    min_filter::linear,
                                    mag_filter::linear);
    return sourceTexture.sample(linearSampler, input.textureCoordinate);
}
