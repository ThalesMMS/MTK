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
    var gradientSmoothness: Float = 0.0
    var usePreIntegratedTF: Int32 = 0
    var _pad1: Int32 = 0
    var _pad2: Int32 = 0
    // Per-mode early-exit thresholds
    var earlyExitMIP: Float = 1.0   // disabled by default for MIP/MinIP
    var earlyExitAvgIP: Float = 0.99
    var earlyExitFTB: Float = 0.99
    var _earlyExitPad: Float = 0.0

    // Reconstruction kernel and advanced flags (Phase 4)
    var samplingMethod: Int32 = 0 // 0=linear,1=cubic,2=lanczos2
    var occupancySkipEnabled: Int32 = 0
    var minMaxSkipEnabled: Int32 = 0
    var dualParameterTFEnabled: Int32 = 0
    var lightOcclusionEnabled: Int32 = 0
    var lightOcclusionStrength: Float = 0.0
    var _padAdv0: Float = 0.0
    var _padAdv1: Float = 0.0
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
    // Spacing (mm)
    var spacingX: Float = 1
    var spacingY: Float = 1
    var spacingZ: Float = 1
    var spacingPad: Float = 0
    // Adaptive step sizing
    var adaptiveStepMinScale: Float = 1.0
    var adaptiveStepMaxScale: Float = 1.0
    var adaptiveGradientScale: Float = 0.0
    var adaptiveFlatThreshold: Float = 0.0
    var adaptiveFlatBoost: Float = 1.0
    var minStepNormalized: Float = 0.0
    var preTFBlurRadius: Float = 0.0
    // Empty-space skipping controls
    var zeroRunThreshold: Float = 0.001
    var zeroRunLength: UInt16 = 4
    var zeroSkipDistance: UInt16 = 3
    var emptySpaceGradientThreshold: Float = 0.0
    var emptySpaceDensityThreshold: Float = 0.0
    var _emptySpacePad: UInt16 = 0

    // Occupancy grid (optional)
    var occupancyBrickDimX: UInt16 = 0
    var occupancyBrickDimY: UInt16 = 0
    var occupancyBrickDimZ: UInt16 = 0
    var occupancyInvBrickCountX: Float = 0
    var occupancyInvBrickCountY: Float = 0
    var occupancyInvBrickCountZ: Float = 0
    var _occupancyPad: Float = 0
}

struct CameraUniforms: Sizeable {
    var modelMatrix: simd_float4x4 = matrix_identity_float4x4
    var inverseModelMatrix: simd_float4x4 = matrix_identity_float4x4
    var inverseViewProjectionMatrix: simd_float4x4 = matrix_identity_float4x4
    var worldToTextureMatrix: simd_float4x4 = matrix_identity_float4x4      // SCTC: world (mm, LPS) -> texture [0,1]^3
    var textureToWorldMatrix: simd_float4x4 = matrix_identity_float4x4      // Inverse: texture [0,1]^3 -> world (mm, LPS)
    var cameraPositionLocal: SIMD3<Float> = .zero
    var frameIndex: UInt32 = 0
    var padding: SIMD3<UInt32> = .zero
}
