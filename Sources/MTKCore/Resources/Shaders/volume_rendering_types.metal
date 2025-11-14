#ifndef volume_rendering_types_metal
#define volume_rendering_types_metal

#include <metal_stdlib>
#include "../MPR/Shared.metal"

using namespace metal;

struct VolumeUniforms {
    int isLightingOn;
    int isBackwardOn;
    int method;
    int renderingQuality;
    int voxelMinValue;
    int voxelMaxValue;
    int datasetMinValue;
    int datasetMaxValue;
    float densityFloor;
    float densityCeil;
    int gateHuMin;
    int gateHuMax;
    int useHuGate;
    int dimX;
    int dimY;
    int dimZ;
    int useTFProj;
    int _pad0;
    int _pad1;
    int _pad2;
};

struct PackedColor {
    float4 ch1;
    float4 ch2;
    float4 ch3;
    float4 ch4;
};

struct RenderingParameters {
    VolumeUniforms material;
    float scale;
    float zScale;
    ushort sliceNo;
    ushort sliceMax;
    float trimXMin;
    float trimXMax;
    float trimYMin;
    float trimYMax;
    float trimZMin;
    float trimZMax;
    PackedColor color;
    float4 cropLockQuaternions;
    float4 clipBoxQuaternion;
    float4 clipPlane0;
    float4 clipPlane1;
    float4 clipPlane2;
    ushort cropSliceNo;
    float eulerX;
    float eulerY;
    float eulerZ;
    float translationX;
    float translationY;
    ushort viewSize;
    float pointX;
    float pointY;
    uchar alphaPower;
    float renderingStep;
    float earlyTerminationThreshold;
    float adaptiveGradientThreshold;
    float jitterAmount;
    float4 intensityRatio;
    float light;
    float shade;
    float4 dicomOrientationRow;
    float4 dicomOrientationColumn;
    float4 dicomOrientationNormal;
    uint dicomOrientationActive;
    uint3 dicomOrientationPadding;
    uchar renderingMethod;
    float3 backgroundColor;
    uchar padding0;
    ushort padding1;
};

struct CameraUniforms {
    float4x4 modelMatrix;
    float4x4 inverseModelMatrix;
    float4x4 inverseViewProjectionMatrix;
    float3   cameraPositionLocal;
    uint     frameIndex;
    uint     padding;
};

struct RenderingArguments {
    texture3d<short, access::sample> volumeTexture [[id(0)]];
    constant RenderingParameters &params           [[id(1)]];
    texture2d<float, access::write> outputTexture  [[id(2)]];
    device float *toneBufferCh1                    [[id(3)]];
    device float *toneBufferCh2                    [[id(4)]];
    device float *toneBufferCh3                    [[id(5)]];
    device float *toneBufferCh4                    [[id(6)]];
    constant ushort &optionValue                   [[id(7)]];
    constant float4 &quaternion                    [[id(8)]];
    constant ushort &targetViewSize                [[id(9)]];
    sampler volumeSampler                          [[id(10)]];
    constant ushort &pointSetCount                 [[id(11)]];
    constant ushort &pointSelectedIndex            [[id(12)]];
    constant float3 *pointSet                      [[id(13)]];
    device uint8_t *legacyOutputBuffer             [[id(14)]];
    texture2d<float, access::sample> transferTextureCh1 [[id(15)]];
    texture2d<float, access::sample> transferTextureCh2 [[id(16)]];
    texture2d<float, access::sample> transferTextureCh3 [[id(17)]];
    texture2d<float, access::sample> transferTextureCh4 [[id(18)]];
};

#endif
