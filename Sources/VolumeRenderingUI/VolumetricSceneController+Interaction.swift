//
//  VolumetricSceneController+Interaction.swift
//  MetalVolumetrics
//
//  Interaction-facing API split from the core controller to keep files under
//  the verify script thresholds.
//
#if os(iOS)
import Foundation
import SceneKit
import simd
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Metal)
import Metal
#endif
#if canImport(MetalPerformanceShaders)
import MetalPerformanceShaders
#endif
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
import MetalKit
#endif
import VolumeRenderingCore
import VolumeRenderingCore

@MainActor extension VolumetricSceneController {
    /// Encadeia o dataset entre SceneKit e MPS, recalculando bounds do volume
    /// para direcionar `configureCamera`. A geometria resultante dita o centro
    /// do volume, o raio usado como limite de distância e o transform de
    /// fallback aplicado caso o volume seja descartado depois.
    public func applyDataset(_ dataset: VolumeDataset) async {
        guard self.dataset != dataset || datasetApplied == false else { return }
        self.dataset = dataset

        volumeMaterial.setDataset(device: device, dataset: dataset)
        mprMaterial.setDataset(device: device, dataset: dataset)

        let scale = volumeMaterial.scale
        volumeNode.scale = SCNVector3(scale)

        geometry = makeGeometry(from: dataset)
        applyPatientOrientationIfNeeded()
        synchronizeMprNodeTransform()
        updateVolumeBounds()
        if let geometry {
            configureCamera(using: geometry)
        } else {
            restoreFallbackCamera()
        }

        let baselineShift = transferFunction?.shift ?? volumeMaterial.tf?.shift ?? 0
        defaultTransferShift = baselineShift

        datasetApplied = true
        logger.debug("Applied dataset dim=\(scale)")
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
        mpsDisplay?.updateDataset(dataset)
        mpsDisplay?.updateTransferFunction(transferFunction ?? volumeMaterial.tf)
        mpsDisplay?.updateDisplayConfiguration(currentDisplay)
#endif
#if canImport(MetalPerformanceShaders)
        prepareMpsResourcesForDataset(dataset)
#endif
    }

    public func setDisplayConfiguration(_ configuration: DisplayConfiguration) async {
        guard datasetApplied else {
            logger.warning("Attempted to change display configuration before dataset load")
            return
        }

        if currentDisplay == configuration { return }
        currentDisplay = configuration

        resumeSceneViewIfNeeded()

        switch configuration {
        case let .volume(method):
            volumeMaterial.setMethod(method)
            volumeNode.isHidden = false
            mprNode.isHidden = true
            requestImmediateSceneViewFrame()
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
            mpsDisplay?.updateDisplayConfiguration(configuration)
#endif
        case let .mpr(axis, index, blend, slab):
            configureMPR(axis: axis, index: index, blend: blend, slab: slab)
            volumeNode.isHidden = true
            mprNode.isHidden = false
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
            mpsDisplay?.updateDisplayConfiguration(configuration)
#endif
        }
    }

    private func resumeSceneViewIfNeeded() {
        if sceneView.isPlaying == false {
            sceneView.isPlaying = true
        }
        if sceneView.rendersContinuously == false {
            sceneView.rendersContinuously = true
        }
    }

    private func requestImmediateSceneViewFrame() {
        guard renderingBackend == .sceneKit else { return }
#if os(macOS)
        sceneView.setNeedsDisplay(sceneView.bounds)
#else
        sceneView.setNeedsDisplay()
#endif
    }

    public func resetCamera() async {
        let cameraNode = ensureCameraNode()
        updateVolumeBounds()
        if let initialCameraTransform {
            cameraNode.simdTransform = initialCameraTransform
        } else {
            cameraNode.position = SCNVector3(x: 0, y: 0, z: 2)
            cameraNode.eulerAngles = SCNVector3(x: 0, y: 0, z: 0)
        }
        let radius = max(volumeBoundingRadius, 1e-3)
        updateInteractiveCameraState(target: fallbackCameraTarget,
                                      up: fallbackWorldUp,
                                      cameraNode: cameraNode,
                                      radius: radius)
        defaultCameraTarget = SCNVector3(x: SCNFloat(fallbackCameraTarget.x),
                                         y: SCNFloat(fallbackCameraTarget.y),
                                         z: SCNFloat(fallbackCameraTarget.z))
        prepareCameraControllerForExternalGestures(worldUp: fallbackWorldUp)
    }

    public func rotateCamera(screenDelta: SIMD2<Float>) async {
        let cameraNode = ensureCameraNode()
        let yaw = screenDelta.x * 0.01
        let pitch = screenDelta.y * 0.01
        let threshold = Float.ulpOfOne
        if abs(yaw) <= threshold && abs(pitch) <= threshold { return }

        var offset = cameraOffset
        var up = safeNormalize(cameraUpVector, fallback: fallbackWorldUp)

        if abs(yaw) > threshold {
            let yawAxis = safeNormalize(patientLongitudinalAxis, fallback: fallbackWorldUp)
            let yawRotation = simd_quatf(angle: yaw, axis: yawAxis)
            offset = yawRotation.act(offset)
            up = yawRotation.act(up)
        }

        var forward = safeNormalize(-offset, fallback: SIMD3<Float>(0, 0, -1))
        var right = safeNormalize(simd_cross(forward, up), fallback: safePerpendicular(to: forward))

        if abs(pitch) > threshold {
            let pitchRotation = simd_quatf(angle: pitch, axis: right)
            offset = pitchRotation.act(offset)
            up = pitchRotation.act(up)
            forward = safeNormalize(-offset, fallback: forward)
            right = safeNormalize(simd_cross(forward, up), fallback: safePerpendicular(to: forward))
        }

        cameraOffset = offset
        cameraUpVector = up
        applyInteractiveCameraTransform(cameraNode)
    }

    public func tiltCamera(roll: Float, pitch: Float) async {
        let cameraNode = ensureCameraNode()
        let threshold = Float.ulpOfOne
        if abs(roll) <= threshold && abs(pitch) <= threshold { return }

        var offset = cameraOffset
        var up = cameraUpVector
        var forward = safeNormalize(-offset, fallback: SIMD3<Float>(0, 0, -1))
        var right = safeNormalize(simd_cross(forward, up), fallback: safePerpendicular(to: forward))

        if abs(roll) > threshold {
            let rollRotation = simd_quatf(angle: roll, axis: forward)
            up = rollRotation.act(up)
            right = rollRotation.act(right)
        }

        if abs(pitch) > threshold {
            let pitchRotation = simd_quatf(angle: pitch, axis: right)
            offset = pitchRotation.act(offset)
            up = pitchRotation.act(up)
            forward = safeNormalize(-offset, fallback: forward)
        }

        cameraOffset = offset
        cameraUpVector = up
        applyInteractiveCameraTransform(cameraNode)
    }

    public func panCamera(screenDelta: SIMD2<Float>) async {
        let cameraNode = ensureCameraNode()
        let threshold = Float.ulpOfOne
        if abs(screenDelta.x) <= threshold && abs(screenDelta.y) <= threshold { return }

        var up = safeNormalize(cameraUpVector, fallback: fallbackWorldUp)
        let forward = safeNormalize(-cameraOffset, fallback: SIMD3<Float>(0, 0, -1))
        let right = safeNormalize(simd_cross(forward, up), fallback: safePerpendicular(to: forward))
        up = safeNormalize(simd_cross(right, forward), fallback: up)

        let distance = max(simd_length(cameraOffset), Float.ulpOfOne)
        let scales = screenSpaceScale(distance: distance, cameraNode: cameraNode)
        let translation = (-screenDelta.x * scales.horizontal) * right + (screenDelta.y * scales.vertical) * up
        cameraTarget = clampCameraTarget(cameraTarget + translation)
        cameraUpVector = up
        applyInteractiveCameraTransform(cameraNode)
    }

    public func dollyCamera(delta: Float) async {
        let cameraNode = ensureCameraNode()
        guard delta.isFinite else { return }
        if abs(delta) <= Float.ulpOfOne { return }

        var offset = cameraOffset
        let forward = safeNormalize(-offset, fallback: SIMD3<Float>(0, 0, -1))
        offset -= forward * delta
        cameraOffset = offset
        applyInteractiveCameraTransform(cameraNode)
    }

    public func setTransferFunction(_ transferFunction: TransferFunction?) async throws {
        transferFunction.map { self.transferFunction = $0 }
        guard let transferFunction else {
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
            mpsDisplay?.updateTransferFunction(nil)
#endif
            return
        }
        guard let texture = transferFunction.makeTexture(device: device) else {
            throw Error.transferFunctionUnavailable
        }
        volumeMaterial.tf = transferFunction
        volumeMaterial.setTransferFunctionTexture(texture)
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
        mpsDisplay?.updateTransferFunction(transferFunction)
#endif
    }

    func setLighting(enabled: Bool) async {
        volumeMaterial.setLighting(on: enabled)
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
        mpsDisplay?.updateLighting(enabled: enabled)
#endif
    }

    func setSamplingStep(_ step: Float) async {
        baseSamplingStep = step
        volumeMaterial.setStep(step)
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
        mpsDisplay?.updateSamplingStep(step)
#endif
    }

    func setProjectionsUseTransferFunction(_ enabled: Bool) async {
        volumeMaterial.setUseTFOnProjections(enabled)
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
        mpsDisplay?.updateProjectionsUseTransferFunction(enabled)
#endif
    }

    func setProjectionDensityGate(floor: Float, ceil: Float) async {
        volumeMaterial.setDensityGate(floor: floor, ceil: ceil)
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
        mpsDisplay?.updateDensityGate(floor: floor, ceil: ceil)
#endif
    }

    func setProjectionHuGate(enabled: Bool, min: Int32, max: Int32) async {
        volumeMaterial.setHuGate(enabled: enabled)
        if enabled {
            volumeMaterial.setHuWindow(minHU: min, maxHU: max)
        }
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
        mpsDisplay?.updateProjectionHuGate(enabled: enabled, min: min, max: max)
#endif
    }

    public func setAdaptiveSampling(_ enabled: Bool) async {
        adaptiveSamplingEnabled = enabled
        if !enabled {
            restoreSamplingStep()
        }
#if canImport(UIKit)
        attachAdaptiveHandlersIfNeeded()
#endif
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
        mpsDisplay?.updateAdaptiveSampling(enabled)
#endif
    }

    public func beginAdaptiveSamplingInteraction() async {
        applyAdaptiveSampling()
    }

    public func endAdaptiveSamplingInteraction() async {
        restoreSamplingStep()
    }


    func setRenderMethod(_ method: VolumeCubeMaterial.Method) async {
        await setVolumeMethod(method)
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
        mpsDisplay?.updateRenderMethod(method)
#endif
    }

    public func setMprBlend(_ mode: MPRPlaneMaterial.BlendMode) async {
        guard datasetApplied else { return }
        mprMaterial.setBlend(mode)
    }

    public func setMprSlab(thickness: Int, steps: Int) async {
        guard datasetApplied else { return }
        guard let axis = currentMprAxis else { return }
        let normalizedThickness = SlabConfiguration.snapToOddVoxelCount(thickness)
        let normalizedSteps = SlabConfiguration.snapToOddVoxelCount(max(1, steps))
        mprMaterial.setSlab(thicknessInVoxels: normalizedThickness, axis: axis.rawValue, steps: normalizedSteps)
    }

    public func setMprHuWindow(min: Int32, max: Int32) async {
        guard datasetApplied else { return }
        mprMaterial.setHU(min: min, max: max)
    }

    public func setMprPlane(axis: Axis, normalized: Float) async {
        guard datasetApplied else { return }
        guard currentMprAxis == axis else { return }
        let clamped = clampFloat(normalized, lower: 0.0, upper: 1.0)
        let targetIndex = indexPosition(for: axis, normalized: clamped)
        // Convertendo para índice inteiro e depois de volta para normalizado
        // garantimos que tanto o plano do SceneKit quanto o renderer MPS usem
        // exatamente o mesmo voxel central, evitando discrepâncias após
        // arredondamentos sucessivos de interações.
        mprPlaneIndex = clampedIndex(for: axis, index: targetIndex)
        mprNormalizedPosition = normalizedPosition(for: axis, index: mprPlaneIndex)
        applyMprOrientation()
    }

    public func translate(axis: Axis, deltaNormalized: Float) async {
        guard datasetApplied else { return }
        guard currentMprAxis == axis else { return }
        await setMprPlane(axis: axis, normalized: mprNormalizedPosition + deltaNormalized)
    }

    public func rotate(axis: Axis, radians: Float) async {
        guard datasetApplied else { return }
        switch axis {
        case .x:
            mprEuler.x += radians
        case .y:
            mprEuler.y += radians
        case .z:
            mprEuler.z += radians
        }
        applyMprOrientation()
    }

    public func updateTransferFunctionShift(_ shift: Float) async {
        guard let tf = transferFunction else { return }
        var copy = tf
        copy.shift = shift
        guard let texture = copy.makeTexture(device: device) else { return }
        volumeMaterial.setTransferFunctionTexture(texture)
        transferFunction = copy
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
        mpsDisplay?.updateTransferFunction(copy)
#endif
    }

    public func setVolumeMethod(_ method: VolumeCubeMaterial.Method) async {
        volumeMaterial.setMethod(method)
        if case .volume = currentDisplay {
            currentDisplay = .volume(method: method)
        }
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
        mpsDisplay?.updateVolumeMethod(method)
#endif
    }

    public func setPreset(_ preset: VolumeCubeMaterial.Preset) async {
        volumeMaterial.setPreset(device: device, preset: preset)
        transferFunction = volumeMaterial.tf
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
        mpsDisplay?.updateTransferFunction(transferFunction)
#endif
    }

    public func setShift(_ shift: Float) async {
        volumeMaterial.setShift(device: device, shift: shift)
        transferFunction = volumeMaterial.tf
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
        mpsDisplay?.updateTransferFunction(transferFunction)
#endif
    }

    public func setHuGate(enabled: Bool) async {
        volumeMaterial.setHuGate(enabled: enabled)
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
        mpsDisplay?.updateHuGate(enabled: enabled)
#endif
    }

    public func setHuWindow(_ window: VolumeCubeMaterial.HuWindowMapping) async {
        volumeMaterial.setHuWindow(window)
        mprMaterial.setHU(min: window.minHU, max: window.maxHU)
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
        mpsDisplay?.updateHuWindow(min: window.minHU, max: window.maxHU)
#endif
    }

    public func setRenderMode(_ mode: VolumetricRenderMode) async {
        switch mode {
        case .active:
            sceneView.isPlaying = true
            sceneView.rendersContinuously = true
        case .paused:
            sceneView.isPlaying = false
            sceneView.rendersContinuously = false
        }
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
        mpsDisplay?.setRenderMode(mode)
#endif
    }

    public func setRenderingBackend(_ backend: VolumetricRenderingBackend) async -> VolumetricRenderingBackend {
        if renderingBackend == backend {
            return renderingBackend
        }

        switch backend {
        case .sceneKit:
            activateSceneKitBackend()
            return renderingBackend

        case .metalPerformanceShaders:
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
            guard MPSSupportsMTLDevice(device), let display = mpsDisplay else {
                logger.warning("Metal Performance Shaders backend unavailable on this device; staying on SceneKit.")
                activateSceneKitBackend()
                return renderingBackend
            }

            if mpsRenderer == nil {
                guard let renderer = MPSVolumeRenderer(device: device, commandQueue: commandQueue) else {
                    logger.error("Failed to initialize MPS volume renderer; staying on SceneKit backend.")
                    activateSceneKitBackend()
                    return renderingBackend
                }
                mpsRenderer = renderer
            }

            guard mpsRenderer != nil else {
                activateSceneKitBackend()
                return renderingBackend
            }

            renderingBackend = .metalPerformanceShaders
            sceneView.isHidden = true
            display.setActive(true)

            if datasetApplied, let dataset {
                prepareMpsResourcesForDataset(dataset)
                display.updateDataset(dataset)
                display.updateTransferFunction(transferFunction ?? volumeMaterial.tf)
                display.updateDisplayConfiguration(currentDisplay)
                if let histogram = lastMpsHistogram {
                    display.updateHistogram(histogram)
                }
            } else {
                display.updateDataset(nil)
            }

            return renderingBackend
#else
            logger.warning("Metal Performance Shaders backend not supported on this platform; staying on SceneKit.")
            activateSceneKitBackend()
            return renderingBackend
#endif
        }
    }

    private func activateSceneKitBackend() {
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
        mpsDisplay?.setActive(false)
#endif
        sceneView.isHidden = false
        renderingBackend = .sceneKit
        if datasetApplied, let dataset {
            volumeMaterial.setDataset(device: device, dataset: dataset)
            mprMaterial.setDataset(device: device, dataset: dataset)
        }
        requestImmediateSceneViewFrame()
    }

    func resetView() async {
        guard datasetApplied else { return }

        if let geometry {
            applyPatientOrientationIfNeeded()
            synchronizeMprNodeTransform()
            configureCamera(using: geometry)
        } else {
            restoreFallbackCamera()
        }

        if let dataset {
            let range = dataset.intensityRange
            volumeMaterial.setHuWindow(minHU: range.lowerBound, maxHU: range.upperBound)
            mprMaterial.setHU(min: range.lowerBound, max: range.upperBound)
        }

        if volumeMaterial.tf != nil || transferFunction != nil {
            volumeMaterial.setShift(device: device, shift: defaultTransferShift)
            transferFunction = volumeMaterial.tf
        }

        applyMprOrientation()
    }

#if canImport(MetalPerformanceShaders)
    /// Propaga histogramas derivados de máscaras de ROI para o backend MPS.
    /// Permite que o `MPSDisplayAdapter` ajuste o brilho e destaques com base
    /// na região selecionada.
    func applyROIHistogram(_ histogram: MPSVolumeRenderer.HistogramResult?) {
        lastMpsHistogram = histogram
#if canImport(MetalKit)
        mpsDisplay?.updateHistogram(histogram)
#endif
    }
#endif

    public func metadata() -> (dimension: SIMD3<Int32>, resolution: SIMD3<Float>)? {
        guard datasetApplied else { return nil }
        return volumeMaterial.datasetMeta
    }
}
#endif
