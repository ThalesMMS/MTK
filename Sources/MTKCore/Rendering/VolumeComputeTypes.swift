//
//  VolumeComputeTypes.swift
//  MTK
//
//  Host-side representations for the volume_compute Metal kernel.
//  Mirrors the layout defined in volume_rendering_types.metal.
//

import simd

struct VolumeUniforms: Sizeable {
    var isLightingOn: Int32 = 1
    var isBackwardOn: Int32 = 0
    var method: Int32 = 1
    var renderingQuality: Int32 = 512
    var voxelMinValue: Int32 = -1024
    var voxelMaxValue: Int32 = 3071
    var datasetMinValue: Int32 = -1024
    var datasetMaxValue: Int32 = 3071
    var densityFloor: Float = 0.02
    var densityCeil: Float = 1.0
    var gateHuMin: Int32 = -1024
    var gateHuMax: Int32 = 3071
    var useHuGate: Int32 = 0
    var dimX: Int32 = 1
    var dimY: Int32 = 1
    var dimZ: Int32 = 1
    var useTFProj: Int32 = 1
    var _pad0: Int32 = 0
    var _pad1: Int32 = 0
    var _pad2: Int32 = 0
}

struct PackedColor: Sizeable {
    var ch1: SIMD4<Float> = .zero
    var ch2: SIMD4<Float> = .zero
    var ch3: SIMD4<Float> = .zero
    var ch4: SIMD4<Float> = .zero
}

struct RenderingParameters: Sizeable {
    var material = VolumeUniforms()
    var scale: Float = 1
    var zScale: Float = 1
    var sliceNo: UInt16 = 0
    var sliceMax: UInt16 = 0
    var trimXMin: Float = 0
    var trimXMax: Float = 1
    var trimYMin: Float = 0
    var trimYMax: Float = 1
    var trimZMin: Float = 0
    var trimZMax: Float = 1
    var color = PackedColor()
    var cropLockQuaternions: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1)
    var clipBoxQuaternion: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1)
    var clipPlane0: SIMD4<Float> = .zero
    var clipPlane1: SIMD4<Float> = .zero
    var clipPlane2: SIMD4<Float> = .zero
    var cropSliceNo: UInt16 = 0
    var eulerX: Float = 0
    var eulerY: Float = 0
    var eulerZ: Float = 0
    var translationX: Float = 0
    var translationY: Float = 0
    var viewSize: UInt16 = 0
    var pointX: Float = 0
    var pointY: Float = 0
    var alphaPower: UInt8 = 1
    var renderingStep: Float = 1 / 512
    var earlyTerminationThreshold: Float = 0.99
    var adaptiveGradientThreshold: Float = 0.1
    var jitterAmount: Float = 0
    var intensityRatio: SIMD4<Float> = SIMD4<Float>(1, 0, 0, 0)
    var light: Float = 1
    var shade: Float = 1
    var dicomOrientationRow: SIMD4<Float> = SIMD4<Float>(1, 0, 0, 0)
    var dicomOrientationColumn: SIMD4<Float> = SIMD4<Float>(0, 1, 0, 0)
    var dicomOrientationNormal: SIMD4<Float> = SIMD4<Float>(0, 0, 1, 0)
    var dicomOrientationActive: UInt32 = 0
    var dicomOrientationPadding: SIMD3<UInt32> = .zero
    var renderingMethod: UInt8 = 1
    var backgroundColor: SIMD3<Float> = SIMD3<Float>(repeating: 0)
    var padding0: UInt8 = 0
    var padding1: UInt16 = 0
}

struct CameraUniforms: Sizeable {
    var modelMatrix: simd_float4x4 = matrix_identity_float4x4
    var inverseModelMatrix: simd_float4x4 = matrix_identity_float4x4
    var inverseViewProjectionMatrix: simd_float4x4 = matrix_identity_float4x4
    var cameraPositionLocal: SIMD3<Float> = .zero
    var frameIndex: UInt32 = 0
    var padding: UInt32 = 0
}
