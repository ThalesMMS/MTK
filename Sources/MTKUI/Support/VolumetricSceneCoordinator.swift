//
//  VolumetricSceneCoordinator.swift
//  MTKUI
//
//  Coordinator for volumetric scene controller instances.
//  Manages MTK controller instances for MPR and volume rendering with comprehensive state synchronization.
//  Originally from MTK-Demo MTKOverlayCoordinator — Promoted to MTKUI for reusability.
//  Thales Matheus Mendonça Santos — November 2025
//

import Combine
import Foundation
import Metal
import MTKCore
import MTKSceneKit

/// Coordinator that manages MTK volumetric scene controllers
/// Provides singleton access to MTK controllers for SwiftUI views
@MainActor
public final class VolumetricSceneCoordinator: ObservableObject {
    /// Shared singleton instance
    public static let shared = VolumetricSceneCoordinator()

    /// Whether a Metal device was successfully resolved
    @Published public private(set) var isMetalAvailable: Bool

    private enum SurfaceKey: Hashable {
        case volume
        case mpr(VolumetricSceneController.Axis)
    }

    private struct MprConfiguration {
        var blend: MPRPlaneMaterial.BlendMode
        var slab: VolumetricSceneController.SlabConfiguration?
        var normalizedPosition: Float
    }

    private var controllers: [SurfaceKey: VolumetricSceneController] = [:]
    private var controllerCancellables: [SurfaceKey: Set<AnyCancellable>] = [:]
    private var pendingDataset: VolumeDataset?
    private var pendingTransferFunction: TransferFunction?
    private var pendingHuWindow: VolumeCubeMaterial.HuWindowMapping?
    private var volumeConfiguration: VolumetricSceneController.DisplayConfiguration = .volume(method: .dvr)
    private var mprConfigurations: [VolumetricSceneController.Axis: MprConfiguration] = [
        .x: MprConfiguration(blend: .single, slab: nil, normalizedPosition: 0.5),
        .y: MprConfiguration(blend: .single, slab: nil, normalizedPosition: 0.5),
        .z: MprConfiguration(blend: .single, slab: nil, normalizedPosition: 0.5)
    ]
    private let device: (any MTLDevice)?
    private var stubControllers: [SurfaceKey: VolumetricSceneController] = [:]
    @Published public private(set) var rendererState = VolumetricRendererState(
        normalizedMprPositions: [
            VolumetricSceneController.Axis.x: 0.5,
            VolumetricSceneController.Axis.y: 0.5,
            VolumetricSceneController.Axis.z: 0.5
        ]
    )

    private init() {
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            self.device = metalDevice
            self.isMetalAvailable = true
        } else {
            self.device = nil
            self.isMetalAvailable = false
        }
    }

    /// Primary controller used for the preview overlay and volume rendering tile
    public var controller: VolumetricSceneController {
        controller(for: .volume)
    }

    /// Returns (or creates) the controller dedicated to a specific MPR axis
    /// - Parameter axis: The MPR axis (.x, .y, or .z)
    /// - Returns: The volumetric scene controller for that axis
    public func controller(for axis: VolumetricSceneController.Axis) -> VolumetricSceneController {
        controller(for: .mpr(axis))
    }

    /// Clears all cached controllers (useful for tests)
    public func reset() {
        controllers.removeAll()
        controllerCancellables.removeAll()
        pendingDataset = nil
        pendingTransferFunction = nil
        pendingHuWindow = nil
        volumeConfiguration = .volume(method: .dvr)
        mprConfigurations = [
            .x: MprConfiguration(blend: .single, slab: nil, normalizedPosition: 0.5),
            .y: MprConfiguration(blend: .single, slab: nil, normalizedPosition: 0.5),
            .z: MprConfiguration(blend: .single, slab: nil, normalizedPosition: 0.5)
        ]
        stubControllers.removeAll()
        updateRendererState { state in
            state.dataset = nil
            state.huWindow = nil
            state.transferFunction = nil
            state.normalizedMprPositions = [
                .x: 0.5,
                .y: 0.5,
                .z: 0.5
            ]
        }
    }

    /// Applies a new dataset to all managed controllers, creating them on-demand
    /// - Parameter dataset: The volume dataset to apply
    public func apply(dataset: VolumeDataset) {
        guard isMetalAvailable else { return }
        pendingDataset = dataset
        updateRendererState { state in
            state.dataset = VolumetricRendererState.DatasetSummary(
                dimensions: dataset.dimensions,
                spacing: dataset.spacing,
                intensityRange: dataset.intensityRange,
                orientation: dataset.orientation
            )
        }
        controllers.forEach { surface, controller in
            Task { await propagateState(to: controller, surface: surface) }
        }
    }

    /// Propagates the active transfer function to all controllers (volume + MPR)
    /// - Parameter transferFunction: The transfer function to apply (nil to clear)
    public func apply(transferFunction: TransferFunction?) {
        guard isMetalAvailable else { return }
        pendingTransferFunction = transferFunction
        updateRendererState { $0.transferFunction = transferFunction }
        controllers.forEach { surface, controller in
            Task { await propagateState(to: controller, surface: surface) }
        }
    }

    /// Synchronizes HU window and level with all registered controllers
    /// - Parameters:
    ///   - min: Minimum HU value
    ///   - max: Maximum HU value
    public func applyHuWindow(min: Int32, max: Int32) {
        guard isMetalAvailable else { return }
        let mapping = makeHuMapping(min: min, max: max)
        pendingHuWindow = mapping
        updateRendererState { $0.huWindow = mapping }
        controllers.forEach { surface, controller in
            Task { await propagateState(to: controller, surface: surface) }
        }
    }

    /// Ensures the shared volume controller renders with the expected configuration (e.g., DVR)
    /// - Parameter configuration: The display configuration to apply
    public func configureVolumeDisplay(_ configuration: VolumetricSceneController.DisplayConfiguration) {
        guard isMetalAvailable else { return }
        volumeConfiguration = configuration
        if let controller = controllers[.volume] {
            Task { await propagateState(to: controller, surface: .volume) }
        }
    }

    /// Registers the desired MPR display configuration for the specified axis
    /// - Parameters:
    ///   - axis: The MPR axis to configure
    ///   - blend: The blend mode (default: .single)
    ///   - slab: Optional slab configuration
    ///   - normalizedPosition: Normalized position along axis (0...1, default: 0.5)
    public func configureMPRDisplay(axis: VolumetricSceneController.Axis,
                                    blend: MPRPlaneMaterial.BlendMode = .single,
                                    slab: VolumetricSceneController.SlabConfiguration? = nil,
                                    normalizedPosition: Float = 0.5) {
        guard isMetalAvailable else { return }
        let clamped = clamp(normalizedPosition, lower: 0, upper: 1)
        mprConfigurations[axis] = MprConfiguration(blend: blend,
                                                   slab: slab,
                                                   normalizedPosition: clamped)
        updateRendererState { $0.normalizedMprPositions[axis] = clamped }
        if let controller = controllers[.mpr(axis)] {
            Task { await propagateState(to: controller, surface: .mpr(axis)) }
        }
    }

    /// Updates the normalized MPR plane and notifies the controller immediately
    /// - Parameters:
    ///   - axis: The MPR axis to update
    ///   - normalizedPosition: Normalized position along axis (0...1)
    public func setMprPlane(axis: VolumetricSceneController.Axis, normalizedPosition: Float) {
        guard isMetalAvailable else { return }
        let clamped = clamp(normalizedPosition, lower: 0, upper: 1)
        if var config = mprConfigurations[axis] {
            config.normalizedPosition = clamped
            mprConfigurations[axis] = config
            if let controller = controllers[.mpr(axis)] {
                Task {
                    await controller.setMprPlane(axis: axis, normalized: clamped)
                }
            }
        }
    }

    private func controller(for surface: SurfaceKey) -> VolumetricSceneController {
        if !isMetalAvailable {
            if let stub = stubControllers[surface]
                ?? (try? VolumetricSceneController(device: nil, sceneView: nil))
                ?? (try? VolumetricSceneController()) {
                stubControllers[surface] = stub
                controllers[surface] = stub
                return stub
            }
            fatalError("Failed to create stub VolumetricSceneController without Metal.")
        }

        if let existing = controllers[surface] {
            return existing
        }

        let newController: VolumetricSceneController
#if os(iOS) || os(macOS)
        guard let device else {
            if let stub = stubControllers[surface]
                ?? (try? VolumetricSceneController(device: nil, sceneView: nil))
                ?? (try? VolumetricSceneController()) {
                stubControllers[surface] = stub
                controllers[surface] = stub
                return stub
            }
            fatalError("Failed to create fallback VolumetricSceneController when Metal device is unavailable.")
        }
        newController = (try? VolumetricSceneController(device: device))
            ?? (try? VolumetricSceneController(device: nil, sceneView: nil))
            ?? (try? VolumetricSceneController())
            ?? {
                fatalError("Failed to create VolumetricSceneController with or without Metal device.")
            }()
#else
        newController = (try? VolumetricSceneController(device: nil, sceneView: nil))
            ?? (try? VolumetricSceneController())
            ?? {
                fatalError("Failed to create VolumetricSceneController stub on unsupported platform.")
            }()
#endif

        controllers[surface] = newController
        attachObservers(to: newController, surface: surface)

        Task { await propagateState(to: newController, surface: surface) }

        return newController
    }

    private func makeHuMapping(min: Int32, max: Int32) -> VolumeCubeMaterial.HuWindowMapping {
        if let dataset = pendingDataset {
            return VolumeCubeMaterial.makeHuWindowMapping(minHU: min,
                                                          maxHU: max,
                                                          datasetRange: dataset.intensityRange,
                                                          transferDomain: nil)
        }
        return VolumeCubeMaterial.HuWindowMapping(minHU: min, maxHU: max, tfMin: 0, tfMax: 1)
    }

    private func propagateState(to controller: VolumetricSceneController,
                                surface: SurfaceKey) async {
        if let dataset = pendingDataset {
            await controller.applyDataset(dataset)
        }
        if let transfer = pendingTransferFunction {
            try? await controller.setTransferFunction(transfer)
        }
        if let window = pendingHuWindow {
            await controller.setHuWindow(window)
            await controller.setMprHuWindow(min: window.minHU, max: window.maxHU)
        }

        switch surface {
        case .volume:
            await controller.setDisplayConfiguration(volumeConfiguration)
        case let .mpr(axis):
            let config = mprConfigurations[axis] ?? MprConfiguration(blend: .single, slab: nil, normalizedPosition: 0.5)
            let index = makeMprIndex(axis: axis, normalized: config.normalizedPosition)
            await controller.setDisplayConfiguration(.mpr(axis: axis,
                                                          index: index,
                                                          blend: config.blend,
                                                          slab: config.slab))
            await controller.setMprPlane(axis: axis, normalized: config.normalizedPosition)
        }
    }

    private func makeMprIndex(axis: VolumetricSceneController.Axis, normalized: Float) -> Int {
        guard let dataset = pendingDataset else { return 0 }
        let dimensions = dataset.dimensions
        let voxelCount: Int
        switch axis {
        case .x:
            voxelCount = max(Int(dimensions.width) - 1, 0)
        case .y:
            voxelCount = max(Int(dimensions.height) - 1, 0)
        case .z:
            voxelCount = max(Int(dimensions.depth) - 1, 0)
        }
        return Int(round(normalized * Float(voxelCount)))
    }

    @inline(__always)
    private func clamp(_ value: Float, lower: Float, upper: Float) -> Float {
        return min(max(value, lower), upper)
    }

    private func attachObservers(to controller: VolumetricSceneController,
                                 surface: SurfaceKey) {
        var cancellables = Set<AnyCancellable>()

        if case .volume = surface {
            controller.$windowLevelState
                .sink { [weak self] state in
                    guard let self else { return }
                    let minHU = Int32((state.level - state.window / 2).rounded())
                    let maxHU = Int32((state.level + state.window / 2).rounded())
                    let datasetRange = self.pendingDataset?.intensityRange ??
                        self.rendererState.dataset?.intensityRange ??
                        (-1024...3071)
                    updateRendererState { renderer in
                        renderer.huWindow = VolumeCubeMaterial.makeHuWindowMapping(
                            minHU: minHU,
                            maxHU: maxHU,
                            datasetRange: datasetRange,
                            transferDomain: nil
                        )
                    }
                }
                .store(in: &cancellables)
        }

        if case let .mpr(axis) = surface {
            controller.$sliceState
                .sink { [weak self] slice in
                    guard let self else { return }
                    updateRendererState { state in
                        state.normalizedMprPositions[axis] = slice.normalizedPosition
                    }
                }
                .store(in: &cancellables)
        }

        controllerCancellables[surface] = cancellables
    }

    private func updateRendererState(_ update: (inout VolumetricRendererState) -> Void) {
        var snapshot = rendererState
        update(&snapshot)
        rendererState = snapshot
    }

    public func rendererStateSnapshot() -> VolumetricRendererState {
        rendererState
    }

    public func updateToneCurves(_ snapshots: [VolumetricRendererState.ToneCurveSnapshot]) {
        updateRendererState { $0.toneCurves = snapshots }
    }

    public func updateClipState(bounds: ClipBoundsSnapshot?, plane: ClipPlaneSnapshot?) {
        updateRendererState {
            $0.clipBounds = bounds
            $0.clipPlane = plane
        }
    }

}
