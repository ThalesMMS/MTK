//
//  mpr_presentation.metal
//  MTK
//
//  Window/level presentation for raw MPR intensity textures.
//

#include <metal_stdlib>

using namespace metal;

struct MPRPresentationUniforms {
    int windowMin;
    int windowMax;
    int invert;
    int useColormap;
    int flipHorizontal;
    int flipVertical;
    int bitShift;
    int transposeUV;
    float viewportZoom;
    float viewportPanX;
    float viewportPanY;
    float viewportRotationCos;
    float viewportRotationSin;
    float sourceAspectRatio;
    float _pad2;
    float _pad3;
    float imageOriginX;
    float imageOriginY;
    float imageWidth;
    float imageHeight;
    int shutterMode;
    int _pad4;
    int _pad5;
    int _pad6;
    float shutterMinX;
    float shutterMinY;
    float shutterMaxX;
    float shutterMaxY;
    float shutterCenterX;
    float shutterCenterY;
    float shutterRadius;
    float _pad7;
    float3 planeOriginTexture;
    float _pad8;
    float3 planeAxisUTexture;
    float _pad9;
    float3 planeAxisVTexture;
    float _pad10;
    int shadingEnabled;
    float shadingAmbient;
    float shadingDiffuse;
    float shadingSpecular;
    float shadingGradientScaleU;
    float shadingGradientScaleV;
    float _pad11;
    float _pad12;
};

struct MPRLabelmapOverlayUniforms {
    float opacity;
    float3 _pad0;
    float3 originTexture;
    float _pad1;
    float3 axisUTexture;
    float _pad2;
    float3 axisVTexture;
    float _pad3;
    int flipHorizontal;
    int flipVertical;
    int transposeUV;
    float viewportZoom;
    float viewportPanX;
    float viewportPanY;
    float viewportRotationCos;
    float viewportRotationSin;
    float sourceAspectRatio;
    float _pad6;
    float imageOriginX;
    float imageOriginY;
    float imageWidth;
    float imageHeight;
};

struct MPRScalarOverlayUniforms {
    float opacity;
    float intensityMin;
    float intensityMax;
    int blendMode;
    float3 originTexture;
    float _pad0;
    float3 axisUTexture;
    float _pad1;
    float3 axisVTexture;
    float _pad2;
    int flipHorizontal;
    int flipVertical;
    int transposeUV;
    float viewportZoom;
    float viewportPanX;
    float viewportPanY;
    float viewportRotationCos;
    float viewportRotationSin;
    float sourceAspectRatio;
    float _pad5;
    float imageOriginX;
    float imageOriginY;
    float imageWidth;
    float imageHeight;
};

namespace {
inline float normalizeWindow(int value, constant MPRPresentationUniforms& uniforms) {
    int lower = min(uniforms.windowMin, uniforms.windowMax);
    int upper = max(uniforms.windowMin, uniforms.windowMax);
    float span = max(float(upper - lower), 1.0f);
    float normalized = clamp((float(value) - float(lower)) / span, 0.0f, 1.0f);
    return uniforms.invert != 0 ? 1.0f - normalized : normalized;
}

inline float normalizeWindow(float value, constant MPRPresentationUniforms& uniforms) {
    int lower = min(uniforms.windowMin, uniforms.windowMax);
    int upper = max(uniforms.windowMin, uniforms.windowMax);
    float span = max(float(upper - lower), 1.0f);
    float normalized = clamp((value - float(lower)) / span, 0.0f, 1.0f);
    return uniforms.invert != 0 ? 1.0f - normalized : normalized;
}

inline float2 normalizedCoordinates(uint2 gid, uint width, uint height) {
    return float2(width > 1 ? float(gid.x) / float(width - 1) : 0.0f,
                  height > 1 ? float(gid.y) / float(height - 1) : 0.0f);
}

inline float2 inverseViewportTransform(float2 outputUV,
                                       float zoom,
                                       float2 pan,
                                       float rotationCos,
                                       float rotationSin,
                                       float sourceAspectRatio) {
    // Keep this inverse identical to MPRViewportTransform's aspect-aware rotated-bounds mapping.
    // 0.25 mirrors MPRViewportTransform.minimumZoom (zoom-out below fit is allowed).
    float safeZoom = max(zoom, 0.25f);
    float safeSourceAspectRatio = max(sourceAspectRatio, 1e-6f);
    float2 sourceSize = float2(safeSourceAspectRatio, 1.0f);
    float2 rotatedBounds = float2(
        abs(rotationCos) * sourceSize.x + abs(rotationSin) * sourceSize.y,
        abs(rotationSin) * sourceSize.x + abs(rotationCos) * sourceSize.y
    );
    float2 centered = (outputUV - float2(0.5f) - pan) * max(rotatedBounds, float2(1e-6f));
    float2 rotated = float2(centered.x * rotationCos + centered.y * rotationSin,
                            -centered.x * rotationSin + centered.y * rotationCos);
    return float2(0.5f) + (rotated / safeZoom) / sourceSize;
}

inline bool isInUnitSquare(float2 position) {
    constexpr float epsilon = 1e-5f;
    return all(position >= -epsilon) && all(position <= 1.0f + epsilon);
}

inline bool passesPresentationShutter(float2 sourceUV,
                                      constant MPRPresentationUniforms& uniforms) {
    if (uniforms.shutterMode == 1) {
        return sourceUV.x >= uniforms.shutterMinX
            && sourceUV.x <= uniforms.shutterMaxX
            && sourceUV.y >= uniforms.shutterMinY
            && sourceUV.y <= uniforms.shutterMaxY;
    }
    if (uniforms.shutterMode == 2) {
        float2 delta = sourceUV - float2(uniforms.shutterCenterX, uniforms.shutterCenterY);
        return length(delta) <= max(uniforms.shutterRadius, 0.0f);
    }
    return true;
}

inline float2 imageCoordinates(float2 outputUV,
                               float2 imageOrigin,
                               float2 imageSize) {
    float2 safeSize = max(imageSize, float2(1e-6f));
    return (outputUV - imageOrigin) / safeSize;
}

inline float2 sourceCoordinates(float2 outputUV,
                                int flipHorizontal,
                                int flipVertical,
                                int transposeUV,
                                float viewportZoom,
                                float2 viewportPan,
                                float viewportRotationCos,
                                float viewportRotationSin,
                                float sourceAspectRatio,
                                float2 imageOrigin,
                                float2 imageSize) {
    float2 imageUV = imageCoordinates(outputUV, imageOrigin, imageSize);
    float2 sourceUV = inverseViewportTransform(imageUV,
                                               viewportZoom,
                                               viewportPan,
                                               viewportRotationCos,
                                               viewportRotationSin,
                                               sourceAspectRatio);
    if (!isInUnitSquare(sourceUV)) {
        return sourceUV;
    }
    
    if (flipHorizontal != 0) {
        sourceUV.x = 1.0f - sourceUV.x;
    }
    if (flipVertical != 0) {
        sourceUV.y = 1.0f - sourceUV.y;
    }
    if (transposeUV != 0) {
        sourceUV = sourceUV.yx;
    }
    return sourceUV;
}

inline float2 sourceCoordinates(uint2 outputGid,
                                uint width,
                                uint height,
                                constant MPRPresentationUniforms& uniforms) {
    return sourceCoordinates(normalizedCoordinates(outputGid, width, height),
                             uniforms.flipHorizontal,
                             uniforms.flipVertical,
                             uniforms.transposeUV,
                             uniforms.viewportZoom,
                             float2(uniforms.viewportPanX, uniforms.viewportPanY),
                             uniforms.viewportRotationCos,
                             uniforms.viewportRotationSin,
                             uniforms.sourceAspectRatio,
                             float2(uniforms.imageOriginX, uniforms.imageOriginY),
                             float2(uniforms.imageWidth, uniforms.imageHeight));
}

inline float2 sourceCoordinates(uint2 outputGid,
                                uint width,
                                uint height,
                                constant MPRLabelmapOverlayUniforms& uniforms) {
    return sourceCoordinates(normalizedCoordinates(outputGid, width, height),
                             uniforms.flipHorizontal,
                             uniforms.flipVertical,
                             uniforms.transposeUV,
                             uniforms.viewportZoom,
                             float2(uniforms.viewportPanX, uniforms.viewportPanY),
                             uniforms.viewportRotationCos,
                             uniforms.viewportRotationSin,
                             uniforms.sourceAspectRatio,
                             float2(uniforms.imageOriginX, uniforms.imageOriginY),
                             float2(uniforms.imageWidth, uniforms.imageHeight));
}

inline float2 sourceCoordinates(uint2 outputGid,
                                uint width,
                                uint height,
                                constant MPRScalarOverlayUniforms& uniforms) {
    return sourceCoordinates(normalizedCoordinates(outputGid, width, height),
                             uniforms.flipHorizontal,
                             uniforms.flipVertical,
                             uniforms.transposeUV,
                             uniforms.viewportZoom,
                             float2(uniforms.viewportPanX, uniforms.viewportPanY),
                             uniforms.viewportRotationCos,
                             uniforms.viewportRotationSin,
                             uniforms.sourceAspectRatio,
                             float2(uniforms.imageOriginX, uniforms.imageOriginY),
                             float2(uniforms.imageWidth, uniforms.imageHeight));
}

inline uint2 nearestPixel(float2 uv, uint width, uint height) {
    return uint2(uint(round(clamp(uv.x, 0.0f, 1.0f) * float(max(width, 1u) - 1u))),
                 uint(round(clamp(uv.y, 0.0f, 1.0f) * float(max(height, 1u) - 1u))));
}

inline float4 presentationColor(float normalized,
                                texture2d<float, access::sample> colormap,
                                constant MPRPresentationUniforms& uniforms) {
    if (uniforms.useColormap != 0) {
        constexpr sampler colormapSampler(coord::normalized,
                                          address::clamp_to_edge,
                                          filter::linear);
        float4 color = colormap.sample(colormapSampler, float2(normalized, 0.5f));
        return float4(color.rgb, color.a);
    }
    return float4(normalized, normalized, normalized, 1.0f);
}

inline int shiftedValue(short value, constant MPRPresentationUniforms& uniforms) {
    int shifted = int(value);
    if (uniforms.bitShift > 0) {
        shifted >>= uniforms.bitShift;
    }
    return shifted;
}

inline int shiftedValue(ushort value, constant MPRPresentationUniforms& uniforms) {
    int shifted = int(value);
    if (uniforms.bitShift > 0) {
        shifted >>= uniforms.bitShift;
    }
    return shifted;
}

inline float normalizedValue(texture2d<short, access::read> inputTexture,
                             uint2 gid,
                             constant MPRPresentationUniforms& uniforms) {
    return normalizeWindow(shiftedValue(inputTexture.read(gid).r, uniforms), uniforms);
}

inline float normalizedValue(texture2d<ushort, access::read> inputTexture,
                             uint2 gid,
                             constant MPRPresentationUniforms& uniforms) {
    return normalizeWindow(shiftedValue(inputTexture.read(gid).r, uniforms), uniforms);
}

inline float shadingFactor(float left,
                           float right,
                           float up,
                           float down,
                           constant MPRPresentationUniforms& uniforms) {
    constexpr float shininess = 24.0f;
    float3 normal = normalize(float3((left - right) * uniforms.shadingGradientScaleU,
                                     (up - down) * uniforms.shadingGradientScaleV,
                                     1.0f));
    constexpr float3 lightDirection = float3(0.0f, 0.0f, 1.0f);
    float diffuse = max(dot(normal, lightDirection), 0.0f);
    float specular = pow(diffuse, shininess);
    return max(uniforms.shadingAmbient
               + uniforms.shadingDiffuse * diffuse
               + uniforms.shadingSpecular * specular,
               0.0f);
}

template<typename Scalar>
inline float4 shadedPresentationColor(texture2d<Scalar, access::read> inputTexture,
                                      uint2 sourceGid,
                                      texture2d<float, access::sample> colormap,
                                      constant MPRPresentationUniforms& uniforms) {
    float normalized = normalizedValue(inputTexture, sourceGid, uniforms);
    float4 color = presentationColor(normalized, colormap, uniforms);
    if (uniforms.shadingEnabled == 0) {
        return color;
    }

    uint2 upperBounds = uint2(inputTexture.get_width() - 1, inputTexture.get_height() - 1);
    uint2 leftGid = uint2(sourceGid.x > 0 ? sourceGid.x - 1 : 0, sourceGid.y);
    uint2 rightGid = uint2(min(sourceGid.x + 1, upperBounds.x), sourceGid.y);
    uint2 upGid = uint2(sourceGid.x, sourceGid.y > 0 ? sourceGid.y - 1 : 0);
    uint2 downGid = uint2(sourceGid.x, min(sourceGid.y + 1, upperBounds.y));
    float lighting = shadingFactor(float(shiftedValue(inputTexture.read(leftGid).r, uniforms)),
                                   float(shiftedValue(inputTexture.read(rightGid).r, uniforms)),
                                   float(shiftedValue(inputTexture.read(upGid).r, uniforms)),
                                   float(shiftedValue(inputTexture.read(downGid).r, uniforms)),
                                   uniforms);
    return float4(min(color.rgb * lighting, float3(1.0f)), color.a);
}

template<typename Scalar>
inline float convolvedRawValue(texture2d<Scalar, access::read> inputTexture,
                               uint2 sourceGid,
                               constant MPRPresentationUniforms& uniforms,
                               constant float* convolutionWeights,
                               uint convolutionSize) {
    int radius = int(convolutionSize / 2u);
    int2 upperBounds = int2(int(inputTexture.get_width()) - 1,
                            int(inputTexture.get_height()) - 1);
    float value = 0.0f;
    for (uint row = 0; row < convolutionSize; ++row) {
        for (uint column = 0; column < convolutionSize; ++column) {
            int2 offset = int2(int(column) - radius, int(row) - radius);
            uint2 sampleGid = uint2(clamp(int2(sourceGid) + offset,
                                          int2(0),
                                          upperBounds));
            value += float(shiftedValue(inputTexture.read(sampleGid).r, uniforms))
                   * convolutionWeights[row * convolutionSize + column];
        }
    }
    return value;
}

template<typename Scalar>
inline float4 convolvedPresentationColor(texture2d<Scalar, access::read> inputTexture,
                                         uint2 sourceGid,
                                         texture2d<float, access::sample> colormap,
                                         constant MPRPresentationUniforms& uniforms,
                                         constant float* convolutionWeights,
                                         uint convolutionSize) {
    float rawValue = convolvedRawValue(inputTexture,
                                       sourceGid,
                                       uniforms,
                                       convolutionWeights,
                                       convolutionSize);
    float4 color = presentationColor(normalizeWindow(rawValue, uniforms), colormap, uniforms);
    if (uniforms.shadingEnabled == 0) {
        return color;
    }

    uint2 upperBounds = uint2(inputTexture.get_width() - 1, inputTexture.get_height() - 1);
    uint2 leftGid = uint2(sourceGid.x > 0 ? sourceGid.x - 1 : 0, sourceGid.y);
    uint2 rightGid = uint2(min(sourceGid.x + 1, upperBounds.x), sourceGid.y);
    uint2 upGid = uint2(sourceGid.x, sourceGid.y > 0 ? sourceGid.y - 1 : 0);
    uint2 downGid = uint2(sourceGid.x, min(sourceGid.y + 1, upperBounds.y));
    float lighting = shadingFactor(
        float(shiftedValue(inputTexture.read(leftGid).r, uniforms)),
        float(shiftedValue(inputTexture.read(rightGid).r, uniforms)),
        float(shiftedValue(inputTexture.read(upGid).r, uniforms)),
        float(shiftedValue(inputTexture.read(downGid).r, uniforms)),
        uniforms
    );
    return float4(min(color.rgb * lighting, float3(1.0f)), color.a);
}

inline bool isInUnitCube(float3 position) {
    return all(position >= 0.0f) && all(position <= 1.0f);
}

inline bool isInVolumeBounds(float3 position) {
    constexpr float epsilon = 1e-6f;
    return all(position >= -epsilon) && all(position <= 1.0f + epsilon);
}

inline float normalizedScalarOverlayValue(int value,
                                          constant MPRScalarOverlayUniforms& uniforms) {
    float lower = uniforms.intensityMin;
    float upper = uniforms.intensityMax;
    if (upper <= lower) {
        return 0.0f;
    }
    return clamp((float(value) - lower) / (upper - lower), 0.0f, 1.0f);
}

inline float4 compositeScalarOverlay(float4 base,
                                     int storedValue,
                                     texture2d<float, access::sample> colorLUTTexture,
                                     constant MPRScalarOverlayUniforms& uniforms) {
    float opacity = clamp(uniforms.opacity, 0.0f, 1.0f);
    if (opacity <= 0.0f) {
        return base;
    }

    constexpr sampler lutSampler(coord::normalized,
                                 address::clamp_to_edge,
                                 filter::linear);
    float normalized = normalizedScalarOverlayValue(storedValue, uniforms);
    float4 overlay = colorLUTTexture.sample(lutSampler, float2(normalized, 0.5f));
    float alpha = clamp(overlay.a * opacity, 0.0f, 1.0f);
    if (alpha <= 0.0f) {
        return base;
    }

    float3 rgb;
    if (uniforms.blendMode == 1) {
        rgb = min(base.rgb + overlay.rgb * alpha, float3(1.0f));
    } else {
        rgb = mix(base.rgb, overlay.rgb, alpha);
    }
    float outAlpha = base.a + alpha * (1.0f - base.a);
    return float4(rgb, outAlpha);
}
}

kernel void mprPresentation(texture2d<short, access::read> inputTexture      [[texture(0)]],
                            texture2d<float, access::write> outputTexture    [[texture(1)]],
                            texture2d<float, access::sample> colormapTexture [[texture(2)]],
                            constant MPRPresentationUniforms& uniforms       [[buffer(0)]],
                            uint2 gid                                        [[thread_position_in_grid]]) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    float2 sourceUV = sourceCoordinates(gid,
                                        outputTexture.get_width(),
                                        outputTexture.get_height(),
                                        uniforms);
    if (!isInUnitSquare(sourceUV)) {
        outputTexture.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
        return;
    }
    float3 volumePosition = uniforms.planeOriginTexture
                          + sourceUV.x * uniforms.planeAxisUTexture
                          + sourceUV.y * uniforms.planeAxisVTexture;
    if (!isInVolumeBounds(volumePosition)) {
        outputTexture.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
        return;
    }
    if (!passesPresentationShutter(sourceUV, uniforms)) {
        outputTexture.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
        return;
    }

    uint2 sourceGid = nearestPixel(sourceUV, inputTexture.get_width(), inputTexture.get_height());
    outputTexture.write(shadedPresentationColor(inputTexture, sourceGid, colormapTexture, uniforms), gid);
}

kernel void mprCompositeLabelmapOverlay(texture2d<float, access::read> inputTexture      [[texture(0)]],
                                        texture2d<float, access::write> outputTexture    [[texture(1)]],
                                        texture3d<ushort, access::sample> labelmapTexture [[texture(2)]],
                                        texture2d<float, access::read> colorLUTTexture    [[texture(3)]],
                                        constant MPRLabelmapOverlayUniforms& uniforms     [[buffer(0)]],
                                        uint2 gid                                         [[thread_position_in_grid]]) {
    uint width = outputTexture.get_width();
    uint height = outputTexture.get_height();
    if (gid.x >= width || gid.y >= height) {
        return;
    }

    float4 base = inputTexture.read(gid);
    float opacity = clamp(uniforms.opacity, 0.0f, 1.0f);
    if (opacity <= 0.0f) {
        outputTexture.write(base, gid);
        return;
    }

    float2 sampleUV = sourceCoordinates(gid, width, height, uniforms);
    if (!isInUnitSquare(sampleUV)) {
        outputTexture.write(base, gid);
        return;
    }
    
    float3 labelmapPosition = uniforms.originTexture
                            + sampleUV.x * uniforms.axisUTexture
                            + sampleUV.y * uniforms.axisVTexture;

    if (!isInUnitCube(labelmapPosition)) {
        outputTexture.write(base, gid);
        return;
    }

    constexpr sampler labelmapSampler(coord::normalized,
                                      address::clamp_to_edge,
                                      filter::nearest);
    ushort label = labelmapTexture.sample(labelmapSampler, labelmapPosition).r;
    if (label == 0) {
        outputTexture.write(base, gid);
        return;
    }

    uint labelIndex = uint(label);
    uint lutX = labelIndex & 255u;
    uint lutY = labelIndex >> 8u;
    if (lutX >= colorLUTTexture.get_width() || lutY >= colorLUTTexture.get_height()) {
        outputTexture.write(base, gid);
        return;
    }

    float4 overlay = colorLUTTexture.read(uint2(lutX, lutY));
    float alpha = clamp(overlay.a * opacity, 0.0f, 1.0f);
    if (alpha <= 0.0f) {
        outputTexture.write(base, gid);
        return;
    }

    float3 rgb = mix(base.rgb, overlay.rgb, alpha);
    float outAlpha = base.a + alpha * (1.0f - base.a);
    outputTexture.write(float4(rgb, outAlpha), gid);
}

kernel void mprCompositeScalarOverlay(texture2d<float, access::read> inputTexture       [[texture(0)]],
                                      texture2d<float, access::write> outputTexture     [[texture(1)]],
                                      texture3d<short, access::sample> scalarTexture    [[texture(2)]],
                                      texture2d<float, access::sample> colorLUTTexture  [[texture(3)]],
                                      constant MPRScalarOverlayUniforms& uniforms       [[buffer(0)]],
                                      uint2 gid                                         [[thread_position_in_grid]]) {
    uint width = outputTexture.get_width();
    uint height = outputTexture.get_height();
    if (gid.x >= width || gid.y >= height) {
        return;
    }

    float4 base = inputTexture.read(gid);
    float2 sampleUV = sourceCoordinates(gid, width, height, uniforms);
    if (!isInUnitSquare(sampleUV)) {
        outputTexture.write(base, gid);
        return;
    }

    float3 scalarPosition = uniforms.originTexture
                          + sampleUV.x * uniforms.axisUTexture
                          + sampleUV.y * uniforms.axisVTexture;
    if (!isInUnitCube(scalarPosition)) {
        outputTexture.write(base, gid);
        return;
    }

    constexpr sampler scalarSampler(coord::normalized,
                                    address::clamp_to_edge,
                                    filter::nearest);
    int storedValue = int(scalarTexture.sample(scalarSampler, scalarPosition).r);
    outputTexture.write(compositeScalarOverlay(base, storedValue, colorLUTTexture, uniforms), gid);
}

kernel void mprCompositeScalarOverlayUnsigned(texture2d<float, access::read> inputTexture       [[texture(0)]],
                                              texture2d<float, access::write> outputTexture     [[texture(1)]],
                                              texture3d<ushort, access::sample> scalarTexture   [[texture(2)]],
                                              texture2d<float, access::sample> colorLUTTexture  [[texture(3)]],
                                              constant MPRScalarOverlayUniforms& uniforms       [[buffer(0)]],
                                              uint2 gid                                         [[thread_position_in_grid]]) {
    uint width = outputTexture.get_width();
    uint height = outputTexture.get_height();
    if (gid.x >= width || gid.y >= height) {
        return;
    }

    float4 base = inputTexture.read(gid);
    float2 sampleUV = sourceCoordinates(gid, width, height, uniforms);
    if (!isInUnitSquare(sampleUV)) {
        outputTexture.write(base, gid);
        return;
    }

    float3 scalarPosition = uniforms.originTexture
                          + sampleUV.x * uniforms.axisUTexture
                          + sampleUV.y * uniforms.axisVTexture;
    if (!isInUnitCube(scalarPosition)) {
        outputTexture.write(base, gid);
        return;
    }

    constexpr sampler scalarSampler(coord::normalized,
                                    address::clamp_to_edge,
                                    filter::nearest);
    int storedValue = int(scalarTexture.sample(scalarSampler, scalarPosition).r);
    outputTexture.write(compositeScalarOverlay(base, storedValue, colorLUTTexture, uniforms), gid);
}

kernel void mprPresentationUnsigned(texture2d<ushort, access::read> inputTexture  [[texture(0)]],
                                    texture2d<float, access::write> outputTexture [[texture(1)]],
                                    texture2d<float, access::sample> colormapTexture [[texture(2)]],
                                    constant MPRPresentationUniforms& uniforms    [[buffer(0)]],
                                    uint2 gid                                     [[thread_position_in_grid]]) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    float2 sourceUV = sourceCoordinates(gid,
                                        outputTexture.get_width(),
                                        outputTexture.get_height(),
                                        uniforms);
    if (!isInUnitSquare(sourceUV)) {
        outputTexture.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
        return;
    }
    float3 volumePosition = uniforms.planeOriginTexture
                          + sourceUV.x * uniforms.planeAxisUTexture
                          + sourceUV.y * uniforms.planeAxisVTexture;
    if (!isInVolumeBounds(volumePosition)) {
        outputTexture.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
        return;
    }
    if (!passesPresentationShutter(sourceUV, uniforms)) {
        outputTexture.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
        return;
    }

    uint2 sourceGid = nearestPixel(sourceUV, inputTexture.get_width(), inputTexture.get_height());
    outputTexture.write(shadedPresentationColor(inputTexture, sourceGid, colormapTexture, uniforms), gid);
}

kernel void mprPresentationConvolved(
    texture2d<short, access::read> inputTexture                [[texture(0)]],
    texture2d<float, access::write> outputTexture              [[texture(1)]],
    texture2d<float, access::sample> colormapTexture           [[texture(2)]],
    constant MPRPresentationUniforms& uniforms                 [[buffer(0)]],
    constant float* convolutionWeights                        [[buffer(1)]],
    constant uint& convolutionSize                            [[buffer(2)]],
    uint2 gid                                                  [[thread_position_in_grid]]) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    float2 sourceUV = sourceCoordinates(gid,
                                        outputTexture.get_width(),
                                        outputTexture.get_height(),
                                        uniforms);
    if (!isInUnitSquare(sourceUV)) {
        outputTexture.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
        return;
    }
    float3 volumePosition = uniforms.planeOriginTexture
                          + sourceUV.x * uniforms.planeAxisUTexture
                          + sourceUV.y * uniforms.planeAxisVTexture;
    if (!isInVolumeBounds(volumePosition)) {
        outputTexture.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
        return;
    }
    if (!passesPresentationShutter(sourceUV, uniforms)) {
        outputTexture.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
        return;
    }

    uint2 sourceGid = nearestPixel(sourceUV, inputTexture.get_width(), inputTexture.get_height());
    outputTexture.write(convolvedPresentationColor(inputTexture,
                                                    sourceGid,
                                                    colormapTexture,
                                                    uniforms,
                                                    convolutionWeights,
                                                    convolutionSize),
                        gid);
}

kernel void mprPresentationUnsignedConvolved(
    texture2d<ushort, access::read> inputTexture               [[texture(0)]],
    texture2d<float, access::write> outputTexture              [[texture(1)]],
    texture2d<float, access::sample> colormapTexture           [[texture(2)]],
    constant MPRPresentationUniforms& uniforms                 [[buffer(0)]],
    constant float* convolutionWeights                        [[buffer(1)]],
    constant uint& convolutionSize                            [[buffer(2)]],
    uint2 gid                                                  [[thread_position_in_grid]]) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    float2 sourceUV = sourceCoordinates(gid,
                                        outputTexture.get_width(),
                                        outputTexture.get_height(),
                                        uniforms);
    if (!isInUnitSquare(sourceUV)) {
        outputTexture.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
        return;
    }
    float3 volumePosition = uniforms.planeOriginTexture
                          + sourceUV.x * uniforms.planeAxisUTexture
                          + sourceUV.y * uniforms.planeAxisVTexture;
    if (!isInVolumeBounds(volumePosition)) {
        outputTexture.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
        return;
    }
    if (!passesPresentationShutter(sourceUV, uniforms)) {
        outputTexture.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
        return;
    }

    uint2 sourceGid = nearestPixel(sourceUV, inputTexture.get_width(), inputTexture.get_height());
    outputTexture.write(convolvedPresentationColor(inputTexture,
                                                    sourceGid,
                                                    colormapTexture,
                                                    uniforms,
                                                    convolutionWeights,
                                                    convolutionSize),
                        gid);
}
