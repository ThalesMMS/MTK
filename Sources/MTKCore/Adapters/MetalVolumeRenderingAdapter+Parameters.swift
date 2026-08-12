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
    func buildRenderingParameters(for request: VolumeRenderRequest,
                                  window: ClosedRange<Int32>? = nil) throws -> RenderingParameters {
        var params = RenderingParameters()
        params.material = try buildVolumeUniforms(for: request, window: window)
        let renderQualitySettings = request.renderQualitySettings.sanitized
        params.scale = renderQualitySettings.depthGradientScale
        params.light = Float(renderQualitySettings.directionalLightIntensity)
        params.shade = Float(renderQualitySettings.ambientLightIntensity)
        params.renderingStep = request.samplingDistance
        params.earlyTerminationThreshold = interactiveEarlyTerminationThreshold(for: request)
        params.adaptiveGradientThreshold = extendedState.adaptiveThreshold
        params.jitterAmount = extendedState.jitterAmount
        params.intensityRatio = extendedState.channelIntensities
        let clip = request.clipping.shaderCropBounds()
        params.trimXMin = clip.xMin
        params.trimXMax = clip.xMax
        params.trimYMin = clip.yMin
        params.trimYMax = clip.yMax
        params.trimZMin = clip.zMin
        params.trimZMax = clip.zMax
        params.clipBoxQuaternion = request.clipping.shaderCropRotation()
        let planes = try request.clipping.shaderClipPlanes(for: request.dataset)
        params.clipPlane0 = planes.0
        params.clipPlane1 = planes.1
        params.clipPlane2 = planes.2
        params.backgroundColor = SIMD3<Float>(repeating: 0)
        return params
    }

    private func interactiveEarlyTerminationThreshold(for request: VolumeRenderRequest) -> Float {
        switch request.quality {
        case .preview, .interactive:
            return min(extendedState.earlyTerminationThreshold, 0.85)
        case .production:
            return extendedState.earlyTerminationThreshold
        }
    }

    func buildVolumeUniforms(for request: VolumeRenderRequest,
                             window providedWindow: ClosedRange<Int32>? = nil) throws -> VolumeUniforms {
        var uniforms = VolumeUniforms()
        let dataset = request.dataset
        let window = try providedWindow ?? resolveWindow(for: dataset)

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

        let renderQualitySettings = request.renderQualitySettings.sanitized
        let lightingEnabled = overrides.lightingEnabled &&
            extendedState.lightingEnabled &&
            renderQualitySettings.lightingEnabled(for: request.quality)
        uniforms.isLightingOn = lightingEnabled ? 1 : 0
        uniforms.shadowMode = lightingEnabled
            ? renderQualitySettings.effectiveShadowMode(for: request.quality).shaderValue
            : VolumeShadowMode.off.shaderValue

        if let gate = extendedState.huGate {
            uniforms.useHuGate = 1
            uniforms.gateHuMin = gate.lowerBound
            uniforms.gateHuMax = gate.upperBound
        } else {
            uniforms.useHuGate = 0
        }

        if let gate = extendedState.densityGate {
            uniforms.densityFloor = gate.lowerBound
            uniforms.densityCeil = gate.upperBound
        }

        switch request.compositing {
        case .frontToBack:
            uniforms.useTFProj = 1
        case .maximumIntensity, .minimumIntensity, .averageIntensity:
            // Issues #98 and #103 track the broader viewport routing cleanup.
            // The empty fourth viewport was not a missing render call here; the
            // projection modes were incorrectly reusing DVR transfer-function
            // projection and could collapse the presented output to black.
            uniforms.useTFProj = 0
        }
        if let gradientOpacity = request.transferFunction.gradientOpacity {
            uniforms.use2DTF = 1
            uniforms.gradientMin = gradientOpacity.minimumGradient
            uniforms.gradientMax = gradientOpacity.maximumGradient
        } else {
            uniforms.use2DTF = 0
        }
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

    func legacyClippingState(for dataset: VolumeDataset) throws -> VolumeClippingState {
        var cropBox: VolumeCropBox?
        if extendedState.clipBounds != .default {
            cropBox = try extendedState.clipBounds.volumeCropBox()
        }

        let planeSnapshot = ClipPlaneSnapshot(preset: extendedState.clipPlanePreset,
                                              offset: extendedState.clipPlaneOffset)
        let clipPlanes = try planeSnapshot.volumeClipPlane(for: dataset).map { [$0] } ?? []
        return try VolumeClippingState(cropBox: cropBox,
                                       clipPlanes: clipPlanes)
    }

    func applyCompatibilityClippingIfNeeded(to request: VolumeRenderRequest) throws -> VolumeRenderRequest {
        guard request.clipping.isDisabled else {
            return request
        }
        let legacy = try legacyClippingState(for: request.dataset)
        guard !legacy.isDisabled else {
            return request
        }
        var resolved = request
        resolved.clipping = legacy
        return resolved
    }

    func computeOptionFlags(useAcceleration: Bool = false) -> UInt16 {
        var flags: UInt16 = extendedState.adaptiveEnabled ? VolumeRenderOptionBits.adaptiveStepping : 0
        if useAcceleration {
            flags |= VolumeRenderOptionBits.acceleration
        }
        return flags
    }

    func makeCameraUniforms(for request: VolumeRenderRequest,
                            viewportSize: (width: Int, height: Int),
                            frameIndex: UInt32) throws -> CameraUniforms {
        var camera = CameraUniforms()
        let geometry = VolumeRenderGeometry.make(for: request.dataset)
        let renderCamera = geometry.renderCamera(for: request.camera)
        camera.modelMatrix = geometry.modelMatrix
        camera.inverseModelMatrix = geometry.inverseModelMatrix
        let inverseViewProjectionMatrix = try makeInverseViewProjectionMatrix(camera: renderCamera,
                                                                              viewportSize: viewportSize)
        camera.inverseViewProjectionMatrix = inverseViewProjectionMatrix
        camera.cameraPositionLocal = geometry.centeredTextureCoordinate(for: request.camera.position)
        camera.frameIndex = frameIndex
        camera.projectionType = request.camera.projectionType.rawValue
        camera.cameraPositionWorld = SIMD4<Float>(renderCamera.position.x,
                                                  renderCamera.position.y,
                                                  renderCamera.position.z,
                                                  1)
        if let rayBasis = makeLocalRayBasis(inverseViewProjectionMatrix: inverseViewProjectionMatrix,
                                            inverseModelMatrix: geometry.inverseModelMatrix) {
            camera.localNearOrigin = SIMD4<Float>(rayBasis.nearOrigin, 0)
            camera.localNearDeltaX = SIMD4<Float>(rayBasis.nearDeltaX, 0)
            camera.localNearDeltaY = SIMD4<Float>(rayBasis.nearDeltaY, 0)
            camera.localFarOrigin = SIMD4<Float>(rayBasis.farOrigin, 0)
            camera.localFarDeltaX = SIMD4<Float>(rayBasis.farDeltaX, 0)
            camera.localFarDeltaY = SIMD4<Float>(rayBasis.farDeltaY, 0)
            camera.rayBasisValid = 1
        }
        return camera
    }

    func makeLocalRayBasis(inverseViewProjectionMatrix: simd_float4x4,
                           inverseModelMatrix: simd_float4x4)
        -> (nearOrigin: SIMD3<Float>,
            nearDeltaX: SIMD3<Float>,
            nearDeltaY: SIMD3<Float>,
            farOrigin: SIMD3<Float>,
            farDeltaX: SIMD3<Float>,
            farDeltaY: SIMD3<Float>)? {
        guard let near00 = makeLocalRayPoint(uv: SIMD2<Float>(0, 0),
                                             clipZ: 0,
                                             inverseViewProjectionMatrix: inverseViewProjectionMatrix,
                                             inverseModelMatrix: inverseModelMatrix),
              let near10 = makeLocalRayPoint(uv: SIMD2<Float>(1, 0),
                                             clipZ: 0,
                                             inverseViewProjectionMatrix: inverseViewProjectionMatrix,
                                             inverseModelMatrix: inverseModelMatrix),
              let near01 = makeLocalRayPoint(uv: SIMD2<Float>(0, 1),
                                             clipZ: 0,
                                             inverseViewProjectionMatrix: inverseViewProjectionMatrix,
                                             inverseModelMatrix: inverseModelMatrix),
              let far00 = makeLocalRayPoint(uv: SIMD2<Float>(0, 0),
                                            clipZ: 1,
                                            inverseViewProjectionMatrix: inverseViewProjectionMatrix,
                                            inverseModelMatrix: inverseModelMatrix),
              let far10 = makeLocalRayPoint(uv: SIMD2<Float>(1, 0),
                                            clipZ: 1,
                                            inverseViewProjectionMatrix: inverseViewProjectionMatrix,
                                            inverseModelMatrix: inverseModelMatrix),
              let far01 = makeLocalRayPoint(uv: SIMD2<Float>(0, 1),
                                            clipZ: 1,
                                            inverseViewProjectionMatrix: inverseViewProjectionMatrix,
                                            inverseModelMatrix: inverseModelMatrix) else {
            return nil
        }

        return (near00,
                near10 - near00,
                near01 - near00,
                far00,
                far10 - far00,
                far01 - far00)
    }

    private func makeLocalRayPoint(uv: SIMD2<Float>,
                                   clipZ: Float,
                                   inverseViewProjectionMatrix: simd_float4x4,
                                   inverseModelMatrix: simd_float4x4) -> SIMD3<Float>? {
        let clip = SIMD4<Float>(uv.x * 2 - 1, uv.y * 2 - 1, clipZ, 1)
        let worldHomogeneous = inverseViewProjectionMatrix * clip
        guard abs(worldHomogeneous.w) > Float.ulpOfOne else {
            return nil
        }
        let world = SIMD4<Float>(worldHomogeneous.x / worldHomogeneous.w,
                                 worldHomogeneous.y / worldHomogeneous.w,
                                 worldHomogeneous.z / worldHomogeneous.w,
                                 1)
        let localHomogeneous = inverseModelMatrix * world
        guard abs(localHomogeneous.w) > Float.ulpOfOne else {
            return nil
        }
        let local = SIMD3<Float>(localHomogeneous.x / localHomogeneous.w,
                                 localHomogeneous.y / localHomogeneous.w,
                                 localHomogeneous.z / localHomogeneous.w)
            + SIMD3<Float>(repeating: 0.5)
        return local.allFinite ? local : nil
    }

    func makeInverseViewProjectionMatrix(camera: VolumeRenderRequest.Camera,
                                         viewportSize: (width: Int, height: Int)) throws -> simd_float4x4 {
        let matrices: VolumeCameraMath.Matrices
        do {
            matrices = try VolumeCameraMath.matrices(
                camera: camera,
                viewportWidth: Float(viewportSize.width),
                viewportHeight: Float(viewportSize.height)
            )
        } catch {
            throw AdapterError.degenerateCameraMatrix
        }

        if diagnosticLoggingEnabled {
            logger.info("[DIAG] View Matrix:\n\(matrices.view.debugDescription)")
            logger.info("[DIAG] Projection Matrix:\n\(matrices.projection.debugDescription)")
            logger.info("[DIAG] InvViewProj Matrix:\n\(matrices.inverseViewProjection.debugDescription)")
        }

        return matrices.inverseViewProjection
    }
}

private extension SIMD3 where Scalar == Float {
    var allFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}
