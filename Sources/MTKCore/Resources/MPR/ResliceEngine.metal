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

    // Phase 4 accuracy toggles (default-off for legacy parity)
    float3 spacingMM;        // voxel spacing em mm (x,y,z)
    float  slabThicknessMM;  // espessura física total do slab em mm
    int    usePhysicalWeighting; // 1 => usa passos físicos ao longo da normal
    int    useBoundsEpsilon;     // 1 => aplica margem de epsilon para bounds
    float  boundsEpsilon;        // margem adicional (ex.: 1e-4)
    float  _pad4;
    float3 volumeSizeMM;         // dimensão física total em mm (x,y,z)
    float  _pad5;
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

inline float sampleDensity01(texture3d<float, access::sample> volume, float3 p,
                             short minV, short maxV) {
    float hu = VR::getDensity(volume, p);
    return Util::normalize(hu, (float)minV, (float)maxV); // HU -> [0,1]
}

fragment float4 mpr_fragment(VSOut in                                       [[stage_in]],
                             constant SCNSceneBuffer& scn_frame              [[buffer(0)]],
                             constant NodeBuffer& scn_node                   [[buffer(1)]],
                             constant MPRUniforms& U                         [[buffer(4)]],
                             texture3d<float, access::sample> volume         [[texture(0)]]) {

    // Coord do plano no volume (normalizada)
    float vCoord = (U.flipVertical != 0) ? (1.0f - in.uv.y) : in.uv.y;
    float3 Pw = U.planeOrigin + in.uv.x * U.planeX + vCoord * U.planeY;

    // Fora do volume? (com pequena margem)
    if (any(Pw < -1e-6) || any(Pw > 1.0 + 1e-6)) {
        return float4(0,0,0,1);
    }

    const float eps = (U.useBoundsEpsilon != 0) ? U.boundsEpsilon : 0.0f;

    if (U.numSteps <= 1 || U.slabHalf <= 0.0f || U.blendMode == 0) {
        // MPR fino (uma amostra) OU modo single
        float3 PwClamped = clamp(Pw, float3(0.0f - eps), float3(1.0f + eps));
        float d = sampleDensity01(volume, PwClamped, (short)U.voxelMinValue, (short)U.voxelMaxValue);
        return float4(d, d, d, 1);
    }

    // Thick slab: percorre ao longo da normal do plano
    const int steps = max(2, U.numSteps);

    float vmax = 0.0f;
    float vmin = 1.0f;
    float vacc = 0.0f;
    float weightSum = 0.0f;
    int   cnt  = 0;

    if (U.usePhysicalWeighting == 0) {
        // Legado: offsets em coordenadas normalizadas
        float3 N = normalize(cross(U.planeX, U.planeY));
        float invStepsMinusOne = 1.0f / float(steps - 1);
        float slabSpan = 2.0f * U.slabHalf;

        for (int sampleIndex = 0; sampleIndex < steps; ++sampleIndex) {
            float normalizedIndex = float(sampleIndex) * invStepsMinusOne;
            float offset = (normalizedIndex - 0.5f) * slabSpan;
            float3 Pi = Pw + offset * N;
            if (any(Pi < (0.0f - eps)) || any(Pi > (1.0f + eps))) continue;
            float3 PiClamped = clamp(Pi, float3(0.0f), float3(1.0f));

            float d = sampleDensity01(volume, PiClamped, (short)U.voxelMinValue, (short)U.voxelMaxValue);
            vmax = max(vmax, d);
            vmin = min(vmin, d);
            vacc += d;
            weightSum += 1.0f;
            cnt++;
        }
    } else {
        // Precisão física: passos em mm ao longo da normal, respeitando anisotropia
        float3 sizeMM = max(U.volumeSizeMM, float3(1.0e-6f));
        float3 Ntex = normalize(cross(U.planeX, U.planeY));
        float3 Nmm = normalize(Ntex * sizeMM);
        float stepMM = (steps > 1) ? (U.slabThicknessMM / float(steps - 1)) : 0.0f;
        float invSizeMMx = 1.0f / sizeMM.x;
        float invSizeMMy = 1.0f / sizeMM.y;
        float invSizeMMz = 1.0f / sizeMM.z;

        for (int sampleIndex = 0; sampleIndex < steps; ++sampleIndex) {
            float offsetMM = (float(sampleIndex) - 0.5f * float(steps - 1)) * stepMM;
            float3 offsetTex = float3(Nmm.x * offsetMM * invSizeMMx,
                                      Nmm.y * offsetMM * invSizeMMy,
                                      Nmm.z * offsetMM * invSizeMMz);
            float3 Pi = Pw + offsetTex;
            if (any(Pi < (0.0f - eps)) || any(Pi > (1.0f + eps))) continue;
            float3 PiClamped = clamp(Pi, float3(0.0f), float3(1.0f));

            float d = sampleDensity01(volume, PiClamped, (short)U.voxelMinValue, (short)U.voxelMaxValue);
            float weight = max(stepMM, 0.0f);
            vmax = max(vmax, d);
            vmin = min(vmin, d);
            vacc += d * (weight > 0.0f ? weight : 1.0f);
            weightSum += (weight > 0.0f ? weight : 1.0f);
            cnt++;
        }
    }

    float val = 0.0f;
    switch (U.blendMode) {
        case 1: val = vmax; break;                          // MIP
        case 2: val = (cnt > 0 ? vmin : 0.0f); break;       // MinIP
        case 3: {
            float denom = (weightSum > 0.0f ? weightSum : float(cnt));
            val = (cnt > 0 && denom > 0.0f) ? (vacc / denom) : 0.0f;
            break;
        } // Mean
        default: // fallback single
            val = sampleDensity01(volume, Pw, (short)U.voxelMinValue, (short)U.voxelMaxValue);
    }

    return float4(val, val, val, 1);
}
