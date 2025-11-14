//
//  ResliceEngine.metal
//  MTK
//
//  MVP MPR Shader (Metal)
//  - Renderiza um plano de reamostragem dentro do volume (dicom 3D).
//  - Suporta MPR fino e thick slab com MIP/MinIP/Mean.
//  - Normalização HU -> [0,1] via min/max (mesma ideia do VR).
//  Thales Matheus Mendonça Santos — October 2025
//

#include <metal_stdlib>
#include "Shared.metal"   // traz NodeBuffer, SCNSceneBuffer, samplers e Utils

using namespace metal;

struct MPRUniforms {
    int   voxelMinValue;
    int   voxelMaxValue;
    int   blendMode;     // 0=single, 1=MIP, 2=MinIP, 3=Mean
    int   numSteps;      // >=1; 1 => MPR fino
    int   flipVertical;  // 1 => invert UV.y amostrada
    float slabHalf;      // metade da espessura em [0,1]
    float2 _pad0;

    float3 planeOrigin;  // origem do plano em [0,1]^3
    float  _pad1;
    float3 planeX;       // eixo U do plano (tamanho = largura em [0,1])
    float  _pad2;
    float3 planeY;       // eixo V do plano (tamanho = altura em [0,1])
    float  _pad3;
};

struct VertexIn {
    float3 position  [[attribute(SCNVertexSemanticPosition)]];
    float3 normal    [[attribute(SCNVertexSemanticNormal)]];
    float4 color     [[attribute(SCNVertexSemanticColor)]];
    float2 uv        [[attribute(SCNVertexSemanticTexcoord0)]];
};

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

vertex VSOut mpr_vertex(VertexIn in                   [[ stage_in ]],
                        constant NodeBuffer& scn_node [[ buffer(1) ]]) {
    VSOut out;
    out.position = Unity::ObjectToClipPos(float4(in.position, 1.0f), scn_node);
    out.uv = in.uv;
    return out;
}

inline float sampleDensity01(texture3d<short, access::sample> volume, float3 p,
                             short minV, short maxV) {
    short hu = volume.sample(sampler3d, p).r;
    return Util::normalize(hu, minV, maxV); // HU -> [0,1]
}

fragment float4 mpr_fragment(VSOut in                                       [[stage_in]],
                             constant SCNSceneBuffer& scn_frame              [[buffer(0)]],
                             constant NodeBuffer& scn_node                   [[buffer(1)]],
                             constant MPRUniforms& U                         [[buffer(4)]],
                             texture3d<short, access::sample> volume         [[texture(0)]]) {

    // Coord do plano no volume (normalizada)
    float vCoord = (U.flipVertical != 0) ? (1.0f - in.uv.y) : in.uv.y;
    float3 Pw = U.planeOrigin + in.uv.x * U.planeX + vCoord * U.planeY;

    // Fora do volume? (com pequena margem)
    if (any(Pw < -1e-6) || any(Pw > 1.0 + 1e-6)) {
        return float4(0,0,0,1);
    }

    if (U.numSteps <= 1 || U.slabHalf <= 0.0f || U.blendMode == 0) {
        // MPR fino (uma amostra) OU modo single
        float d = sampleDensity01(volume, Pw, (short)U.voxelMinValue, (short)U.voxelMaxValue);
        return float4(d, d, d, 1);
    }

    // Thick slab: percorre ao longo da normal do plano
    float3 N = normalize(cross(U.planeX, U.planeY));
    int steps = max(2, U.numSteps);
    float invStepsMinusOne = 1.0f / float(steps - 1);
    float slabSpan = 2.0f * U.slabHalf;

    float vmax = 0.0f;
    float vmin = 1.0f;
    float vacc = 0.0f;
    int   cnt  = 0;

    for (int sampleIndex = 0; sampleIndex < steps; ++sampleIndex) {
        float normalizedIndex = float(sampleIndex) * invStepsMinusOne;
        float offset = (normalizedIndex - 0.5f) * slabSpan;
        float3 Pi = Pw + offset * N;
        if (any(Pi < 0.0f) || any(Pi > 1.0f)) continue;

        float d = sampleDensity01(volume, Pi, (short)U.voxelMinValue, (short)U.voxelMaxValue);
        vmax = max(vmax, d);
        vmin = min(vmin, d);
        vacc += d;
        cnt++;
    }

    float val = 0.0f;
    switch (U.blendMode) {
        case 1: val = vmax; break;                          // MIP
        case 2: val = (cnt > 0 ? vmin : 0.0f); break;       // MinIP
        case 3: val = (cnt > 0 ? (vacc / float(cnt)) : 0.0f); break; // Mean
        default: // fallback single
            val = sampleDensity01(volume, Pw, (short)U.voxelMinValue, (short)U.voxelMaxValue);
    }

    return float4(val, val, val, 1);
}
