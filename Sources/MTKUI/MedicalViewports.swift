//
//  MedicalViewports.swift
//  MTKUI
//
//  Public medical viewport contracts backed by the existing Metal-native controllers.
//

import Combine
import CoreGraphics
import Foundation
@preconcurrency import Metal
import MTKCore
import simd

/// Public MTKUI viewport categories for downstream medical viewers.
public enum MedicalViewportType: Hashable, Sendable {
    case stack(axis: MTKCore.Axis)
    case volume(axis: MTKCore.Axis)
    case projection(mode: ProjectionMode)
    case volume3D
}

/// Public render-mode snapshot for a medical viewport.
public enum MedicalViewportRenderMode: Equatable, Sendable {
    case stack
    case mpr(blend: VolumetricMPRBlendMode)
    case projection(mode: ProjectionMode)
    case volume3D(method: VolumetricRenderMethod)
}

/// Dataset metadata exposed by public viewport contracts without retaining voxel bytes.
public struct MedicalViewportDatasetSummary: Equatable, Sendable {
    public let dimensions: VolumeDimensions
    public let spacing: VolumeSpacing
    public let intensityRange: ClosedRange<Int32>
    public let orientation: VolumeOrientation

    public init(dimensions: VolumeDimensions,
                spacing: VolumeSpacing,
                intensityRange: ClosedRange<Int32>,
                orientation: VolumeOrientation) {
        self.dimensions = dimensions
        self.spacing = spacing
        self.intensityRange = intensityRange
        self.orientation = orientation
    }

    public init(dataset: VolumeDataset) {
        self.init(dimensions: dataset.dimensions,
                  spacing: dataset.spacing,
                  intensityRange: dataset.intensityRange,
                  orientation: dataset.orientation)
    }
}

/// Public stack/MPR slice state.
public struct MedicalViewportSliceState: Equatable, Sendable {
    public let axis: MTKCore.Axis
    public let index: Int
    public let count: Int
    public let normalizedPosition: Float

    public init(axis: MTKCore.Axis,
                index: Int,
                count: Int,
                normalizedPosition: Float) {
        self.axis = axis
        self.index = index
        self.count = count
        self.normalizedPosition = normalizedPosition
    }
}

/// Public presentation-target state for a Metal-native viewport.
public struct MedicalViewportPresentationState: Equatable, Sendable {
    public let isMetalBacked: Bool
    public let drawablePixelSize: CGSize
    public let lastErrorDescription: String?

    public init(isMetalBacked: Bool,
                drawablePixelSize: CGSize,
                lastErrorDescription: String? = nil) {
        self.isMetalBacked = isMetalBacked
        self.drawablePixelSize = drawablePixelSize
        self.lastErrorDescription = lastErrorDescription
    }
}

/// Consolidated public state for a medical viewport.
public struct MedicalViewportState: Equatable {
    public let viewportID: ViewportID
    public let viewportType: MedicalViewportType
    public let renderMode: MedicalViewportRenderMode
    public let dataset: MedicalViewportDatasetSummary?
    public let camera: VolumetricCameraState
    public let windowLevel: VolumetricWindowLevelState
    public let slice: MedicalViewportSliceState?
    public let clipping: VolumeClippingState
    public let presentation: MedicalViewportPresentationState

    public init(viewportID: ViewportID,
                viewportType: MedicalViewportType,
                renderMode: MedicalViewportRenderMode,
                dataset: MedicalViewportDatasetSummary? = nil,
                camera: VolumetricCameraState = VolumetricCameraState(),
                windowLevel: VolumetricWindowLevelState = VolumetricWindowLevelState(),
                slice: MedicalViewportSliceState? = nil,
                clipping: VolumeClippingState = .disabled,
                presentation: MedicalViewportPresentationState) {
        self.viewportID = viewportID
        self.viewportType = viewportType
        self.renderMode = renderMode
        self.dataset = dataset
        self.camera = camera
        self.windowLevel = windowLevel
        self.slice = slice
        self.clipping = clipping
        self.presentation = presentation
    }
}

/// Shared public contract implemented by MTKUI medical viewports.
@MainActor
public protocol MedicalViewport: AnyObject {
    var id: ViewportID { get }
    var viewportType: MedicalViewportType { get }
    var renderMode: MedicalViewportRenderMode { get }
    var state: MedicalViewportState { get }
    var surface: any ViewportPresenting { get }

    func applyDataset(_ dataset: VolumeDataset) async
    func setWindowLevel(window: Double, level: Double) async
    func resetCamera() async
}

/// Volume-backed stack viewport for predictable slice scrolling.
@MainActor
public final class StackViewport: ObservableObject, MedicalViewport {
    public let id: ViewportID
    public let axis: MTKCore.Axis
    public let metalSurface: MetalViewportSurface
    @Published public private(set) var state: MedicalViewportState
    @Published public private(set) var sliceIndex: Int
    @Published public private(set) var sliceCount: Int = 0

    public var surface: any ViewportPresenting { metalSurface }
    public var viewportType: MedicalViewportType { .stack(axis: axis) }
    public var renderMode: MedicalViewportRenderMode { .stack }

    private let controller: VolumeViewportController
    private var dataset: VolumeDataset?

    public init(axis: MTKCore.Axis = .axial,
                initialSliceIndex: Int = 0,
                device: (any MTLDevice)? = nil,
                surface: MetalViewportSurface? = nil) throws {
        let controller = try VolumeViewportController(device: device, surface: surface)
        self.id = ViewportID()
        self.axis = axis
        self.controller = controller
        self.metalSurface = controller.viewportSurface
        let resolvedSliceIndex = max(0, initialSliceIndex)
        self.sliceIndex = resolvedSliceIndex
        self.state = Self.makeState(id: id,
                                    axis: axis,
                                    controller: controller,
                                    dataset: nil,
                                    index: resolvedSliceIndex,
                                    count: 0)
    }

    public func applyDataset(_ dataset: VolumeDataset) async {
        self.dataset = dataset
        sliceCount = Self.sliceCount(for: axis, in: dataset)
        sliceIndex = Self.clamp(sliceIndex, count: sliceCount)
        await controller.applyDataset(dataset)
        await configureController()
        refreshState()
    }

    public func setSliceIndex(_ index: Int) async {
        sliceIndex = Self.clamp(index, count: sliceCount)
        await configureController()
        refreshState()
    }

    public func scroll(by delta: Int, loop: Bool = false) async {
        guard sliceCount > 0 else {
            await setSliceIndex(0)
            return
        }

        let target = sliceIndex + delta
        if loop {
            let wrapped = ((target % sliceCount) + sliceCount) % sliceCount
            await setSliceIndex(wrapped)
        } else {
            await setSliceIndex(target)
        }
    }

    public func setWindowLevel(window: Double, level: Double) async {
        let mapping = Self.windowMapping(window: window,
                                         level: level,
                                         dataset: dataset,
                                         transferDomain: controller.transferFunctionDomain)
        await controller.setHuWindow(mapping)
        await controller.setMprHuWindow(min: mapping.minHU, max: mapping.maxHU)
        refreshState()
    }

    public func resetCamera() async {
        await controller.resetCamera()
        refreshState()
    }

    private func configureController() async {
        guard sliceCount > 0 else { return }
        let controllerAxis = axis.controllerAxis
        await controller.setDisplayConfiguration(
            .mpr(axis: controllerAxis,
                 index: sliceIndex,
                 blend: .single,
                 slab: nil)
        )
        await controller.setMprPlane(axis: controllerAxis,
                                     normalized: normalizedPosition)
    }

    private var normalizedPosition: Float {
        guard sliceCount > 1 else { return 0 }
        return Float(sliceIndex) / Float(sliceCount - 1)
    }

    private func refreshState() {
        state = Self.makeState(id: id,
                               axis: axis,
                               controller: controller,
                               dataset: dataset,
                               index: sliceIndex,
                               count: sliceCount)
    }

    private static func makeState(id: ViewportID,
                                  axis: MTKCore.Axis,
                                  controller: VolumeViewportController,
                                  dataset: VolumeDataset?,
                                  index: Int,
                                  count: Int) -> MedicalViewportState {
        let normalized = count > 1 ? Float(index) / Float(count - 1) : 0
        let slice = MedicalViewportSliceState(axis: axis,
                                              index: index,
                                              count: count,
                                              normalizedPosition: normalized)
        return MedicalViewportState(
            viewportID: id,
            viewportType: .stack(axis: axis),
            renderMode: .stack,
            dataset: dataset.map(MedicalViewportDatasetSummary.init(dataset:)),
            camera: controller.cameraState,
            windowLevel: controller.windowLevelState,
            slice: slice,
            presentation: MedicalViewportPresentationState(surface: controller.viewportSurface)
        )
    }
}

/// Public MPR/projection viewport contract backed by a Metal-native controller.
@MainActor
public final class VolumeViewport: ObservableObject, MedicalViewport {
    public let id: ViewportID
    public let metalSurface: MetalViewportSurface
    @Published public private(set) var state: MedicalViewportState
    @Published public private(set) var axis: MTKCore.Axis
    @Published public private(set) var normalizedSlicePosition: Float
    @Published public private(set) var projectionMode: ProjectionMode?
    @Published public private(set) var blendMode: VolumetricMPRBlendMode
    @Published public private(set) var slab: VolumeViewportController.SlabConfiguration?
    @Published public private(set) var clipping: VolumeClippingState = .disabled

    public var surface: any ViewportPresenting { metalSurface }
    public var viewportType: MedicalViewportType {
        if let projectionMode {
            return .projection(mode: projectionMode)
        }
        return .volume(axis: axis)
    }
    public var renderMode: MedicalViewportRenderMode {
        if let projectionMode {
            return .projection(mode: projectionMode)
        }
        return .mpr(blend: blendMode)
    }

    private let controller: VolumeViewportController
    private var dataset: VolumeDataset?

    public init(axis: MTKCore.Axis = .axial,
                projectionMode: ProjectionMode? = nil,
                normalizedSlicePosition: Float = 0.5,
                blend: VolumetricMPRBlendMode = .single,
                slab: VolumeViewportController.SlabConfiguration? = nil,
                device: (any MTLDevice)? = nil,
                surface: MetalViewportSurface? = nil) throws {
        let controller = try VolumeViewportController(device: device, surface: surface)
        self.id = ViewportID()
        self.axis = axis
        self.projectionMode = projectionMode
        let resolvedNormalizedSlicePosition = VolumetricMath.clampFloat(normalizedSlicePosition,
                                                                        lower: 0,
                                                                        upper: 1)
        self.normalizedSlicePosition = resolvedNormalizedSlicePosition
        self.blendMode = blend
        self.slab = slab
        self.controller = controller
        self.metalSurface = controller.viewportSurface
        self.state = Self.makeState(id: id,
                                    axis: axis,
                                    projectionMode: projectionMode,
                                    blend: blend,
                                    controller: controller,
                                    dataset: nil,
                                    normalized: resolvedNormalizedSlicePosition,
                                    sliceCount: 0,
                                    clipping: .disabled)
    }

    public func applyDataset(_ dataset: VolumeDataset) async {
        self.dataset = dataset
        await controller.applyDataset(dataset)
        await configureController()
        refreshState()
    }

    public func setOrientation(_ axis: MTKCore.Axis) async {
        self.axis = axis
        projectionMode = nil
        await configureController()
        refreshState()
    }

    public func setSlicePosition(_ normalizedPosition: Float) async {
        normalizedSlicePosition = VolumetricMath.clampFloat(normalizedPosition,
                                                           lower: 0,
                                                           upper: 1)
        projectionMode = nil
        await configureController()
        refreshState()
    }

    public func setProjectionMode(_ mode: ProjectionMode?) async {
        projectionMode = mode
        await configureController()
        refreshState()
    }

    public func setVolumeClipping(_ clipping: VolumeClippingState) async throws {
        self.clipping = clipping
        try await controller.setVolumeClipping(clipping)
        refreshState()
    }

    public func clearVolumeClipping() async throws {
        try await setVolumeClipping(.disabled)
    }

    public func setMPRBlend(_ mode: VolumetricMPRBlendMode) async {
        blendMode = mode
        projectionMode = nil
        await configureController()
        refreshState()
    }

    public func setSlab(_ slab: VolumeViewportController.SlabConfiguration?) async {
        self.slab = slab
        projectionMode = nil
        await configureController()
        refreshState()
    }

    public func setWindowLevel(window: Double, level: Double) async {
        let mapping = Self.windowMapping(window: window,
                                         level: level,
                                         dataset: dataset,
                                         transferDomain: controller.transferFunctionDomain)
        await controller.setHuWindow(mapping)
        await controller.setMprHuWindow(min: mapping.minHU, max: mapping.maxHU)
        refreshState()
    }

    public func resetCamera() async {
        await controller.resetCamera()
        refreshState()
    }

    private func configureController() async {
        if let projectionMode {
            await controller.setDisplayConfiguration(
                .volume(method: projectionMode.volumetricMethod)
            )
            return
        }

        let controllerAxis = axis.controllerAxis
        let index = Self.sliceIndex(axis: axis,
                                    normalized: normalizedSlicePosition,
                                    dataset: dataset)
        await controller.setDisplayConfiguration(
            .mpr(axis: controllerAxis,
                 index: index,
                 blend: blendMode,
                 slab: slab)
        )
        await controller.setMprPlane(axis: controllerAxis,
                                     normalized: normalizedSlicePosition)
    }

    private func refreshState() {
        state = Self.makeState(id: id,
                               axis: axis,
                               projectionMode: projectionMode,
                               blend: blendMode,
                               controller: controller,
                               dataset: dataset,
                               normalized: normalizedSlicePosition,
                               sliceCount: dataset.map { Self.sliceCount(for: axis, in: $0) } ?? 0,
                               clipping: clipping)
    }

    private static func makeState(id: ViewportID,
                                  axis: MTKCore.Axis,
                                  projectionMode: ProjectionMode?,
                                  blend: VolumetricMPRBlendMode,
                                  controller: VolumeViewportController,
                                  dataset: VolumeDataset?,
                                  normalized: Float,
                                  sliceCount: Int,
                                  clipping: VolumeClippingState) -> MedicalViewportState {
        let viewportType: MedicalViewportType
        let renderMode: MedicalViewportRenderMode
        let slice: MedicalViewportSliceState?
        if let projectionMode {
            viewportType = .projection(mode: projectionMode)
            renderMode = .projection(mode: projectionMode)
            slice = nil
        } else {
            viewportType = .volume(axis: axis)
            renderMode = .mpr(blend: blend)
            let index = Self.sliceIndex(axis: axis,
                                        normalized: normalized,
                                        dataset: dataset)
            slice = MedicalViewportSliceState(axis: axis,
                                              index: index,
                                              count: sliceCount,
                                              normalizedPosition: normalized)
        }

        return MedicalViewportState(
            viewportID: id,
            viewportType: viewportType,
            renderMode: renderMode,
            dataset: dataset.map(MedicalViewportDatasetSummary.init(dataset:)),
            camera: controller.cameraState,
            windowLevel: controller.windowLevelState,
            slice: slice,
            clipping: projectionMode == nil ? .disabled : clipping,
            presentation: MedicalViewportPresentationState(surface: controller.viewportSurface)
        )
    }
}

/// Public 3D volume viewport contract backed by a Metal-native controller.
@MainActor
public final class VolumeViewport3D: ObservableObject, MedicalViewport {
    public let id: ViewportID
    public let metalSurface: MetalViewportSurface
    @Published public private(set) var state: MedicalViewportState
    @Published public private(set) var method: VolumetricRenderMethod
    @Published public private(set) var clipping: VolumeClippingState = .disabled
    @Published public private(set) var volumeLayers: [MTKCore.VolumeLayer] = []

    public var surface: any ViewportPresenting { metalSurface }
    public var viewportType: MedicalViewportType { .volume3D }
    public var renderMode: MedicalViewportRenderMode { .volume3D(method: method) }

    private let controller: VolumeViewportController
    private var dataset: VolumeDataset?
    private var surfaceMeshLayers: [SurfaceMeshLayer] = []

    public init(method: VolumetricRenderMethod = .dvr,
                device: (any MTLDevice)? = nil,
                surface: MetalViewportSurface? = nil) throws {
        let controller = try VolumeViewportController(device: device, surface: surface)
        self.id = ViewportID()
        self.method = method
        self.controller = controller
        self.metalSurface = controller.viewportSurface
        self.state = Self.makeState(id: id,
                                    method: method,
                                    controller: controller,
                                    dataset: nil)
    }

    public func applyDataset(_ dataset: VolumeDataset) async {
        self.dataset = dataset
        await controller.applyDataset(dataset)
        await controller.setDisplayConfiguration(.volume(method: method))
        refreshState()
    }

    public func setRenderMethod(_ method: VolumetricRenderMethod) async {
        self.method = method
        await controller.setDisplayConfiguration(.volume(method: method))
        refreshState()
    }

    public func setPreset(_ preset: VolumeRenderingBuiltinPreset) async {
        await controller.setPreset(preset)
        refreshState()
    }

    public func setTransferFunction(_ transferFunction: TransferFunction?) async throws {
        try await controller.setTransferFunction(transferFunction)
        refreshState()
    }

    public func applyTransferFunction(_ transferFunction: TransferFunction) async throws {
        if let intent = transferFunction.renderingIntent {
            await setRenderMethod(VolumetricRenderMethod(renderMode: intent.mode))
            if let lightingEnabled = intent.lightingEnabled {
                await controller.setLighting(enabled: lightingEnabled)
            }
            if let projectionsUseTransferFunction = intent.projectionsUseTransferFunction {
                await controller.setProjectionsUseTransferFunction(projectionsUseTransferFunction)
            }
        }
        try await setTransferFunction(transferFunction)
    }

    public func applyClinicalTransferFunctionPreset(_ preset: ClinicalTransferFunctionPreset) async throws {
        try await applyTransferFunction(preset.loadTransferFunction())
    }

    public func setWindowLevel(window: Double, level: Double) async {
        let mapping = Self.windowMapping(window: window,
                                         level: level,
                                         dataset: dataset,
                                         transferDomain: controller.transferFunctionDomain)
        await controller.setHuWindow(mapping)
        refreshState()
    }

    public func setVolumeClipping(_ clipping: VolumeClippingState) async throws {
        self.clipping = clipping
        try await controller.setVolumeClipping(clipping)
        refreshState()
    }

    public func setSurfaceMeshLayers(_ layers: [SurfaceMeshLayer]) async {
        surfaceMeshLayers = layers
        await controller.setSurfaceMeshLayers(layers)
        refreshState()
    }

    public func setVolumeLayers(_ layers: [MTKCore.VolumeLayer]) async {
        volumeLayers = layers
        await controller.setVolumeLayers(layers)
        refreshState()
    }

    public func setVolumeLayerVisibility(id: String, isVisible: Bool) async {
        if let index = volumeLayers.firstIndex(where: { $0.id == id }) {
            volumeLayers[index].isVisible = isVisible
        }
        await controller.setVolumeLayerVisibility(id: id, isVisible: isVisible)
        refreshState()
    }

    public func setVolumeLayerOpacity(id: String, opacity: Float) async {
        if let index = volumeLayers.firstIndex(where: { $0.id == id }) {
            volumeLayers[index].opacity = opacity
        }
        await controller.setVolumeLayerOpacity(id: id, opacity: opacity)
        refreshState()
    }

    public func setVolumeLayerBlendMode(id: String, blendMode: MTKCore.VolumeLayerBlendMode) async {
        if let index = volumeLayers.firstIndex(where: { $0.id == id }) {
            volumeLayers[index].blendMode = blendMode
        }
        await controller.setVolumeLayerBlendMode(id: id, blendMode: blendMode)
        refreshState()
    }

    public func setSurfaceMeshLayerVisibility(id: String, isVisible: Bool) async {
        if let index = surfaceMeshLayers.firstIndex(where: { $0.id == id }) {
            surfaceMeshLayers[index].isVisible = isVisible
        }
        await controller.setSurfaceMeshLayerVisibility(id: id, isVisible: isVisible)
        refreshState()
    }

    public func setSurfaceMeshLayerOpacity(id: String, opacity: Float) async {
        if let index = surfaceMeshLayers.firstIndex(where: { $0.id == id }) {
            surfaceMeshLayers[index].opacity = opacity
        }
        await controller.setSurfaceMeshLayerOpacity(id: id, opacity: opacity)
        refreshState()
    }

    public func clearVolumeClipping() async throws {
        try await setVolumeClipping(.disabled)
    }

    public func resetCamera() async {
        await controller.resetCamera()
        refreshState()
    }

    public func rotateCamera(screenDelta: SIMD2<Float>) async {
        await controller.rotateCamera(screenDelta: screenDelta)
        refreshState()
    }

    public func panCamera(screenDelta: SIMD2<Float>) async {
        await controller.panCamera(screenDelta: screenDelta)
        refreshState()
    }

    public func dollyCamera(delta: Float) async {
        await controller.dollyCamera(delta: delta)
        refreshState()
    }

    public func tiltCamera(roll: Float, pitch: Float) async {
        await controller.tiltCamera(roll: roll, pitch: pitch)
        refreshState()
    }

    public func renderSnapshotFrame() async throws -> VolumeRenderFrame {
        try await controller.renderVolumeSnapshotFrame()
    }

    private func refreshState() {
        state = Self.makeState(id: id,
                               method: method,
                               controller: controller,
                               dataset: dataset,
                               clipping: clipping)
    }

    private static func makeState(id: ViewportID,
                                  method: VolumetricRenderMethod,
                                  controller: VolumeViewportController,
                                  dataset: VolumeDataset?,
                                  clipping: VolumeClippingState = .disabled) -> MedicalViewportState {
        MedicalViewportState(
            viewportID: id,
            viewportType: .volume3D,
            renderMode: .volume3D(method: method),
            dataset: dataset.map(MedicalViewportDatasetSummary.init(dataset:)),
            camera: controller.cameraState,
            windowLevel: controller.windowLevelState,
            slice: nil,
            clipping: clipping,
            presentation: MedicalViewportPresentationState(surface: controller.viewportSurface)
        )
    }
}

/// Public clinical 2x2 viewport session used by the reference grid and demo app.
@MainActor
public final class ClinicalViewportSession: ObservableObject {
    let controller: ClinicalViewportGridController
    private var cancellables = Set<AnyCancellable>()

    public var axialViewportID: ViewportID { controller.axialViewportID }
    public var coronalViewportID: ViewportID { controller.coronalViewportID }
    public var sagittalViewportID: ViewportID { controller.sagittalViewportID }
    public var volumeViewportID: ViewportID { controller.volumeViewportID }
    public var axialSurface: MetalViewportSurface { controller.axialSurface }
    public var coronalSurface: MetalViewportSurface { controller.coronalSurface }
    public var sagittalSurface: MetalViewportSurface { controller.sagittalSurface }
    public var volumeSurface: MetalViewportSurface { controller.volumeSurface }
    public var datasetApplied: Bool { controller.datasetApplied }
    public var volumeViewportMode: ClinicalVolumeViewportMode { controller.volumeViewportMode }
    public var volumeClipping: VolumeClippingState { controller.volumeClipping }
    public var volumeLayers: [MTKCore.VolumeLayer] { controller.volumeLayers }
    public var surfaceMeshLayers: [SurfaceMeshLayer] { controller.surfaceMeshLayers }
    public var latestTimingSnapshot: ClinicalViewportTimingSnapshot { controller.latestTimingSnapshot }
    public var lastRenderError: (any Error)? { controller.lastRenderErrors.values.first ?? controller.lastRenderError }

    public init(controller: ClinicalViewportGridController) {
        self.controller = controller
        controller.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    public static func make(device: (any MTLDevice)? = nil,
                            initialViewportSize: CGSize = CGSize(width: 512, height: 512),
                            dataset: VolumeDataset? = nil,
                            transferFunction: TransferFunction? = nil) async throws -> ClinicalViewportSession {
        let controller = try await ClinicalViewportGridController.make(device: device,
                                                                       initialViewportSize: initialViewportSize,
                                                                       dataset: dataset,
                                                                       transferFunction: transferFunction)
        return ClinicalViewportSession(controller: controller)
    }

    public func applyDataset(_ dataset: VolumeDataset) async throws {
        try await controller.applyDataset(dataset)
    }

    public func setTransferFunction(_ transferFunction: TransferFunction?) async throws {
        try await controller.setTransferFunction(transferFunction)
    }

    public func applyTransferFunction(_ transferFunction: TransferFunction) async throws {
        if let mode = transferFunction.renderingIntent?.mode {
            try await setVolumeViewportMode(ClinicalVolumeViewportMode(renderMode: mode))
        }
        try await setTransferFunction(transferFunction)
    }

    public func applyClinicalTransferFunctionPreset(_ preset: ClinicalTransferFunctionPreset) async throws {
        try await applyTransferFunction(preset.loadTransferFunction())
    }

    public func setVolumeLayers(_ layers: [MTKCore.VolumeLayer]) async {
        await controller.setVolumeLayers(layers)
    }

    public func setSurfaceMeshLayers(_ layers: [SurfaceMeshLayer]) async {
        await controller.setSurfaceMeshLayers(layers)
    }

    public func setVolumeLayerVisibility(id: String, isVisible: Bool) async {
        await controller.setVolumeLayerVisibility(id: id, isVisible: isVisible)
    }

    public func setVolumeLayerOpacity(id: String, opacity: Float) async {
        await controller.setVolumeLayerOpacity(id: id, opacity: opacity)
    }

    public func setVolumeLayerBlendMode(id: String, blendMode: MTKCore.VolumeLayerBlendMode) async {
        await controller.setVolumeLayerBlendMode(id: id, blendMode: blendMode)
    }

    public func setSurfaceMeshLayerVisibility(id: String, isVisible: Bool) async {
        await controller.setSurfaceMeshLayerVisibility(id: id, isVisible: isVisible)
    }

    public func setSurfaceMeshLayerOpacity(id: String, opacity: Float) async {
        await controller.setSurfaceMeshLayerOpacity(id: id, opacity: opacity)
    }

    public func setVolumeViewportMode(_ mode: ClinicalVolumeViewportMode) async throws {
        try await controller.setVolumeViewportMode(mode)
    }

    public func setVolumeClipping(_ clipping: VolumeClippingState) async throws {
        try await controller.setVolumeClipping(clipping)
    }

    public func clearVolumeClipping() async throws {
        try await controller.clearVolumeClipping()
    }

    public func setMPRWindowLevel(window: Double, level: Double) async {
        await controller.setMPRWindowLevel(window: window, level: level)
    }

    public func scrollSlice(axis: MTKCore.Axis, deltaNormalized: Float) async {
        await controller.scrollSlice(axis: axis, deltaNormalized: deltaNormalized)
    }

    public func setCrosshair(in axis: MTKCore.Axis, normalizedPoint: CGPoint) async {
        await controller.setCrosshair(in: axis, normalizedPoint: normalizedPoint)
    }

    public func pick(in viewport: ViewportID,
                     screenPoint: CGPoint) throws -> VolumePickResult {
        try controller.pick(in: viewport, screenPoint: screenPoint)
    }

    public func pick(in axis: MTKCore.Axis,
                     screenPoint: CGPoint) throws -> VolumePickResult {
        try controller.pick(in: axis, screenPoint: screenPoint)
    }

    public func pickVolume(screenPoint: CGPoint) throws -> VolumePickResult {
        try controller.pickVolume(screenPoint: screenPoint)
    }

    public func renderVolumeSnapshotFrame() async throws -> VolumeRenderFrame {
        try await controller.renderVolumeSnapshotFrame()
    }

    public func resourceMetrics() async -> GPUResourceMetrics {
        await controller.engine.resourceMetrics()
    }

    public func debugSnapshot(for viewport: ViewportID) -> ClinicalViewportDebugSnapshot {
        controller.debugSnapshot(for: viewport)
    }

    public func shutdown() async {
        await controller.shutdown()
    }
}

private extension MedicalViewportPresentationState {
    @MainActor
    init(surface: MetalViewportSurface) {
        self.init(isMetalBacked: true,
                  drawablePixelSize: surface.drawablePixelSize,
                  lastErrorDescription: surface.lastPresentationError?.localizedDescription)
    }
}

private extension MedicalViewportType {
    var routedViewportType: ViewportType {
        switch self {
        case .stack(let axis), .volume(let axis):
            return .mpr(axis: axis)
        case .projection(let mode):
            return .projection(mode: mode)
        case .volume3D:
            return .volume3D
        }
    }
}

private extension MTKCore.Axis {
    var controllerAxis: VolumeViewportController.Axis {
        switch self {
        case .axial:
            return .z
        case .coronal:
            return .y
        case .sagittal:
            return .x
        }
    }
}

private extension ProjectionMode {
    var volumetricMethod: VolumetricRenderMethod {
        switch self {
        case .mip:
            return .mip
        case .minip:
            return .minip
        case .aip:
            return .avg
        }
    }
}

private extension MedicalViewport {
    static func sliceCount(for axis: MTKCore.Axis, in dataset: VolumeDataset) -> Int {
        switch axis {
        case .axial:
            return max(dataset.dimensions.depth, 0)
        case .coronal:
            return max(dataset.dimensions.height, 0)
        case .sagittal:
            return max(dataset.dimensions.width, 0)
        }
    }

    static func sliceIndex(axis: MTKCore.Axis,
                           normalized: Float,
                           dataset: VolumeDataset?) -> Int {
        guard let dataset else { return 0 }
        let count = sliceCount(for: axis, in: dataset)
        guard count > 1 else { return 0 }
        let clamped = VolumetricMath.clampFloat(normalized, lower: 0, upper: 1)
        return Int(round(clamped * Float(count - 1)))
    }

    static func clamp(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    static func windowMapping(window: Double,
                              level: Double,
                              dataset: VolumeDataset?,
                              transferDomain: ClosedRange<Float>?) -> VolumetricHUWindowMapping {
        let safeWindow = window.isFinite ? max(window, 1) : 1
        let safeLevel = level.isFinite ? level : 0
        let lower = clampedInt32((safeLevel - safeWindow / 2).rounded())
        let upper = clampedInt32((safeLevel + safeWindow / 2).rounded())
        let minHU = min(lower, upper)
        let maxHU = max(lower, upper)
        let datasetRange = dataset?.intensityRange ?? minHU...maxHU
        return VolumetricHUWindowMapping.makeHuWindowMapping(minHU: minHU,
                                                             maxHU: maxHU,
                                                             datasetRange: datasetRange,
                                                             transferDomain: transferDomain)
    }

    static func clampedInt32(_ value: Double) -> Int32 {
        guard value.isFinite else {
            return value.sign == .minus ? Int32.min : Int32.max
        }
        let lower = Double(Int32.min)
        let upper = Double(Int32.max)
        return Int32(min(max(value, lower), upper))
    }
}
