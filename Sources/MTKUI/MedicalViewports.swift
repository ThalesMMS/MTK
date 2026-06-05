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
    public let progressiveVolumeState: ProgressiveVolumeStreamState
    public let camera: VolumetricCameraState
    public let windowLevel: VolumetricWindowLevelState
    public let slice: MedicalViewportSliceState?
    public let clipping: VolumeClippingState
    public let presentation: MedicalViewportPresentationState

    public init(viewportID: ViewportID,
                viewportType: MedicalViewportType,
                renderMode: MedicalViewportRenderMode,
                dataset: MedicalViewportDatasetSummary? = nil,
                progressiveVolumeState: ProgressiveVolumeStreamState = .idle,
                camera: VolumetricCameraState = VolumetricCameraState(),
                windowLevel: VolumetricWindowLevelState = VolumetricWindowLevelState(),
                slice: MedicalViewportSliceState? = nil,
                clipping: VolumeClippingState = .disabled,
                presentation: MedicalViewportPresentationState) {
        self.viewportID = viewportID
        self.viewportType = viewportType
        self.renderMode = renderMode
        self.dataset = dataset
        self.progressiveVolumeState = progressiveVolumeState
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
    var progressiveVolumeState: ProgressiveVolumeStreamState { get }

    func applyDataset(_ dataset: VolumeDataset) async
    func recordProgressiveVolumeUpdate(_ update: ProgressiveVolumeDatasetUpdate) async
    func recordProgressiveVolumeStreamCancellation() async
    func beginProgressivePreviewInteraction() async
    func endProgressivePreviewInteraction() async
    func forceProgressiveFinalRenderQuality() async
    func setWindowLevel(window: Double, level: Double) async
    func resetCamera() async
}

public extension MedicalViewport {
    var progressiveVolumeState: ProgressiveVolumeStreamState {
        state.progressiveVolumeState
    }

    func recordProgressiveVolumeUpdate(_ update: ProgressiveVolumeDatasetUpdate) async {
        _ = update
    }

    func recordProgressiveVolumeStreamCancellation() async {}
    func beginProgressivePreviewInteraction() async {}
    func endProgressivePreviewInteraction() async {}
    func forceProgressiveFinalRenderQuality() async {}
}

/// Volume-backed stack viewport for predictable slice scrolling.
public struct StackViewportWindowPresentation: Equatable, Sendable {
    public var isInverted: Bool
    public var clut: Clinical2DCLUT

    public init(isInverted: Bool = false,
                clut: Clinical2DCLUT = .grayscale) {
        self.isInverted = isInverted
        self.clut = clut
    }

    public var effectiveInversion: Bool {
        isInverted != clut.invertsBaseLuminance
    }
}

@MainActor
public final class StackViewport: ObservableObject, MedicalViewport {
    public let id: ViewportID
    public let axis: MTKCore.Axis
    public let metalSurface: MetalViewportSurface
    @Published public private(set) var state: MedicalViewportState
    @Published public private(set) var sliceIndex: Int
    @Published public private(set) var sliceCount: Int = 0
    @Published public private(set) var windowPresentation = StackViewportWindowPresentation()
    @Published public private(set) var viewportTransform = Viewer2DTransform.identity
    @Published public private(set) var volumeLayers: [MTKCore.VolumeLayer] = []

    public var surface: any ViewportPresenting { metalSurface }
    public var viewportType: MedicalViewportType { .stack(axis: axis) }
    public var renderMode: MedicalViewportRenderMode { .stack }
    public var progressiveVolumeState: ProgressiveVolumeStreamState { controller.progressiveVolumeState }

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
        await configureController()
        await controller.applyDataset(dataset)
        await configureController()
        refreshState()
    }

    public func applyVolumeUpload<S: AsyncSequence>(
        referenceDataset dataset: VolumeDataset,
        uploadDescriptor: VolumeUploadDescriptor,
        slices: S,
        progress: VolumeUploadProgressHandler? = nil
    ) async throws where S.Element == VolumeUploadSlice {
        self.dataset = dataset
        sliceCount = Self.sliceCount(for: axis, in: dataset)
        sliceIndex = Self.clamp(sliceIndex, count: sliceCount)
        await configureController()
        try await controller.applyVolumeUpload(referenceDataset: dataset,
                                               uploadDescriptor: uploadDescriptor,
                                               slices: slices,
                                               progress: progress)
        await configureController()
        refreshState()
    }

    public func recordProgressiveVolumeUpdate(_ update: ProgressiveVolumeDatasetUpdate) async {
        await controller.recordProgressiveVolumeUpdate(update)
        refreshState()
    }

    public func recordProgressiveVolumeStreamCancellation() async {
        await controller.recordProgressiveVolumeStreamCancellation()
        refreshState()
    }

    public func beginProgressivePreviewInteraction() async {
        await controller.beginAdaptiveSamplingInteraction()
        refreshState()
    }

    public func endProgressivePreviewInteraction() async {
        await controller.endAdaptiveSamplingInteraction()
        refreshState()
    }

    public func forceProgressiveFinalRenderQuality() async {
        await controller.forceFinalRenderQuality()
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

    public func setWindowPresentation(isInverted: Bool,
                                      clut: Clinical2DCLUT) {
        windowPresentation = StackViewportWindowPresentation(isInverted: isInverted,
                                                            clut: clut)
        controller.setMPRPresentation(invert: windowPresentation.effectiveInversion)
        refreshState()
    }

    public func setViewportTransform(_ transform: Viewer2DTransform) {
        let sanitized = Self.sanitizedViewportTransform(transform)
        viewportTransform = sanitized
        var presentationTransform = MPRViewportTransform(
            zoom: Float(sanitized.zoom),
            pan: SIMD2<Float>(Float(sanitized.pan.x), Float(sanitized.pan.y))
        )
        presentationTransform.rotationRadians = Float(sanitized.rotationRadians)
        controller.setMPRViewportTransform(
            presentationTransform,
            flipHorizontal: sanitized.isFlippedHorizontally,
            flipVertical: sanitized.isFlippedVertically
        )
        refreshState()
    }

    public func resetCamera() async {
        await controller.resetCamera()
        refreshState()
    }

    public func beginAdaptiveSamplingInteraction() async {
        await controller.beginAdaptiveSamplingInteraction()
        refreshState()
    }

    public func endAdaptiveSamplingInteraction() async {
        await controller.endAdaptiveSamplingInteraction()
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

    /// Renders the active 2D stack slice into an export-ready BGRA texture.
    ///
    /// The returned frame reflects the current window/level, inversion, CLUT,
    /// slice axis/index, zoom, pan, rotation, flips, and supported volume-layer
    /// overlays.
    public func renderSnapshotFrame() async throws -> VolumeRenderFrame {
        guard dataset != nil else {
            throw VolumeViewportController.Error.datasetNotLoaded
        }
        await configureController()
        let snapshot = try await controller.renderMPRSnapshotTexture()
        return VolumeRenderFrame(
            texture: snapshot.texture,
            metadata: VolumeRenderFrame.Metadata(
                viewportSize: CGSize(width: snapshot.texture.width,
                                     height: snapshot.texture.height),
                viewportID: id,
                samplingDistance: 1,
                compositing: .frontToBack,
                quality: .production,
                pixelFormat: snapshot.texture.pixelFormat,
                renderTime: snapshot.renderTime
            )
        )
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
            progressiveVolumeState: controller.progressiveVolumeState,
            camera: controller.cameraState,
            windowLevel: controller.windowLevelState,
            slice: slice,
            presentation: MedicalViewportPresentationState(surface: controller.viewportSurface)
        )
    }

    private static func sanitizedViewportTransform(_ transform: Viewer2DTransform) -> Viewer2DTransform {
        let zoom = transform.zoom.isFinite ? max(transform.zoom, 0.01) : 1
        let panX = transform.pan.x.isFinite ? transform.pan.x : 0
        let panY = transform.pan.y.isFinite ? transform.pan.y : 0
        let rotation = transform.rotationRadians.isFinite ? transform.rotationRadians : 0
        return Viewer2DTransform(
            zoom: zoom,
            pan: SIMD2<Double>(panX, panY),
            rotationRadians: rotation,
            isFlippedHorizontally: transform.isFlippedHorizontally,
            isFlippedVertically: transform.isFlippedVertically
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
    public var progressiveVolumeState: ProgressiveVolumeStreamState { controller.progressiveVolumeState }

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
        await configureController()
        await controller.applyDataset(dataset)
        await configureController()
        refreshState()
    }

    public func recordProgressiveVolumeUpdate(_ update: ProgressiveVolumeDatasetUpdate) async {
        await controller.recordProgressiveVolumeUpdate(update)
        refreshState()
    }

    public func recordProgressiveVolumeStreamCancellation() async {
        await controller.recordProgressiveVolumeStreamCancellation()
        refreshState()
    }

    public func beginProgressivePreviewInteraction() async {
        await controller.beginAdaptiveSamplingInteraction()
        refreshState()
    }

    public func endProgressivePreviewInteraction() async {
        await controller.endAdaptiveSamplingInteraction()
        refreshState()
    }

    public func forceProgressiveFinalRenderQuality() async {
        await controller.forceFinalRenderQuality()
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
            progressiveVolumeState: controller.progressiveVolumeState,
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
    @Published public private(set) var volumeRenderQualitySettings: VolumeRenderQualitySettings

    public var surface: any ViewportPresenting { metalSurface }
    public var viewportType: MedicalViewportType { .volume3D }
    public var renderMode: MedicalViewportRenderMode { .volume3D(method: method) }
    public var adaptiveSamplingEnabled: Bool { controller.adaptiveSamplingEnabled }
    public var progressiveVolumeState: ProgressiveVolumeStreamState { controller.progressiveVolumeState }
    public var quantitativeScalarLegends: [QuantitativeScalarLayerLegend] {
        volumeLayers.compactMap(\.quantitativeLegend)
    }

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
        self.volumeRenderQualitySettings = controller.volumeRenderQualitySettings
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

    public func applyVolumeUpload<S: AsyncSequence>(
        referenceDataset dataset: VolumeDataset,
        uploadDescriptor: VolumeUploadDescriptor,
        slices: S,
        progress: VolumeUploadProgressHandler? = nil
    ) async throws where S.Element == VolumeUploadSlice {
        self.dataset = dataset
        try await controller.applyVolumeUpload(referenceDataset: dataset,
                                               uploadDescriptor: uploadDescriptor,
                                               slices: slices,
                                               progress: progress)
        await controller.setDisplayConfiguration(.volume(method: method))
        refreshState()
    }

    public func recordProgressiveVolumeUpdate(_ update: ProgressiveVolumeDatasetUpdate) async {
        await controller.recordProgressiveVolumeUpdate(update)
        refreshState()
    }

    public func recordProgressiveVolumeStreamCancellation() async {
        await controller.recordProgressiveVolumeStreamCancellation()
        refreshState()
    }

    public func beginProgressivePreviewInteraction() async {
        await controller.beginAdaptiveSamplingInteraction()
        refreshState()
    }

    public func endProgressivePreviewInteraction() async {
        await controller.endAdaptiveSamplingInteraction()
        refreshState()
    }

    public func forceProgressiveFinalRenderQuality() async {
        await controller.forceFinalRenderQuality()
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

    public func adjustTransferFunctionShift(screenDelta: SIMD2<Float>) async {
        await controller.adjustTransferFunctionShift(screenDelta: screenDelta)
        refreshState()
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

    public func setPrimaryVolumeDatasetOverride(_ dataset: VolumeDataset?) async {
        await controller.setPrimaryVolumeDatasetOverride(dataset)
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

    public func resetCameraRotation() async {
        await controller.resetCameraRotation()
        refreshState()
    }

    public func setCameraOrientation(_ orientation: Volume3DAnatomicalOrientation) async {
        await controller.setCameraOrientation(orientation)
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

    public func zoomCamera(scale: Float) async {
        await controller.zoomCamera(scale: scale)
        refreshState()
    }

    public func tiltCamera(roll: Float, pitch: Float) async {
        await controller.tiltCamera(roll: roll, pitch: pitch)
        refreshState()
    }

    public func beginAdaptiveSamplingInteraction() async {
        await controller.beginAdaptiveSamplingInteraction()
        refreshState()
    }

    func beginNativeCameraInteraction() {
        controller.beginAdaptiveSamplingInteractionSynchronously()
        refreshState()
    }

    public func endAdaptiveSamplingInteraction() async {
        await controller.endAdaptiveSamplingInteraction()
        refreshState()
    }

    func endNativeCameraInteraction() {
        controller.endAdaptiveSamplingInteractionSynchronously()
        refreshState()
    }

    public func forceFinalRenderQuality() async {
        await controller.forceFinalRenderQuality()
        refreshState()
    }

    public func setAdaptiveSampling(_ enabled: Bool) async {
        await controller.setAdaptiveSampling(enabled)
        refreshState()
    }

    public func setSamplingStep(_ step: Float) async {
        await controller.setSamplingStep(step)
        refreshState()
    }

    public func setVolumeRenderQualitySettings(_ settings: VolumeRenderQualitySettings) async {
        await controller.setVolumeRenderQualitySettings(settings)
        volumeRenderQualitySettings = controller.volumeRenderQualitySettings
        refreshState()
    }

    public func renderSnapshotFrame() async throws -> VolumeRenderFrame {
        try await controller.renderVolumeSnapshotFrame()
    }

    @discardableResult
    func applyNativeOrbitDelta(_ delta: CGSize) -> Bool {
        let changed = controller.rotateCameraInteractively(
            screenDelta: SIMD2<Float>(Float(delta.width), Float(delta.height))
        )
        if changed { refreshState() }
        return changed
    }

    @discardableResult
    func applyNativePanDelta(_ delta: CGSize) -> Bool {
        let changed = controller.panCameraInteractively(
            screenDelta: SIMD2<Float>(Float(delta.width), Float(delta.height))
        )
        if changed { refreshState() }
        return changed
    }

    @discardableResult
    func applyNativeZoomScale(_ scale: Float) -> Bool {
        let changed = controller.zoomCameraInteractively(scale: scale)
        if changed { refreshState() }
        return changed
    }

    @discardableResult
    func applyNativeRollRadians(_ radians: Float) -> Bool {
        let changed = controller.tiltCameraInteractively(roll: radians, pitch: 0)
        if changed { refreshState() }
        return changed
    }

    func flushNativeCameraInteractionRender() {
        controller.scheduleInteractiveCameraRender()
        refreshState()
    }

    func nativeCameraInteractionDiagnostics() -> String {
        controller.nativeCameraInteractionDiagnostics()
    }

    public func pickVolume(screenPoint: CGPoint,
                           dataset pickDataset: VolumeDataset? = nil) throws -> VolumePickResult {
        try controller.pickVolume(screenPoint: screenPoint,
                                  dataset: pickDataset)
    }

    @_spi(Testing)
    public var debugSamplingStep: Float {
        controller.debugSamplingStep
    }

    private func refreshState() {
        volumeRenderQualitySettings = controller.volumeRenderQualitySettings
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
            progressiveVolumeState: controller.progressiveVolumeState,
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
    public var allViewportIDs: [ViewportID] { controller.allViewportIDs }
    public var mprViewportIDs: [ViewportID] { controller.mprViewportIDs }
    public var axialSurface: MetalViewportSurface { controller.axialSurface }
    public var coronalSurface: MetalViewportSurface { controller.coronalSurface }
    public var sagittalSurface: MetalViewportSurface { controller.sagittalSurface }
    public var volumeSurface: MetalViewportSurface { controller.volumeSurface }
    public var datasetApplied: Bool { controller.datasetApplied }
    public var volumeViewportMode: ClinicalVolumeViewportMode { controller.volumeViewportMode }
    public var volumeClipping: VolumeClippingState { controller.volumeClipping }
    public var activeMPRAxis: MTKCore.Axis { controller.activeMPRAxis }
    public var mprInteractionTool: ClinicalMPRInteractionTool { controller.mprInteractionTool }
    public var normalizedPositions: [MTKCore.Axis: Float] { controller.normalizedPositions }
    public var mprViewportTransforms: [MTKCore.Axis: MPRViewportTransform] { controller.mprViewportTransforms }
    public var windowLevel: WindowLevelShift { controller.windowLevel }
    public var mprWindowPreset: MPRWindowPreset { controller.mprWindowPreset }
    public var mprCLUTPreset: Volume3DCLUTPreset { controller.mprCLUTPreset }
    public var isMPRWindowInverted: Bool { controller.isMPRWindowInverted }
    public var canExportActiveMPRSnapshot: Bool { controller.canExportMPRSnapshot(axis: activeMPRAxis) }
    public var mprROIKind: ViewerROIKind { controller.mprROIKind }
    public var mprROIAnnotations: [ViewerROIAnnotation] { controller.mprROIAnnotations }
    public var mprSlabBlendMode: MPRSlabBlendOption { controller.mprSlabBlendMode }
    public var slabThickness: Double { controller.slabThickness }
    public var volumeLayers: [MTKCore.VolumeLayer] { controller.volumeLayers }
    public var surfaceMeshLayers: [SurfaceMeshLayer] { controller.surfaceMeshLayers }
    public var quantitativeScalarLegends: [QuantitativeScalarLayerLegend] {
        controller.volumeLayers.compactMap(\.quantitativeLegend)
    }
    public var rtDoseOverlays: [RTDoseVolumeOverlay] { controller.rtDoseOverlays }
    public var rtStructureContourOverlays: [RTStructureContourOverlay] { controller.rtStructureContourOverlays }
    public var rtStructureContourConfiguration: RTStructureContourOverlayConfiguration { controller.rtStructureContourConfiguration }
    public var mprPresentationStates: [MTKCore.Axis: MPRPresentationState] { controller.mprPresentationStates }
    public var structuredReportViewerState: StructuredReportViewerState? { controller.structuredReportViewerState }
    public var metadataOverlaySettingsByViewport: [ViewportID: ClinicalViewportMetadataOverlaySettings] {
        controller.metadataOverlaySettingsByViewport
    }
    public var latestTimingSnapshot: ClinicalViewportTimingSnapshot { controller.latestTimingSnapshot }
    public var lastRenderError: (any Error)? { controller.lastRenderErrors.values.first ?? controller.lastRenderError }
    public var adaptiveSamplingEnabled: Bool { controller.adaptiveSamplingEnabled }
    public var volumeRenderQualitySettings: VolumeRenderQualitySettings { controller.volumeRenderQualitySettings }
    public var activeTransferFunction: TransferFunction? { controller.lastTransferFunction }
    public var crosshairAngles: [MTKCore.Axis: Double] { controller.crosshairAngles }
    public var hangingProtocolResolvedLayout: HangingProtocolResolvedLayout? { controller.hangingProtocolResolvedLayout }
    public var hangingProtocolSlotAssignments: [HangingProtocolResolvedViewport] { controller.hangingProtocolSlotAssignments }
    public var renderQualityState: RenderQualityState { controller.renderQualityState }
    public var viewportStates: [MedicalViewportState] {
        MTKCore.Axis.allCases.map { state(for: $0) } + [volumeViewportState]
    }

    public var volumeViewportState: MedicalViewportState {
        let viewportType: MedicalViewportType
        let renderMode: MedicalViewportRenderMode
        switch volumeViewportMode {
        case .dvr:
            viewportType = .volume3D
            renderMode = .volume3D(method: .dvr)
        case .mip:
            viewportType = .projection(mode: .mip)
            renderMode = .projection(mode: .mip)
        case .minip:
            viewportType = .projection(mode: .minip)
            renderMode = .projection(mode: .minip)
        case .aip:
            viewportType = .projection(mode: .aip)
            renderMode = .projection(mode: .aip)
        }

        return MedicalViewportState(
            viewportID: volumeViewportID,
            viewportType: viewportType,
            renderMode: renderMode,
            dataset: controller.currentDataset.map(MedicalViewportDatasetSummary.init(dataset:)),
            camera: VolumetricCameraState(position: controller.volumeCameraTarget + controller.volumeCameraOffset,
                                          target: controller.volumeCameraTarget,
                                          up: controller.volumeCameraUp),
            windowLevel: windowLevelState,
            clipping: volumeClipping,
            presentation: MedicalViewportPresentationState(surface: volumeSurface)
        )
    }

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

    public func viewportID(for axis: MTKCore.Axis) -> ViewportID {
        controller.viewportID(for: axis)
    }

    public func axis(for viewport: ViewportID) -> MTKCore.Axis? {
        controller.viewportAxesByID[viewport]
    }

    public func surface(for axis: MTKCore.Axis) -> MetalViewportSurface {
        controller.surface(for: axis)
    }

    public func drawableSize(for axis: MTKCore.Axis) -> CGSize {
        controller.drawableSize(for: axis)
    }

    public func displayTransform(for axis: MTKCore.Axis) -> MPRDisplayTransform {
        controller.displayTransform(for: axis)
    }

    public func displayTransform(for viewport: ViewportID) -> MPRDisplayTransform? {
        axis(for: viewport).map { controller.displayTransform(for: $0) }
    }

    public func state(for axis: MTKCore.Axis) -> MedicalViewportState {
        let dataset = controller.currentDataset
        let count = dataset.map { Self.sliceCount(for: axis, in: $0) } ?? 0
        let normalized = VolumetricMath.clampFloat(normalizedPositions[axis] ?? 0.5,
                                                   lower: 0,
                                                   upper: 1)
        let slice = MedicalViewportSliceState(axis: axis,
                                              index: Self.sliceIndex(axis: axis,
                                                                     normalized: normalized,
                                                                     dataset: dataset),
                                              count: count,
                                              normalizedPosition: normalized)
        return MedicalViewportState(
            viewportID: viewportID(for: axis),
            viewportType: .volume(axis: axis),
            renderMode: .mpr(blend: mprSlabBlendMode.volumetricBlendMode),
            dataset: dataset.map(MedicalViewportDatasetSummary.init(dataset:)),
            windowLevel: windowLevelState,
            slice: slice,
            presentation: MedicalViewportPresentationState(surface: surface(for: axis))
        )
    }

    public func state(for viewport: ViewportID) -> MedicalViewportState? {
        if viewport == volumeViewportID {
            return volumeViewportState
        }
        guard let axis = axis(for: viewport) else { return nil }
        return state(for: axis)
    }

    public func applyDataset(_ dataset: VolumeDataset) async throws {
        try await controller.applyDataset(dataset)
    }

    public func applyVolumeUpload<S: AsyncSequence>(
        referenceDataset dataset: VolumeDataset,
        uploadDescriptor: VolumeUploadDescriptor,
        slices: S,
        progress: VolumeUploadProgressHandler? = nil
    ) async throws where S.Element == VolumeUploadSlice {
        try await controller.applyVolumeUpload(referenceDataset: dataset,
                                               uploadDescriptor: uploadDescriptor,
                                               slices: slices,
                                               progress: progress)
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

    public func setRTDoseOverlays(_ overlays: [RTDoseVolumeOverlay]) async {
        await controller.setRTDoseOverlays(overlays)
    }

    public func setRTDoseOverlayOpacity(id: String, opacity: Float) async {
        await controller.setRTDoseOverlayOpacity(id: id, opacity: opacity)
    }

    public func setRTDoseColorLookupTable(id: String,
                                          colorLookupTable: RTDoseColorLookupTable) async {
        await controller.setRTDoseColorLookupTable(id: id,
                                                   colorLookupTable: colorLookupTable)
    }

    public func pickRTDose(in viewport: ViewportID,
                           screenPoint: CGPoint) throws -> [RTDoseSample] {
        try controller.pickRTDose(in: viewport, screenPoint: screenPoint)
    }

    public func doseStatistics(overlayID: String,
                               roiLayerID: String,
                               label: UInt16? = nil) throws -> RTDoseStatistics {
        try controller.doseStatistics(overlayID: overlayID,
                                      roiLayerID: roiLayerID,
                                      label: label)
    }

    public func quantitativeScalarStatistics(layerID: String,
                                             roiLayerID: String,
                                             label: UInt16? = nil) throws -> QuantitativeScalarStatistics {
        try controller.quantitativeScalarStatistics(layerID: layerID,
                                                    roiLayerID: roiLayerID,
                                                    label: label)
    }

    public func labelmapVolumeSummary(layerID: String,
                                      label: UInt16? = nil) throws -> ViewerROILabelmapVolumeSummary {
        try controller.labelmapVolumeSummary(layerID: layerID, label: label)
    }

    public func setRTStructureContourOverlays(_ overlays: [RTStructureContourOverlay]) {
        controller.setRTStructureContourOverlays(overlays)
    }

    public func setRTStructureContourConfiguration(_ configuration: RTStructureContourOverlayConfiguration) {
        controller.setRTStructureContourConfiguration(configuration)
    }

    public func setRTStructureContourSliceTolerance(_ tolerance: Double) {
        controller.setRTStructureContourSliceTolerance(tolerance)
    }

    public func applyMPRPresentationState(_ presentationState: MPRPresentationState,
                                          to axis: MTKCore.Axis) async {
        await controller.applyMPRPresentationState(presentationState, to: axis)
    }

    public func clearMPRPresentationState(for axis: MTKCore.Axis) {
        controller.clearMPRPresentationState(for: axis)
    }

    public func applyStructuredReportViewerState(_ state: StructuredReportViewerState?) {
        controller.applyStructuredReportViewerState(state)
    }

    public func selectStructuredReportFinding(id: CADFindingOverlayItem.ID?) {
        controller.selectStructuredReportFinding(id: id)
    }

    public func setMetadataOverlaySettings(_ settings: ClinicalViewportMetadataOverlaySettings,
                                           for viewport: ViewportID) {
        controller.setMetadataOverlaySettings(settings, for: viewport)
    }

    public func setMetadataOverlaySettings(_ settings: ClinicalViewportMetadataOverlaySettings,
                                           for axis: MTKCore.Axis) {
        controller.setMetadataOverlaySettings(settings, for: axis)
    }

    public func metadataOverlaySettings(for viewport: ViewportID) -> ClinicalViewportMetadataOverlaySettings {
        controller.metadataOverlaySettings(for: viewport)
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

    public func applyMPRWindowPreset(_ preset: MPRWindowPreset) async {
        await controller.applyMPRWindowPreset(preset)
    }

    public func setMPRCLUTPreset(_ preset: Volume3DCLUTPreset) {
        controller.setMPRCLUTPreset(preset)
    }

    public func setMPRWindowInverted(_ inverted: Bool) {
        controller.setMPRWindowInverted(inverted)
    }

    public func setMPRSlabThickness(_ thickness: Double) async {
        await controller.setMPRSlabThickness(thickness)
    }

    public func setMPRSlabBlendMode(_ blendMode: MPRSlabBlendOption) async {
        await controller.setMPRSlabBlendMode(blendMode)
    }

    public func setActiveMPRAxis(_ axis: MTKCore.Axis) {
        controller.setActiveMPRAxis(axis)
    }

    public func setMPRInteractionTool(_ tool: ClinicalMPRInteractionTool) {
        controller.setMPRInteractionTool(tool)
    }

    public func setMPRROIKind(_ kind: ViewerROIKind, activateTool: Bool = true) {
        controller.setMPRROIKind(kind, activateTool: activateTool)
    }

    public func deleteMPRROIsInActiveView() {
        controller.deleteMPRROIsInActiveView()
    }

    public func deleteAllMPRROIs() {
        controller.deleteAllMPRROIs()
    }

    public func scrollSlice(axis: MTKCore.Axis, deltaNormalized: Float) async {
        await controller.scrollSlice(axis: axis, deltaNormalized: deltaNormalized)
    }

    public func setMPRSlicePosition(axis: MTKCore.Axis, normalizedPosition: Float) async {
        await controller.setMPRSlicePosition(axis: axis, normalizedPosition: normalizedPosition)
    }

    public func setCrosshair(in axis: MTKCore.Axis, normalizedPoint: CGPoint) async {
        await controller.setCrosshair(in: axis, normalizedPoint: normalizedPoint)
    }

    public func panMPR(axis: MTKCore.Axis, deltaNormalized: SIMD2<Float>) {
        controller.panMPR(axis: axis, deltaNormalized: deltaNormalized)
    }

    public func zoomMPR(axis: MTKCore.Axis, factor: Float, anchor: SIMD2<Float> = SIMD2<Float>(repeating: 0.5)) {
        controller.zoomMPR(axis: axis, factor: factor, anchor: anchor)
    }

    public func resetMPRView(axis: MTKCore.Axis) {
        controller.resetMPRView(axis: axis)
    }

    public func resetAllMPRViews() {
        controller.resetAllMPRViews()
    }

    @discardableResult
    public func applyHangingProtocol(_ definition: HangingProtocolDefinition,
                                     context: HangingProtocolContext? = nil) async -> HangingProtocolResolvedLayout? {
        await controller.applyHangingProtocol(definition, context: context)
    }

    public func clearHangingProtocol() {
        controller.clearHangingProtocol()
    }

    public func setAdaptiveSampling(_ enabled: Bool) async {
        await controller.setAdaptiveSampling(enabled)
    }

    public func setVolumeRenderQualitySettings(_ settings: VolumeRenderQualitySettings) async {
        await controller.setVolumeRenderQualitySettings(settings)
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

    public func renderActiveMPRSnapshotFrame() async throws -> VolumeRenderFrame {
        try await controller.renderMPRSnapshotFrame(axis: activeMPRAxis)
    }

    public func renderMPRSnapshotFrame(axis: MTKCore.Axis) async throws -> VolumeRenderFrame {
        try await controller.renderMPRSnapshotFrame(axis: axis)
    }

    public func resourceMetrics() async -> GPUResourceMetrics {
        await controller.engine.resourceMetrics()
    }

    public func debugSnapshot(for viewport: ViewportID) -> ClinicalViewportDebugSnapshot {
        controller.debugSnapshot(for: viewport)
    }

    public func debugSlabConfiguration(for axis: MTKCore.Axis) async -> (thickness: Int, steps: Int, blend: MPRBlendMode)? {
        await debugSlabConfiguration(for: viewportID(for: axis))
    }

    public func debugSlabConfiguration(for viewport: ViewportID) async -> (thickness: Int, steps: Int, blend: MPRBlendMode)? {
        await controller.engine.debugSlabConfiguration(for: viewport)
    }

    public func shutdown() async {
        await controller.shutdown()
    }

    private var windowLevelState: VolumetricWindowLevelState {
        VolumetricWindowLevelState(window: windowLevel.window, level: windowLevel.level)
    }

    private static func sliceCount(for axis: MTKCore.Axis, in dataset: VolumeDataset) -> Int {
        switch axis {
        case .axial:
            return max(dataset.dimensions.depth, 0)
        case .coronal:
            return max(dataset.dimensions.height, 0)
        case .sagittal:
            return max(dataset.dimensions.width, 0)
        }
    }

    private static func sliceIndex(axis: MTKCore.Axis,
                                   normalized: Float,
                                   dataset: VolumeDataset?) -> Int {
        guard let dataset else { return 0 }
        let count = sliceCount(for: axis, in: dataset)
        guard count > 1 else { return 0 }
        let clamped = VolumetricMath.clampFloat(normalized, lower: 0, upper: 1)
        return Int(round(clamped * Float(count - 1)))
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
