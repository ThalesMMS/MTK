//
//  VolumeViewportControlling.swift
//  MTKUI
//

import Foundation
import MTKCore
import simd

public struct VolumetricCameraState: Equatable {
    public var position: SIMD3<Float>
    public var target: SIMD3<Float>
    public var up: SIMD3<Float>
    public var projectionType: ProjectionType

    public init(position: SIMD3<Float> = .zero,
                target: SIMD3<Float> = .zero,
                up: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
                projectionType: ProjectionType = .perspective) {
        self.position = position
        self.target = target
        self.up = up
        self.projectionType = projectionType
    }
}

public struct VolumetricSliceState: Equatable {
    public var axis: VolumeViewportController.Axis
    public var normalizedPosition: Float

    public init(axis: VolumeViewportController.Axis = .z,
                normalizedPosition: Float = 0.5) {
        self.axis = axis
        self.normalizedPosition = normalizedPosition
    }
}

public struct VolumetricWindowLevelState: Equatable {
    public var window: Double
    public var level: Double

    public init(window: Double = .zero, level: Double = .zero) {
        self.window = window
        self.level = level
    }
}

public enum VolumetricRenderMode {
    case active
    case paused
}

public struct VolumetricHotspot: Equatable {
    public let identifier: String
    public let description: String
    public let suggestion: String

    public init(identifier: String, description: String, suggestion: String) {
        self.identifier = identifier
        self.description = description
        self.suggestion = suggestion
    }
}

@MainActor
public protocol VolumeViewportControlling: AnyObject {
    var surface: any ViewportPresenting { get }
    var transferFunctionDomain: ClosedRange<Float>? { get }
    var renderQualityState: RenderQualityState { get }

    func applyDataset(_ dataset: VolumeDataset) async
    func setDisplayConfiguration(_ configuration: VolumeViewportController.DisplayConfiguration) async
    func metadata() -> (dimension: SIMD3<Int32>, resolution: SIMD3<Float>)?

    func setTransferFunction(_ transferFunction: TransferFunction?) async throws
    /// Sets the volume rendering method; this is the preferred API for DVR/MIP/MinIP/Avg changes.
    func setVolumeMethod(_ method: VolumetricRenderMethod) async
    func setPreset(_ preset: VolumeRenderingBuiltinPreset) async
    func setShift(_ shift: Float) async
    func setHuGate(enabled: Bool) async
    func setHuWindow(_ window: VolumetricHUWindowMapping) async
    func setRenderMode(_ mode: VolumetricRenderMode) async
    func updateTransferFunctionShift(_ shift: Float) async
    func setAdaptiveSampling(_ enabled: Bool) async
    func beginAdaptiveSamplingInteraction() async
    func endAdaptiveSamplingInteraction() async
    func forceFinalRenderQuality() async
    /// Deprecated compatibility alias; use ``setVolumeMethod(_:)`` for volume method changes.
    @available(*, deprecated, message: "Use setVolumeMethod(_:) instead")
    func setRenderMethod(_ method: VolumetricRenderMethod) async
    func setLighting(enabled: Bool) async
    func setSamplingStep(_ step: Float) async
    func setProjectionsUseTransferFunction(_ enabled: Bool) async
    func setProjectionDensityGate(floor: Float, ceil: Float) async
    func setProjectionHuGate(enabled: Bool, min: Int32, max: Int32) async
    func setMprBlend(_ mode: VolumetricMPRBlendMode) async
    func setMprSlab(thickness: Int, steps: Int) async
    func setMprHuWindow(min: Int32, max: Int32) async
    func setMprPlane(axis: VolumeViewportController.Axis, normalized: Float) async
    func translate(axis: VolumeViewportController.Axis, deltaNormalized: Float) async
    func rotate(axis: VolumeViewportController.Axis, radians: Float) async
    func resetView() async
    func resetCamera() async

    func rotateCamera(screenDelta: SIMD2<Float>) async
    func tiltCamera(roll: Float, pitch: Float) async
    func panCamera(screenDelta: SIMD2<Float>) async
    func dollyCamera(delta: Float) async
}
