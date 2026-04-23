//
//  VolumeViewportControllerStub.swift
//  MetalVolumetrics
//
//  Platform stub implementation for VolumeViewportController on non-iOS/macOS platforms.
//  Provides a minimal conforming implementation that allows code to compile and run
//  on platforms where Metal is unavailable. This stub maintains the
//  same public API surface while providing no-op implementations.
//
//  Thales Matheus Mendonça Santos - February 2025
//

#if !os(iOS) && !os(macOS)
import Foundation
import CoreGraphics
import simd
import Combine
import MTKCore

@MainActor
public final class VolumeViewportController: VolumeViewportControlling, ObservableObject {
    private final class StubSurface: ViewportPresenting {
#if os(macOS)
        let view = PlatformView(frame: .zero)
#else
        let view = PlatformView()
#endif

        func setContentScale(_ scale: CGFloat) { _ = scale }
    }

    public let surface: any ViewportPresenting
    public var transferFunctionDomain: ClosedRange<Float>?
    private var storedMetadata: (dimension: SIMD3<Int32>, resolution: SIMD3<Float>)?

    public let statePublisher = VolumetricStatePublisher()

    public var cameraState: VolumetricCameraState {
        statePublisher.cameraState
    }

    public var sliceState: VolumetricSliceState {
        statePublisher.sliceState
    }

    public var windowLevelState: VolumetricWindowLevelState {
        statePublisher.windowLevelState
    }

    public var adaptiveSamplingEnabled: Bool {
        statePublisher.adaptiveSamplingEnabled
    }

    public var renderQualityState: RenderQualityState {
        statePublisher.qualityState
    }

    private var stubCameraPosition = SIMD3<Float>(0, 0, 2)
    private var stubCameraTarget = SIMD3<Float>(0, 0, 0)
    private var stubCameraUp = SIMD3<Float>(0, 1, 0)
    public enum Axis: Int {
        case x = 0
        case y = 1
        case z = 2
    }

    public struct SlabConfiguration: Equatable {
        public var thickness: Int
        public var steps: Int

        public init(thickness: Int, steps: Int) {
            self.thickness = thickness
            self.steps = steps
        }
    }

    public enum DisplayConfiguration: Equatable {
        case volume(method: VolumetricRenderMethod)
        case mpr(axis: Axis, index: Int, blend: VolumetricMPRBlendMode, slab: SlabConfiguration?)
    }

    public enum VolumeDisplayConfiguration: Equatable {
        case method(VolumetricRenderMethod)

        var displayConfiguration: DisplayConfiguration {
            switch self {
            case .method(let method):
                return .volume(method: method)
            }
        }
    }

    public init() {
        surface = StubSurface()
    }

    public func applyDataset(_ dataset: VolumeDataset) async {
        _ = dataset
        storedMetadata = nil
    }

    public func setDisplayConfiguration(_ configuration: DisplayConfiguration) async {
        _ = configuration
    }

    public func metadata() -> (dimension: SIMD3<Int32>, resolution: SIMD3<Float>)? {
        storedMetadata
    }

    public func setTransferFunction(_ transferFunction: TransferFunction?) async throws {
        _ = transferFunction
    }

    /// Sets the volume rendering method; this is the preferred API for DVR/MIP/MinIP/Avg changes.
    public func setVolumeMethod(_ method: VolumetricRenderMethod) async { _ = method }

    public func setPreset(_ preset: VolumeRenderingBuiltinPreset) async { _ = preset }

    public func setShift(_ shift: Float) async { _ = shift }

    public func setHuGate(enabled: Bool) async { _ = enabled }

    public func setHuWindow(_ window: VolumetricHUWindowMapping) async {
        transferFunctionDomain = Float(window.minHU)...Float(window.maxHU)
        statePublisher.recordWindowLevelState(window)
    }

    public func setRenderMode(_ mode: VolumetricRenderMode) async { _ = mode }

    public func updateTransferFunctionShift(_ shift: Float) async { _ = shift }

    public func setAdaptiveSampling(_ enabled: Bool) async {
        statePublisher.setAdaptiveSamplingFlag(enabled)
    }

    public func beginAdaptiveSamplingInteraction() async {}

    public func endAdaptiveSamplingInteraction() async {}

    public func forceFinalRenderQuality() async {
        statePublisher.recordRenderQualityState(.settled)
    }

    /// Deprecated compatibility alias; use ``setVolumeMethod(_:)`` for volume method changes.
    @available(*, deprecated, message: "Use setVolumeMethod(_:) instead")
    public func setRenderMethod(_ method: VolumetricRenderMethod) async {
        await setVolumeMethod(method)
    }

    public func setLighting(enabled: Bool) async { _ = enabled }

    public func setSamplingStep(_ step: Float) async { _ = step }

    public func setProjectionsUseTransferFunction(_ enabled: Bool) async { _ = enabled }

    public func setProjectionDensityGate(floor: Float, ceil: Float) async {
        _ = (floor, ceil)
    }

    public func setProjectionHuGate(enabled: Bool, min: Int32, max: Int32) async {
        _ = (enabled, min, max)
    }

    public func setMprBlend(_ mode: VolumetricMPRBlendMode) async { _ = mode }

    public func setMprSlab(thickness: Int, steps: Int) async {
        _ = (thickness, steps)
    }

    public func setMprHuWindow(min: Int32, max: Int32) async {
        _ = (min, max)
    }

    public func setMprPlane(axis: Axis, normalized: Float) async {
        statePublisher.recordSliceState(axis: axis, normalized: normalized)
    }

    public func translate(axis: Axis, deltaNormalized: Float) async {
        await setMprPlane(axis: axis, normalized: sliceState.normalizedPosition + deltaNormalized)
    }

    public func rotate(axis: Axis, radians: Float) async {
        _ = (axis, radians)
    }

    public func resetView() async {}

    public func resetCamera() async {
        stubCameraPosition = SIMD3<Float>(0, 0, 2)
        stubCameraTarget = .zero
        stubCameraUp = SIMD3<Float>(0, 1, 0)
        statePublisher.recordCameraState(position: stubCameraPosition,
                                         target: stubCameraTarget,
                                         up: stubCameraUp)
    }

    public func rotateCamera(screenDelta: SIMD2<Float>) async {
        stubCameraTarget += SIMD3<Float>(screenDelta.x * 0.01, screenDelta.y * 0.01, 0)
        statePublisher.recordCameraState(position: stubCameraPosition,
                                         target: stubCameraTarget,
                                         up: stubCameraUp)
    }

    public func tiltCamera(roll: Float, pitch: Float) async {
        stubCameraUp = SIMD3<Float>(0, 1, 0) + SIMD3<Float>(roll * 0.01, pitch * 0.01, 0)
        statePublisher.recordCameraState(position: stubCameraPosition,
                                         target: stubCameraTarget,
                                         up: stubCameraUp)
    }

    public func panCamera(screenDelta: SIMD2<Float>) async {
        let delta = SIMD3<Float>(screenDelta.x * 0.01, screenDelta.y * 0.01, 0)
        stubCameraPosition += delta
        stubCameraTarget += delta
        statePublisher.recordCameraState(position: stubCameraPosition,
                                         target: stubCameraTarget,
                                         up: stubCameraUp)
    }

    public func dollyCamera(delta: Float) async {
        stubCameraPosition.z += delta * 0.1
        statePublisher.recordCameraState(position: stubCameraPosition,
                                         target: stubCameraTarget,
                                         up: stubCameraUp)
    }
}
#endif
