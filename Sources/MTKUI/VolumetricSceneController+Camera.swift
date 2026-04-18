//
//  VolumetricSceneController+Camera.swift
//  MetalVolumetrics
//
//  Camera utilities and MPR support extracted for maintainability.
#if os(iOS) || os(macOS)
//
import Foundation
import SceneKit
import simd
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Metal)
import Metal
#endif
@_spi(Internal) import MTKCore
import MTKSceneKit

@MainActor public extension VolumetricSceneController {
    // MARK: - Camera Controller Delegation

    @discardableResult
    func ensureCameraNode() -> SCNNode {
        return cameraController.ensureCameraNode(
            volumeBoundingRadius: volumeBoundingRadius,
            cameraOffset: cameraOffset
        )
    }

    func configureCamera(using geometry: DICOMGeometry) {
        updateVolumeBounds()
        _ = cameraController.configureCamera(
            using: geometry,
            volumeWorldCenter: volumeWorldCenter,
            volumeBoundingRadius: volumeBoundingRadius,
            defaultCameraDistanceFactor: defaultCameraDistanceFactor,
            updateState: { [weak self] (cameraTarget: SIMD3<Float>, cameraOffset: SIMD3<Float>, cameraUpVector: SIMD3<Float>, fallbackCameraTransform: simd_float4x4, initialCameraTransform: simd_float4x4, fallbackWorldUp: SIMD3<Float>, fallbackCameraTarget: SIMD3<Float>, patientLongitudinalAxis: SIMD3<Float>, defaultCameraTarget: SCNVector3, cameraDistanceLimits: ClosedRange<Float>) in
                guard let self else { return }
                self.cameraTarget = cameraTarget
                self.cameraOffset = cameraOffset
                self.cameraUpVector = cameraUpVector
                self.fallbackCameraTransform = fallbackCameraTransform
                self.initialCameraTransform = initialCameraTransform
                self.fallbackWorldUp = fallbackWorldUp
                self.fallbackCameraTarget = fallbackCameraTarget
                self.patientLongitudinalAxis = patientLongitudinalAxis
                self.defaultCameraTarget = defaultCameraTarget
                self.cameraDistanceLimits = cameraDistanceLimits
            }
        )
    }

    func restoreFallbackCamera() {
        updateVolumeBounds()
        _ = cameraController.restoreFallbackCamera(
            fallbackCameraTransform: fallbackCameraTransform,
            fallbackCameraTarget: fallbackCameraTarget,
            fallbackWorldUp: fallbackWorldUp,
            volumeBoundingRadius: volumeBoundingRadius,
            updateState: { [weak self] (cameraTarget: SIMD3<Float>, cameraOffset: SIMD3<Float>, cameraUpVector: SIMD3<Float>, defaultCameraTarget: SCNVector3, cameraDistanceLimits: ClosedRange<Float>) in
                guard let self else { return }
                self.cameraTarget = cameraTarget
                self.cameraOffset = cameraOffset
                self.cameraUpVector = cameraUpVector
                self.defaultCameraTarget = defaultCameraTarget
                self.cameraDistanceLimits = cameraDistanceLimits
            }
        )
    }

    func updateInteractiveCameraState(target: SIMD3<Float>,
                                      up: SIMD3<Float>,
                                      cameraNode: SCNNode,
                                      radius: Float) {
        cameraController.updateInteractiveCameraState(
            target: target,
            up: up,
            cameraNode: cameraNode,
            radius: radius,
            clampTargetFn: { [weak self] (target: SIMD3<Float>) in
                guard let self else { return target }
                return self.clampCameraTarget(target)
            },
            fallbackWorldUp: fallbackWorldUp,
            updateState: { [weak self] (cameraTarget: SIMD3<Float>, cameraUpVector: SIMD3<Float>, cameraOffset: SIMD3<Float>, defaultCameraTarget: SCNVector3, cameraDistanceLimits: ClosedRange<Float>, fallbackWorldUp: SIMD3<Float>) in
                guard let self else { return }
                self.cameraTarget = cameraTarget
                self.cameraUpVector = cameraUpVector
                self.cameraOffset = cameraOffset
                self.defaultCameraTarget = defaultCameraTarget
                self.cameraDistanceLimits = cameraDistanceLimits
                self.fallbackWorldUp = fallbackWorldUp
            }
        )
    }

    func applyInteractiveCameraTransform(_ cameraNode: SCNNode) {
        cameraController.applyInteractiveCameraTransform(
            cameraNode,
            cameraTarget: cameraTarget,
            cameraOffset: cameraOffset,
            cameraUpVector: cameraUpVector,
            volumeBoundingRadius: volumeBoundingRadius,
            fallbackWorldUp: fallbackWorldUp,
            clampTargetFn: { [weak self] (target: SIMD3<Float>) in
                guard let self else { return target }
                return self.clampCameraTarget(target)
            },
            clampOffsetFn: { [weak self] (offset: SIMD3<Float>) in
                guard let self else { return offset }
                return self.clampCameraOffset(offset)
            },
            updateState: { [weak self] (cameraTarget: SIMD3<Float>, cameraUpVector: SIMD3<Float>, cameraOffset: SIMD3<Float>, defaultCameraTarget: SCNVector3) in
                guard let self else { return }
                self.cameraTarget = cameraTarget
                self.cameraUpVector = cameraUpVector
                self.cameraOffset = cameraOffset
                self.defaultCameraTarget = defaultCameraTarget
            }
        )
    }

    func clampCameraOffset(_ offset: SIMD3<Float>) -> SIMD3<Float> {
        return cameraController.clampCameraOffset(offset, distanceLimits: cameraDistanceLimits)
    }

    func makeCameraDistanceLimits(radius: Float) -> ClosedRange<Float> {
        return cameraController.makeCameraDistanceLimits(radius: radius)
    }

    func updateCameraControllerTargets() {
        cameraController.updateCameraControllerTargets(cameraTarget: cameraTarget, cameraUpVector: cameraUpVector)
    }

    func screenSpaceScale(distance: Float, cameraNode: SCNNode) -> (horizontal: Float, vertical: Float) {
        return cameraController.screenSpaceScale(distance: distance, cameraNode: cameraNode)
    }

    func prepareCameraControllerForExternalGestures(worldUp: SIMD3<Float>? = nil) {
        cameraController.prepareCameraControllerForExternalGestures(
            worldUp: worldUp,
            defaultCameraTarget: defaultCameraTarget
        )
    }

    func updateCameraClippingPlanes(_ camera: SCNCamera?, radius: Float, offsetLength: Float) {
        cameraController.updateCameraClippingPlanes(camera, radius: radius, offsetLength: offsetLength)
    }

    func makeLookAtTransform(position: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        return cameraController.makeLookAtTransform(position: position, target: target, up: up)
    }

    func safeNormalize(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        return cameraController.safeNormalize(vector, fallback: fallback)
    }

    func safePerpendicular(to vector: SIMD3<Float>) -> SIMD3<Float> {
        return cameraController.safePerpendicular(to: vector)
    }

    // MARK: - Volume Geometry Delegation

    func updateVolumeBounds() {
        volumeGeometry.updateVolumeBounds(
            patientLongitudinalAxis: patientLongitudinalAxis,
            updateState: { [weak self] (volumeWorldCenter: SIMD3<Float>, volumeBoundingRadius: Float, patientLongitudinalAxis: SIMD3<Float>) in
                guard let self else { return }
                self.volumeWorldCenter = volumeWorldCenter
                self.volumeBoundingRadius = volumeBoundingRadius
                self.patientLongitudinalAxis = patientLongitudinalAxis
            }
        )
    }

    func clampCameraTarget(_ target: SIMD3<Float>) -> SIMD3<Float> {
        return volumeGeometry.clampCameraTarget(
            target,
            volumeWorldCenter: volumeWorldCenter,
            volumeBoundingRadius: volumeBoundingRadius,
            maximumPanDistanceMultiplier: maximumPanDistanceMultiplier
        )
    }

    func patientBasis(from geometry: DICOMGeometry) -> simd_float3x3 {
        return volumeGeometry.patientBasis(from: geometry)
    }

    func makeGeometry(from dataset: VolumeDataset) -> DICOMGeometry {
        return volumeGeometry.makeGeometry(from: dataset)
    }

    // MARK: - MPR Controller Delegation

    func applyPatientOrientationIfNeeded() {
        mprController.applyPatientOrientationIfNeeded(geometry: geometry)
    }

    func synchronizeMprNodeTransform() {
        mprController.synchronizeMprNodeTransform()
    }

    func normalizedPosition(for axis: Axis, index: Int) -> Float {
        return mprController.normalizedPosition(for: axis, index: index)
    }

    func indexPosition(for axis: Axis, normalized: Float) -> Int {
        return mprController.indexPosition(for: axis, normalized: normalized)
    }

    func clampedIndex(for axis: Axis, index: Int) -> Int {
        return mprController.clampedIndex(for: axis, index: index)
    }

    func applyMprOrientation() {
        mprController.applyMprOrientation(
            datasetApplied: datasetApplied,
            currentMprAxis: currentMprAxis,
            mprPlaneIndex: mprPlaneIndex,
            mprEuler: mprEuler,
            geometry: geometry,
            fallbackWorldUp: fallbackWorldUp,
            volumeWorldCenter: volumeWorldCenter,
            volumeBoundingRadius: volumeBoundingRadius,
            defaultCameraDistanceFactor: defaultCameraDistanceFactor,
            updateState: { [weak self] (fallbackCameraTransform: simd_float4x4,
                                        initialCameraTransform: simd_float4x4,
                                        defaultCameraTarget: SCNVector3) in
                guard let self else { return }
                self.fallbackCameraTransform = fallbackCameraTransform
                self.initialCameraTransform = initialCameraTransform
                self.defaultCameraTarget = defaultCameraTarget
            }
        )
    }

    func alignCameraToMpr(normal: SIMD3<Float>, up: SIMD3<Float>) {
        updateVolumeBounds()
        mprController.alignCameraToMpr(
            normal: normal,
            up: up,
            volumeWorldCenter: volumeWorldCenter,
            volumeBoundingRadius: volumeBoundingRadius,
            defaultCameraDistanceFactor: defaultCameraDistanceFactor,
            fallbackWorldUp: fallbackWorldUp,
            updateState: { [weak self] (fallbackCameraTransform: simd_float4x4,
                                        initialCameraTransform: simd_float4x4,
                                        defaultCameraTarget: SCNVector3) in
                guard let self else { return }
                self.fallbackCameraTransform = fallbackCameraTransform
                self.initialCameraTransform = initialCameraTransform
                self.defaultCameraTarget = defaultCameraTarget
            }
        )
    }

    func rotationQuaternion(for euler: SIMD3<Float>) -> simd_quatf {
        return mprController.rotationQuaternion(for: euler)
    }

    func datasetDimensions() -> SIMD3<Float> {
        return mprController.datasetDimensions()
    }

    func configureMPR(axis: Axis, index: Int, blend: MPRPlaneMaterial.BlendMode, slab: SlabConfiguration?) {
        mprController.configureMPR(
            axis: axis,
            index: index,
            blend: blend,
            slab: slab,
            datasetApplied: datasetApplied,
            geometry: geometry,
            fallbackWorldUp: fallbackWorldUp,
            volumeWorldCenter: volumeWorldCenter,
            volumeBoundingRadius: volumeBoundingRadius,
            defaultCameraDistanceFactor: defaultCameraDistanceFactor,
            updateState: { [weak self] (currentMprAxis: VolumetricSceneController.Axis,
                                        mprPlaneIndex: Int,
                                        mprNormalizedPosition: Float,
                                        mprEuler: SIMD3<Float>,
                                        fallbackCameraTransform: simd_float4x4,
                                        initialCameraTransform: simd_float4x4,
                                        defaultCameraTarget: SCNVector3) in
                guard let self else { return }
                self.currentMprAxis = currentMprAxis
                self.mprPlaneIndex = mprPlaneIndex
                self.mprNormalizedPosition = mprNormalizedPosition
                self.mprEuler = mprEuler
                self.fallbackCameraTransform = fallbackCameraTransform
                self.initialCameraTransform = initialCameraTransform
                self.defaultCameraTarget = defaultCameraTarget
            }
        )
    }

    // MARK: - Adaptive Sampling Support

#if canImport(UIKit)
    func attachAdaptiveHandlersIfNeeded() {
        guard let recognizers = sceneView.gestureRecognizers else { return }
        for recognizer in recognizers {
            let identifier = ObjectIdentifier(recognizer)
            if adaptiveRecognizers.contains(identifier) { continue }
            recognizer.addTarget(self, action: #selector(handleAdaptiveGesture(_:)))
            adaptiveRecognizers.insert(identifier)
        }
    }

    @objc func handleAdaptiveGesture(_ recognizer: UIGestureRecognizer) {
        guard adaptiveSamplingEnabled else { return }
        switch recognizer.state {
        case .began:
            applyAdaptiveSampling()
        case .ended, .cancelled, .failed:
            restoreSamplingStep()
        default:
            break
        }
    }
#endif

    func applyAdaptiveSampling() {
        guard adaptiveSamplingEnabled, !isAdaptiveSamplingActive else { return }
        isAdaptiveSamplingActive = true
        let reducedStep = max(64, baseSamplingStep * adaptiveInteractionFactor)
        volumeMaterial.setStep(reducedStep)
    }

    func restoreSamplingStep() {
        guard isAdaptiveSamplingActive else {
            volumeMaterial.setStep(baseSamplingStep)
            return
        }
        isAdaptiveSamplingActive = false
        volumeMaterial.setStep(baseSamplingStep)
    }
}
#endif
