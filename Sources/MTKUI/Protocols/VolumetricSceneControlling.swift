//
//  VolumetricSceneControlling.swift
//  MetalVolumetrics
//
//  Protocol abstraction for volumetric scene rendering coordination.
//  Defines the public API contract for dataset application, display
//  configuration, and camera interaction. Enables platform-agnostic
//  presentation layer integration.
//
//  Thales Matheus Mendonça Santos - September 2025
//

import Foundation
import MTKCore

// MARK: - Supporting Types

/// Represents the camera pose in 3D space for volumetric rendering.
/// Used for publishing camera state changes to SwiftUI observers.
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

/// Represents the current MPR slice position along a specific axis.
/// The normalizedPosition is in the range [0, 1] across the volume.
public struct VolumetricSliceState: Equatable {
    public var axis: VolumetricSceneController.Axis
    public var normalizedPosition: Float

    public init(axis: VolumetricSceneController.Axis = .z,
                normalizedPosition: Float = 0.5) {
        self.axis = axis
        self.normalizedPosition = normalizedPosition
    }
}

/// Represents the current window/level settings for HU windowing.
/// Window is the range width, level is the center value.
public struct VolumetricWindowLevelState: Equatable {
    public var window: Double
    public var level: Double

    public init(window: Double = .zero, level: Double = .zero) {
        self.window = window
        self.level = level
    }
}

/// Available rendering backends for volumetric display.
/// SceneKit uses fragment shaders, MPS uses compute pipelines.
public enum VolumetricRenderingBackend: Int, CaseIterable, Equatable, Sendable {
    case sceneKit
    case metalPerformanceShaders

    public var displayName: String {
        switch self {
        case .sceneKit:
            return "SceneKit"
        case .metalPerformanceShaders:
            return "Metal Performance Shaders"
        }
    }
}

/// Render mode controlling whether the scene actively updates or is paused.
public enum VolumetricRenderMode {
    case active
    case paused
}

/// Represents a performance hotspot with optimization suggestions.
/// Used for profiling and performance analysis in volumetric rendering.
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

// MARK: - Protocol Definition

#if os(iOS) || os(macOS)
import MTKCore
import MTKSceneKit
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
import MetalKit
#endif

/// Protocol defining the public API for volumetric scene rendering coordination.
/// Implementers orchestrate dataset application, display configuration, camera control,
/// and rendering settings for both volume and MPR visualization modes.
@MainActor
public protocol VolumetricSceneControlling: AnyObject {
    var surface: any RenderSurface { get }
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
    var mpsView: MTKView? { get }
#endif
    var transferFunctionDomain: ClosedRange<Float>? { get }

    func applyDataset(_ dataset: VolumeDataset) async
    func setDisplayConfiguration(_ configuration: VolumetricSceneController.DisplayConfiguration) async
    func metadata() -> (dimension: SIMD3<Int32>, resolution: SIMD3<Float>)?

    func setTransferFunction(_ transferFunction: TransferFunction?) async throws
    func setVolumeMethod(_ method: VolumeCubeMaterial.Method) async
    func setPreset(_ preset: VolumeCubeMaterial.Preset) async
    func setShift(_ shift: Float) async
    func setHuGate(enabled: Bool) async
    func setHuWindow(_ window: VolumeCubeMaterial.HuWindowMapping) async
    func setRenderMode(_ mode: VolumetricRenderMode) async
    func setRenderingBackend(_ backend: VolumetricRenderingBackend) async -> VolumetricRenderingBackend
    func updateTransferFunctionShift(_ shift: Float) async
    func setAdaptiveSampling(_ enabled: Bool) async
    func beginAdaptiveSamplingInteraction() async
    func endAdaptiveSamplingInteraction() async
    func setRenderMethod(_ method: VolumeCubeMaterial.Method) async
    func setLighting(enabled: Bool) async
    func setSamplingStep(_ step: Float) async
    func setProjectionsUseTransferFunction(_ enabled: Bool) async
    func setProjectionDensityGate(floor: Float, ceil: Float) async
    func setProjectionHuGate(enabled: Bool, min: Int32, max: Int32) async
    func setMprBlend(_ mode: MPRPlaneMaterial.BlendMode) async
    func setMprSlab(thickness: Int, steps: Int) async
    func setMprHuWindow(min: Int32, max: Int32) async
    func setMprPlane(axis: VolumetricSceneController.Axis, normalized: Float) async
    func translate(axis: VolumetricSceneController.Axis, deltaNormalized: Float) async
    func rotate(axis: VolumetricSceneController.Axis, radians: Float) async
    func resetView() async
    func resetCamera() async

    func rotateCamera(screenDelta: SIMD2<Float>) async
    func tiltCamera(roll: Float, pitch: Float) async
    func panCamera(screenDelta: SIMD2<Float>) async
    func dollyCamera(delta: Float) async
}

#else
import MTKCore
import MTKSceneKit
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
import MetalKit
#endif

@MainActor
public protocol VolumetricSceneControlling: AnyObject {
    var surface: any RenderSurface { get }
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
    var mpsView: MTKView? { get }
#endif
    var transferFunctionDomain: ClosedRange<Float>? { get }

    func applyDataset(_ dataset: VolumeDataset) async
    func setDisplayConfiguration(_ configuration: VolumetricSceneController.DisplayConfiguration) async
    func metadata() -> (dimension: SIMD3<Int32>, resolution: SIMD3<Float>)?

    func setTransferFunction(_ transferFunction: TransferFunction?) async throws
    func setVolumeMethod(_ method: VolumeCubeMaterial.Method) async
    func setPreset(_ preset: VolumeCubeMaterial.Preset) async
    func setShift(_ shift: Float) async
    func setHuGate(enabled: Bool) async
    func setHuWindow(_ window: VolumeCubeMaterial.HuWindowMapping) async
    func setRenderMode(_ mode: VolumetricRenderMode) async
    func setRenderingBackend(_ backend: VolumetricRenderingBackend) async -> VolumetricRenderingBackend
    func updateTransferFunctionShift(_ shift: Float) async
    func setAdaptiveSampling(_ enabled: Bool) async
    func beginAdaptiveSamplingInteraction() async
    func endAdaptiveSamplingInteraction() async
    func setRenderMethod(_ method: VolumeCubeMaterial.Method) async
    func setLighting(enabled: Bool) async
    func setSamplingStep(_ step: Float) async
    func setProjectionsUseTransferFunction(_ enabled: Bool) async
    func setProjectionDensityGate(floor: Float, ceil: Float) async
    func setProjectionHuGate(enabled: Bool, min: Int32, max: Int32) async
    func setMprBlend(_ mode: MPRPlaneMaterial.BlendMode) async
    func setMprSlab(thickness: Int, steps: Int) async
    func setMprHuWindow(min: Int32, max: Int32) async
    func setMprPlane(axis: VolumetricSceneController.Axis, normalized: Float) async
    func translate(axis: VolumetricSceneController.Axis, deltaNormalized: Float) async
    func rotate(axis: VolumetricSceneController.Axis, radians: Float) async
    func resetView() async
    func resetCamera() async

    func rotateCamera(screenDelta: SIMD2<Float>) async
    func tiltCamera(roll: Float, pitch: Float) async
    func panCamera(screenDelta: SIMD2<Float>) async
    func dollyCamera(delta: Float) async
}
#endif
