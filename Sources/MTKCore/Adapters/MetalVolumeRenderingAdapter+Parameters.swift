//
//  MetalVolumeRenderingAdapter+Parameters.swift
//  MTK
//
//  Parameter and camera helpers for the Metal volume rendering adapter.
//
//  Thales Matheus Mendonça Santos — April 2026

import Foundation
import simd

extension MetalVolumeRenderingAdapter {
    func buildRenderingParameters(for request: VolumeRenderRequest) throws -> RenderingParameters {
        var params = RenderingParameters()
        params.material = try buildVolumeUniforms(for: request)
        params.renderingStep = request.samplingDistance
        params.earlyTerminationThreshold = extendedState.earlyTerminationThreshold
        params.adaptiveGradientThreshold = extendedState.adaptiveThreshold
        params.jitterAmount = extendedState.jitterAmount
        params.intensityRatio = extendedState.channelIntensities
        let clip = extendedState.clipBounds
        params.trimXMin = clip.xMin
        params.trimXMax = clip.xMax
        params.trimYMin = clip.yMin
        params.trimYMax = clip.yMax
        params.trimZMin = clip.zMin
        params.trimZMax = clip.zMax
        let planes = clipPlanes(preset: extendedState.clipPlanePreset,
                                offset: extendedState.clipPlaneOffset)
        params.clipPlane0 = planes.0
        params.clipPlane1 = planes.1
        params.clipPlane2 = planes.2
        params.backgroundColor = SIMD3<Float>(repeating: 0)
        return params
    }

    func buildVolumeUniforms(for request: VolumeRenderRequest) throws -> VolumeUniforms {
        var uniforms = VolumeUniforms()
        let dataset = request.dataset
        let window = try resolveWindow(for: dataset)

        uniforms.voxelMinValue = window.lowerBound
        uniforms.voxelMaxValue = window.upperBound
        uniforms.datasetMinValue = dataset.intensityRange.lowerBound
        uniforms.datasetMaxValue = dataset.intensityRange.upperBound
        uniforms.dimX = Int32(dataset.dimensions.width)
        uniforms.dimY = Int32(dataset.dimensions.height)
        uniforms.dimZ = Int32(dataset.dimensions.depth)

        let rawSteps = Int(roundf(1.0 / max(request.samplingDistance, 1e-5)))
        uniforms.renderingQuality = Int32(VolumetricMath.sanitizeSteps(rawSteps))

        switch request.compositing {
        case .maximumIntensity:
            uniforms.method = 2
        case .minimumIntensity:
            uniforms.method = 3
        case .averageIntensity:
            uniforms.method = 4
        case .frontToBack:
            uniforms.method = 1
        }

        let lightingEnabled = overrides.lightingEnabled && extendedState.lightingEnabled
        uniforms.isLightingOn = lightingEnabled ? 1 : 0

        if let gate = extendedState.densityGate {
            uniforms.densityFloor = gate.lowerBound
            uniforms.densityCeil = gate.upperBound
            uniforms.useHuGate = 1
            uniforms.gateHuMin = Int32(gate.lowerBound)
            uniforms.gateHuMax = Int32(gate.upperBound)
        } else {
            uniforms.useHuGate = 0
        }

        uniforms.useTFProj = 1
        uniforms.isBackwardOn = 0
        return uniforms
    }

    func clipPlanes(preset: Int, offset: Float) -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        let planeOffset = -offset
        switch preset {
        case 1: // axial
            return (SIMD4<Float>(0, 0, 1, planeOffset), .zero, .zero)
        case 2: // sagittal
            return (SIMD4<Float>(1, 0, 0, planeOffset), .zero, .zero)
        case 3: // coronal
            return (SIMD4<Float>(0, 1, 0, planeOffset), .zero, .zero)
        default:
            return (.zero, .zero, .zero)
        }
    }

    func computeOptionFlags() -> UInt16 {
        extendedState.adaptiveEnabled ? (1 << 2) : 0
    }

    func encodeCamera(_ uniforms: CameraUniforms, into state: MetalState) {
        var localUniforms = uniforms
        let pointer = state.cameraBuffer.contents()
        memcpy(pointer, &localUniforms, CameraUniforms.stride)
    }

    func makeCameraUniforms(for request: VolumeRenderRequest,
                            viewportSize: (width: Int, height: Int),
                            frameIndex: UInt32) throws -> CameraUniforms {
        var camera = CameraUniforms()
        camera.modelMatrix = matrix_identity_float4x4
        camera.inverseModelMatrix = matrix_identity_float4x4
        camera.inverseViewProjectionMatrix = try makeInverseViewProjectionMatrix(camera: request.camera,
                                                                                 viewportSize: viewportSize)
        camera.cameraPositionLocal = request.camera.position
        camera.frameIndex = frameIndex
        camera.projectionType = request.camera.projectionType.rawValue
        return camera
    }

    func makeInverseViewProjectionMatrix(camera: VolumeRenderRequest.Camera,
                                         viewportSize: (width: Int, height: Int)) throws -> simd_float4x4 {
        let aspect = max(Float(viewportSize.width) / Float(viewportSize.height), 1e-3)
        let view = try simd_float4x4(lookAt: camera.position,
                                     target: camera.target,
                                     up: camera.up)

        let center = SIMD3<Float>(repeating: 0.5)
        let distanceToCenter = simd_length(camera.position - center)
        let farPadding = distanceToCenter * 0.1 + 1.0
        let nearZ: Float = 0.01
        let farZ = max(distanceToCenter + farPadding, nearZ + 100.0)

        let projection: simd_float4x4
        if camera.projectionType == .orthographic {
            let viewHeight: Float = 2.0
            let viewWidth = viewHeight * aspect
            projection = simd_float4x4(orthographicWidth: viewWidth,
                                       height: viewHeight,
                                       nearZ: nearZ,
                                       farZ: farZ)
        } else {
            projection = simd_float4x4(perspectiveFovY: max(camera.fieldOfView * .pi / 180, 0.01),
                                       aspect: aspect,
                                       nearZ: nearZ,
                                       farZ: farZ)
        }
        let matrix = projection * view

        if diagnosticLoggingEnabled {
            logger.info("[DIAG] View Matrix:\n\(view.debugDescription)")
            logger.info("[DIAG] Projection Matrix:\n\(projection.debugDescription)")
            logger.info("[DIAG] InvViewProj Matrix:\n\(simd_inverse(matrix).debugDescription)")
        }

        return simd_inverse(matrix)
    }
}

private extension simd_float4x4 {
    init(lookAt eye: SIMD3<Float>,
         target: SIMD3<Float>,
         up: SIMD3<Float>) throws {
        let zAxis = simd_normalize(eye - target)
        let xAxis = simd_normalize(simd_cross(up, zAxis))
        let yAxis = simd_cross(zAxis, xAxis)

        guard zAxis.allFinite, xAxis.allFinite, yAxis.allFinite else {
            throw MetalVolumeRenderingAdapter.AdapterError.degenerateCameraMatrix
        }

        let translation = SIMD3<Float>(
            -simd_dot(xAxis, eye),
            -simd_dot(yAxis, eye),
            -simd_dot(zAxis, eye)
        )

        self = simd_float4x4(columns: (
            SIMD4<Float>(xAxis, 0),
            SIMD4<Float>(yAxis, 0),
            SIMD4<Float>(zAxis, 0),
            SIMD4<Float>(translation, 1)
        ))
    }

    init(perspectiveFovY fovY: Float,
         aspect: Float,
         nearZ: Float,
         farZ: Float) {
        let yScale = 1 / tan(fovY * 0.5)
        let xScale = yScale / max(aspect, 1e-3)
        let zRange = farZ - nearZ
        let z = -(farZ + nearZ) / zRange
        let wz = -(2 * farZ * nearZ) / zRange

        self = simd_float4x4(columns: (
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, wz, 0)
        ))
    }

    init(orthographicWidth width: Float,
         height: Float,
         nearZ: Float,
         farZ: Float) {
        let range = farZ - nearZ

        self = simd_float4x4(columns: (
            SIMD4<Float>(2.0 / width, 0, 0, 0),
            SIMD4<Float>(0, 2.0 / height, 0, 0),
            SIMD4<Float>(0, 0, -2.0 / range, 0),
            SIMD4<Float>(0, 0, -(farZ + nearZ) / range, 1)
        ))
    }
}

private extension SIMD3 where Scalar == Float {
    var allFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}