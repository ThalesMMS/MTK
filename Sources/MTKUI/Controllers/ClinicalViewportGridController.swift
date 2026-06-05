//
//  ClinicalViewportGridController.swift
//  MTKUI
//
//  Metal-native clinical viewport grid controller.
//

import Combine
import CoreGraphics
import Foundation
@preconcurrency import Metal
import MTKCore
import simd

/// Metal-native controller for the fixed 2x2 clinical viewport grid.
///
/// The controller is isolated to `@MainActor` because it owns SwiftUI-observed state and
/// `MetalViewportSurface` presentation objects. Call public methods from the main actor; methods
/// that cross into `MTKRenderingEngine` perform GPU work through that engine actor.
@MainActor
public final class ClinicalViewportGridController: ObservableObject {
    package let engine: MTKRenderingEngine
    public let axialViewportID: ViewportID
    public let coronalViewportID: ViewportID
    public let sagittalViewportID: ViewportID
    public let volumeViewportID: ViewportID

    public let axialSurface: MetalViewportSurface
    public let coronalSurface: MetalViewportSurface
    public let sagittalSurface: MetalViewportSurface
    public let volumeSurface: MetalViewportSurface

    private let device: any MTLDevice

    @Published public internal(set) var windowLevel = WindowLevelShift(window: 400, level: 40)
    @Published public internal(set) var slabThickness: Double = 3
    @Published public internal(set) var activeMPRAxis: MTKCore.Axis = .axial
    @Published public internal(set) var mprInteractionTool: ClinicalMPRInteractionTool = .crosshair
    @Published public internal(set) var mprSlabBlendMode: MPRSlabBlendOption = .mean
    @Published public internal(set) var mprWindowPreset: MPRWindowPreset = .default
    @Published public internal(set) var mprCLUTPreset: Volume3DCLUTPreset = .defaultPreset
    @Published public internal(set) var isMPRWindowInverted = false
    @Published public internal(set) var mprROIKind: ViewerROIKind = .distance
    @Published public internal(set) var mprROIAnnotations: [ViewerROIAnnotation] = []
    @Published public internal(set) var mprPresentationStates: [MTKCore.Axis: MPRPresentationState] = [:]
    @Published public internal(set) var structuredReportViewerState: StructuredReportViewerState?
    @Published public internal(set) var hangingProtocolDefinition: HangingProtocolDefinition?
    @Published public internal(set) var hangingProtocolContext: HangingProtocolContext?
    @Published public internal(set) var hangingProtocolResolvedLayout: HangingProtocolResolvedLayout?
    @Published public internal(set) var hangingProtocolSlotAssignments: [HangingProtocolResolvedViewport] = []
    @Published public internal(set) var normalizedPositions: [MTKCore.Axis: Float] = ClinicalViewportGridController.centeredNormalizedPositions
    @Published public internal(set) var crosshairOffsets: [MTKCore.Axis: CGPoint] = ClinicalViewportGridController.centeredCrosshairOffsets
    @Published public internal(set) var mprCursorVoxel = SIMD3<Float>(repeating: 0)
    @Published public internal(set) var mprCursorWorldPoint: SIMD3<Float>?
    @Published public internal(set) var mprViewportTransforms: [MTKCore.Axis: MPRViewportTransform] = ClinicalViewportGridController.defaultMPRViewportTransforms
    @Published public internal(set) var sharedResourceHandle: VolumeResourceHandle?
    @Published public internal(set) var volumeLayers: [MTKCore.VolumeLayer] = []
    @Published public internal(set) var surfaceMeshLayers: [SurfaceMeshLayer] = []
    @Published public internal(set) var rtDoseOverlays: [RTDoseVolumeOverlay] = []
    @Published public internal(set) var rtStructureContourOverlays: [RTStructureContourOverlay] = []
    @Published public internal(set) var rtStructureContourConfiguration = RTStructureContourOverlayConfiguration.default
    @Published public internal(set) var metadataOverlaySettingsByViewport: [ViewportID: ClinicalViewportMetadataOverlaySettings] = [:]
    @Published public internal(set) var datasetApplied = false
    @Published public internal(set) var renderQualityState: RenderQualityState = .settled
    @Published public internal(set) var lastRenderErrors: [ViewportID: any Error] = [:]
    @Published public internal(set) var lastRenderError: (any Error)?
    @Published public internal(set) var volumeViewportMode: ClinicalVolumeViewportMode = .dvr
    @Published public internal(set) var volumeClipping: VolumeClippingState = .disabled
    @Published public internal(set) var latestTimingSnapshot = ClinicalViewportTimingSnapshot()
    @Published public internal(set) var debugSnapshots: [ViewportID: ClinicalViewportDebugSnapshot] = [:]
    @Published public internal(set) var adaptiveSamplingEnabled: Bool = true
    @Published public internal(set) var volumeRenderQualitySettings: VolumeRenderQualitySettings = .default
    @Published public internal(set) var crosshairAngles: [MTKCore.Axis: Double] = [
        .axial: 0.0,
        .coronal: 0.0,
        .sagittal: 0.0
    ]
    public var baseSamplingStep: Float = 768.0

    var renderTasks: [ViewportID: Task<Void, Never>] = [:]
    var renderPendingViewports = Set<ViewportID>()
    var renderInFlightViewports = Set<ViewportID>()
    var renderGenerations: [ViewportID: UInt64] = [:]
    var presentationInFlightTokens: [ViewportID: UInt64] = [:]
    var presentationFailureCounts: [ViewportID: UInt64] = [:]
    var viewportTimings: [ViewportID: FrameMetadata] = [:]
    let qualityScheduler = RenderQualityScheduler()
    let renderGraph = ViewportRenderGraph()
    let logger = Logger(category: "ClinicalViewportGridController")
    var qualityStateCancellable: AnyCancellable?
    var committedMPRWindowRange: ClosedRange<Int32>?
    var volumeCameraTarget = SIMD3<Float>(repeating: 0.5)
    var volumeCameraOffset = SIMD3<Float>(0, 0, 2)
    var volumeCameraUp = SIMD3<Float>(0, 1, 0)
    var volumeCameraYaw: Float = 0
    var volumeCameraPitch: Float = 0
    var volumeOrbitState = Volume3DOrbitState()
    var volumeCameraInteractionGeneration: UInt64 = 0
    var volumeCameraFlushTask: Task<Void, Never>?
    var volumeCameraFlushPending = false
    var currentDataset: VolumeDataset?
    var lastTransferFunction: TransferFunction?
    var currentVolumeTransferFunction: VolumeTransferFunction?
    var mprColormapTexture: (any MTLTexture)?
    var mprROIStore = ViewerROIStore()
    var rtDoseVolumeLayerIDs = Set<String>()
    var mprPlaneRotationsByAxis: [MTKCore.Axis: simd_quatf] = [:]
    var displayTransformsByAxis: [MTKCore.Axis: MPRDisplayTransform] = [:]
    var viewportAxesByID: [ViewportID: MTKCore.Axis] = [:]
#if DEBUG
    var debugWindowConfigurationFailureViewports = Set<ViewportID>()
#endif

    static let centeredNormalizedPositions: [MTKCore.Axis: Float] = [
        .axial: 0.5,
        .coronal: 0.5,
        .sagittal: 0.5
    ]

    static let centeredCrosshairOffsets: [MTKCore.Axis: CGPoint] = [
        .axial: .zero,
        .coronal: .zero,
        .sagittal: .zero
    ]

    static let defaultMPRViewportTransforms: [MTKCore.Axis: MPRViewportTransform] = [
        .axial: .identity,
        .coronal: .identity,
        .sagittal: .identity
    ]

    /// Creates four engine-backed viewports and one `MetalViewportSurface` per pane.
    ///
    /// - Note: This initializer is `@MainActor` isolated. Create the controller from UI code or
    ///   hop to the main actor before storing it in observable application state.
    public init(device: (any MTLDevice)? = nil,
                initialViewportSize: CGSize = CGSize(width: 512, height: 512)) async throws {
        guard let resolvedDevice = device ?? MTLCreateSystemDefaultDevice() else {
            throw ClinicalViewportGridControllerError.metalUnavailable
        }

        let engine = try await MTKRenderingEngine(device: resolvedDevice)
        self.device = resolvedDevice
        self.engine = engine

        var createdViewportIDs: [ViewportID] = []
        let axialViewportID: ViewportID
        let coronalViewportID: ViewportID
        let sagittalViewportID: ViewportID
        let volumeViewportID: ViewportID
        let axialSurface: MetalViewportSurface
        let coronalSurface: MetalViewportSurface
        let sagittalSurface: MetalViewportSurface
        let volumeSurface: MetalViewportSurface
        do {
            axialViewportID = try await engine.createViewport(
                ViewportDescriptor(type: .mpr(axis: .axial),
                                   initialSize: initialViewportSize,
                                   label: "Axial MPR")
            )
            createdViewportIDs.append(axialViewportID)
            coronalViewportID = try await engine.createViewport(
                ViewportDescriptor(type: .mpr(axis: .coronal),
                                   initialSize: initialViewportSize,
                                   label: "Coronal MPR")
            )
            createdViewportIDs.append(coronalViewportID)
            sagittalViewportID = try await engine.createViewport(
                ViewportDescriptor(type: .mpr(axis: .sagittal),
                                   initialSize: initialViewportSize,
                                   label: "Sagittal MPR")
            )
            createdViewportIDs.append(sagittalViewportID)
            volumeViewportID = try await engine.createViewport(
                ViewportDescriptor(type: .volume3D,
                                   initialSize: initialViewportSize,
                                   label: "Volume 3D")
            )
            createdViewportIDs.append(volumeViewportID)

            axialSurface = try MetalViewportSurface(device: resolvedDevice)
            coronalSurface = try MetalViewportSurface(device: resolvedDevice)
            sagittalSurface = try MetalViewportSurface(device: resolvedDevice)
            volumeSurface = try MetalViewportSurface(device: resolvedDevice)
        } catch {
            for viewportID in createdViewportIDs {
                await engine.destroyViewport(viewportID)
            }
            throw error
        }

        self.axialViewportID = axialViewportID
        self.coronalViewportID = coronalViewportID
        self.sagittalViewportID = sagittalViewportID
        self.volumeViewportID = volumeViewportID
        self.axialSurface = axialSurface
        self.coronalSurface = coronalSurface
        self.sagittalSurface = sagittalSurface
        self.volumeSurface = volumeSurface
        self.viewportAxesByID = [
            self.axialViewportID: .axial,
            self.coronalViewportID: .coronal,
            self.sagittalViewportID: .sagittal
        ]
        self.debugSnapshots = [
            self.axialViewportID: Self.makeDebugSnapshot(viewportID: self.axialViewportID,
                                                         viewportName: "Axial",
                                                         viewportType: "mpr(axial)",
                                                         renderMode: "single"),
            self.coronalViewportID: Self.makeDebugSnapshot(viewportID: self.coronalViewportID,
                                                           viewportName: "Coronal",
                                                           viewportType: "mpr(coronal)",
                                                           renderMode: "single"),
            self.sagittalViewportID: Self.makeDebugSnapshot(viewportID: self.sagittalViewportID,
                                                            viewportName: "Sagittal",
                                                            viewportType: "mpr(sagittal)",
                                                            renderMode: "single"),
            self.volumeViewportID: Self.makeDebugSnapshot(viewportID: self.volumeViewportID,
                                                          viewportName: "Volume",
                                                          viewportType: "volume3D",
                                                          renderMode: String(describing: self.volumeViewportMode))
        ]

        await engine.setProfilingOptions(
            ProfilingOptions(measureUploadTime: true,
                             measureRenderTime: true,
                             measurePresentTime: true)
        )
        qualityScheduler.applyVolumeRenderQualitySettings(volumeRenderQualitySettings)
        baseSamplingStep = qualityScheduler.baseSamplingStep

        configureSurfaceCallbacks()
        qualityStateCancellable = qualityScheduler.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                if state == .settled {
                    Task { @MainActor in
                        guard self.qualityScheduler.state == .settled else { return }
                        await self.applyRenderQualityAndSchedule()
                        guard self.qualityScheduler.state == .settled else { return }
                        self.renderQualityState = .settled
                    }
                } else {
                    self.renderQualityState = state
                }
            }
    }

    deinit {
        renderTasks.values.forEach { $0.cancel() }
    }

    /// Cancels scheduled renders and destroys all engine viewports owned by this controller.
    ///
    /// Call this before releasing a controller that owns loaded data so `VolumeResourceHandle`
    /// references are released promptly. The method is idempotent; repeated calls only cancel any
    /// Performs an orderly, idempotent shutdown of the controller's GPU and task resources.
    /// 
    /// Cancels any pending render tasks, destroys all engine viewports, and clears dataset-related state and cached transforms and error tracking. After this call the controller no longer holds a shared volume resource or an applied dataset.
    public func shutdown() async {
        let runningRenderTasks = Array(renderTasks.values)
        runningRenderTasks.forEach { $0.cancel() }
        for task in runningRenderTasks {
            await task.value
        }
        volumeCameraFlushTask?.cancel()
        await volumeCameraFlushTask?.value
        volumeCameraFlushTask = nil
        volumeCameraFlushPending = false
        renderTasks.removeAll()
        renderPendingViewports.removeAll()
        renderInFlightViewports.removeAll()
        renderGenerations.removeAll()
        presentationInFlightTokens.removeAll()
        presentationFailureCounts.removeAll()
        for viewport in allViewportIDs {
            await engine.destroyViewport(viewport)
        }
        sharedResourceHandle = nil
        currentDataset = nil
        currentVolumeTransferFunction = nil
        displayTransformsByAxis.removeAll()
        activeMPRAxis = .axial
        mprInteractionTool = .crosshair
        mprSlabBlendMode = .mean
        resetMPRROIAnnotations()
        normalizedPositions = Self.centeredNormalizedPositions
        crosshairOffsets = Self.centeredCrosshairOffsets
        mprCursorVoxel = SIMD3<Float>(repeating: 0)
        mprCursorWorldPoint = nil
        crosshairAngles = [.axial: 0, .coronal: 0, .sagittal: 0]
        mprPlaneRotationsByAxis.removeAll()
        mprViewportTransforms = Self.defaultMPRViewportTransforms
        hangingProtocolDefinition = nil
        hangingProtocolContext = nil
        hangingProtocolResolvedLayout = nil
        hangingProtocolSlotAssignments = []
        datasetApplied = false
        lastRenderErrors.removeAll()
        lastRenderError = nil
    }

    public var allViewportIDs: [ViewportID] {
        [axialViewportID, coronalViewportID, sagittalViewportID, volumeViewportID]
    }

    public var mprViewportIDs: [ViewportID] {
        [axialViewportID, coronalViewportID, sagittalViewportID]
    }

    /// Map an MPR axis to its corresponding viewport identifier.
    /// - Parameter axis: The MPR axis (.axial, .coronal, or .sagittal) to look up.
    /// - Returns: The `ViewportID` associated with the provided axis.
    public func viewportID(for axis: MTKCore.Axis) -> ViewportID {
        switch axis {
        case .axial:
            return axialViewportID
        case .coronal:
            return coronalViewportID
        case .sagittal:
            return sagittalViewportID
        }
    }

    /// Selects the MetalViewportSurface associated with the given MPR axis.
    /// - Parameter axis: The MPR axis whose surface to retrieve.
    /// - Returns: The corresponding `MetalViewportSurface` for the specified axis.
    public func surface(for axis: MTKCore.Axis) -> MetalViewportSurface {
        switch axis {
        case .axial:
            return axialSurface
        case .coronal:
            return coronalSurface
        case .sagittal:
            return sagittalSurface
        }
    }

    public func setActiveMPRAxis(_ axis: MTKCore.Axis) {
        if activeMPRAxis != axis {
            logClinicalInteractionInfo("[MTKMPRInteraction] activeAxis.set \(activeMPRAxis)->\(axis)")
        }
        activeMPRAxis = axis
    }

    public func setMPRInteractionTool(_ tool: ClinicalMPRInteractionTool) {
        logClinicalInteractionInfo("[MTKMPRInteraction] tool.set \(mprInteractionTool)->\(tool)")
        mprInteractionTool = tool
    }

    public func viewportTransform(for axis: MTKCore.Axis) -> MPRViewportTransform {
        mprViewportTransforms[axis] ?? .identity
    }

    public func setMPRViewportTransform(_ transform: MPRViewportTransform,
                                        for axis: MTKCore.Axis) {
        guard viewportTransform(for: axis) != transform else { return }
        mprViewportTransforms[axis] = transform
        _ = setCrosshairOffset(crosshairOffset(for: axis), for: axis)
        scheduleRender(for: viewportID(for: axis))
    }

    public func panMPR(axis: MTKCore.Axis,
                       deltaNormalized: SIMD2<Float>) {
        guard deltaNormalized.x.isFinite, deltaNormalized.y.isFinite else {
            logClinicalInteractionInfo("[MTKMPRInteraction] pan.drop axis=\(axis) delta=\(deltaNormalized)")
            return
        }
        let before = viewportTransform(for: axis)
        setActiveMPRAxis(axis)
        setMPRViewportTransform(viewportTransform(for: axis).translated(by: deltaNormalized),
                                for: axis)
        logClinicalInteractionInfo("[MTKMPRInteraction] pan axis=\(axis) delta=\(deltaNormalized) before=\(before) after=\(viewportTransform(for: axis))")
    }

    public func zoomMPR(axis: MTKCore.Axis,
                        factor: Float,
                        anchor: SIMD2<Float> = SIMD2<Float>(repeating: 0.5)) {
        guard factor.isFinite, factor > 0 else {
            logClinicalInteractionInfo("[MTKMPRInteraction] zoom.drop axis=\(axis) factor=\(factor)")
            return
        }
        let before = viewportTransform(for: axis)
        setActiveMPRAxis(axis)
        setMPRViewportTransform(viewportTransform(for: axis).zoomed(by: factor, around: anchor),
                                for: axis)
        logClinicalInteractionInfo("[MTKMPRInteraction] zoom axis=\(axis) factor=\(factor) anchor=\(anchor) before=\(before) after=\(viewportTransform(for: axis))")
    }

    public func resetMPRView(axis: MTKCore.Axis) {
        logClinicalInteractionInfo("[MTKMPRInteraction] reset axis=\(axis)")
        setActiveMPRAxis(axis)
        setMPRViewportTransform(.identity, for: axis)
    }

    public func resetAllMPRViews() {
        logClinicalInteractionInfo("[MTKMPRInteraction] resetAll")
        mprViewportTransforms = Self.defaultMPRViewportTransforms
        crosshairAngles = [.axial: 0, .coronal: 0, .sagittal: 0]
        mprPlaneRotationsByAxis.removeAll()
        displayTransformsByAxis.removeAll()
        rebuildAllCrosshairOffsets()
        guard datasetApplied else {
            scheduleMPRRenderAll()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.configureAllMPRSlices(window: self.windowLevel.range)
                self.rebuildAllCrosshairOffsets()
                self.scheduleMPRRenderAll()
            } catch {
                self.recordError(error, for: self.viewportID(for: self.activeMPRAxis))
            }
        }
    }

    public func setMPRSlicePosition(axis: MTKCore.Axis,
                                    normalizedPosition: Float) async {
        logClinicalInteractionInfo("[MTKMPRInteraction] sliceSlider axis=\(axis) position=\(normalizedPosition)")
        setActiveMPRAxis(axis)
        await setSlicePosition(axis: axis, normalizedPosition: normalizedPosition)
    }

    public func adjustMPRWindowLevel(screenDelta: CGSize) async {
        guard screenDelta.width.isFinite, screenDelta.height.isFinite else {
            logClinicalInteractionInfo("[MTKMPRInteraction] windowLevel.drop delta=\(screenDelta)")
            return
        }
        let nextWindow = max(windowLevel.window + Double(screenDelta.width) * 2, 1)
        let nextLevel = windowLevel.level - Double(screenDelta.height) * 2
        logClinicalInteractionInfo("[MTKMPRInteraction] windowLevel delta=\(screenDelta) before=(window:\(windowLevel.window),level:\(windowLevel.level)) after=(window:\(nextWindow),level:\(nextLevel))")
        await setMPRWindowLevel(window: nextWindow, level: nextLevel)
    }

    public func applyMPRWindowPreset(_ preset: MPRWindowPreset) async {
        if let quickPreset = preset.quickPreset {
            let windowPreset = quickPreset.windowLevelPreset
            await setMPRWindowLevel(window: windowPreset.window,
                                    level: windowPreset.level,
                                    selectedPreset: preset)
            return
        }

        switch preset {
        case .default:
            let range = currentDataset?.recommendedWindow ??
                currentDataset?.intensityRange ??
                WindowLevelShift(window: 400, level: 40).range
            await setMPRWindowLevel(range: range, selectedPreset: .default)
        case .other:
            mprWindowPreset = .other
        case .abdomen, .bone, .brain, .lungs:
            break
        }
    }

    public func setMPRCLUTPreset(_ preset: Volume3DCLUTPreset) {
        guard mprCLUTPreset != preset else { return }
        mprCLUTPreset = preset
        mprColormapTexture = makeMPRColormapTexture(for: preset)
        scheduleMPRRenderAll()
    }

    public func setMPRWindowInverted(_ inverted: Bool) {
        guard isMPRWindowInverted != inverted else { return }
        isMPRWindowInverted = inverted
        scheduleMPRRenderAll()
    }

    private func makeMPRColormapTexture(for preset: Volume3DCLUTPreset) -> (any MTLTexture)? {
        guard case .generatedPalette(let colors) = preset.source,
              !colors.isEmpty else {
            return nil
        }

        let width = 256
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
                                                                  width: width,
                                                                  height: 1,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "MPR.CLUT.\(preset.id)"

        let table = (0..<width).map { index -> SIMD4<Float> in
            let fraction = Float(index) / Float(width - 1)
            return Self.interpolatedColor(fraction: fraction, colors: colors)
        }
        table.withUnsafeBytes { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, width, 1),
                            mipmapLevel: 0,
                            withBytes: baseAddress,
                            bytesPerRow: MemoryLayout<SIMD4<Float>>.stride * width)
        }
        return texture
    }

    private static func interpolatedColor(fraction: Float,
                                          colors: [TransferFunction.RGBAColor]) -> SIMD4<Float> {
        guard let first = colors.first else { return SIMD4<Float>(1, 1, 1, 1) }
        guard colors.count > 1 else {
            return SIMD4<Float>(first.r, first.g, first.b, first.a)
        }

        let clampedFraction = min(max(fraction, 0), 1)
        let scaledIndex = clampedFraction * Float(colors.count - 1)
        let leftIndex = min(max(Int(floor(scaledIndex)), 0), colors.count - 1)
        let rightIndex = min(leftIndex + 1, colors.count - 1)
        let t = scaledIndex - Float(leftIndex)
        let left = colors[leftIndex]
        let right = colors[rightIndex]
        return SIMD4<Float>(
            left.r * (1 - t) + right.r * t,
            left.g * (1 - t) + right.g * t,
            left.b * (1 - t) + right.b * t,
            left.a * (1 - t) + right.a * t
        )
    }

    public func setAdaptiveSampling(_ enabled: Bool) async {
        guard adaptiveSamplingEnabled != enabled else { return }
        adaptiveSamplingEnabled = enabled
        if !enabled {
            qualityScheduler.forceSettled()
        }
        do {
            try await configureMPRSlabResolved()
            scheduleMPRRenderAll()
        } catch {
            logger.error("Failed to reconfigure after toggling adaptive sampling", error: error)
        }
    }

    public func setVolumeRenderQualitySettings(_ settings: VolumeRenderQualitySettings) async {
        let sanitized = settings.sanitized
        volumeRenderQualitySettings = sanitized
        qualityScheduler.applyVolumeRenderQualitySettings(sanitized)
        baseSamplingStep = qualityScheduler.baseSamplingStep
        guard datasetApplied else { return }
        do {
            try await configureVolumeRenderQuality()
        } catch {
            recordError(error, for: volumeViewportID)
        }
    }

    public func setCrosshairAngle(_ angle: Double, for axis: MTKCore.Axis) {
        let previous = crosshairAngles[axis] ?? 0
        let normalized = Self.normalizedAngleDegrees(angle)
        let delta = Self.shortestAngleDeltaDegrees(from: previous, to: normalized)
        crosshairAngles[axis] = normalized
        let affectedAxes = mprAxesAffectedByRotation(around: axis)
        applyMPRRotation(deltaDegrees: delta, around: axis, affecting: affectedAxes)
        displayTransformsByAxis.removeAll()
        Task { @MainActor [weak self] in
            guard let self, self.datasetApplied else { return }
            var configuredViewports = [ViewportID]()
            for affectedAxis in affectedAxes {
                let viewport = self.viewportID(for: affectedAxis)
                do {
                    try await self.configureSlice(axis: affectedAxis, window: self.windowLevel.range)
                    configuredViewports.append(viewport)
                } catch {
                    self.recordError(error, for: viewport)
                }
            }
            self.rebuildAllCrosshairOffsets()
            for viewport in configuredViewports {
                self.scheduleRender(for: viewport)
            }
        }
    }

    /// Convenience factory for the common "create controller, then apply dataset" path.
    ///
    /// - Parameters:
    ///   - device: Optional Metal device. When omitted, the system default device is used.
    ///   - initialViewportSize: Initial size used when creating engine viewports.
    ///   - dataset: Optional dataset to upload to all four viewports.
    ///   - transferFunction: Optional transfer function for the 3D volume pane only.
    /// Creates and initializes a configured ClinicalViewportGridController with optional dataset and transfer function applied.
    /// - Parameters:
    ///   - device: An optional Metal device to use; if `nil`, the system default device is used.
    ///   - initialViewportSize: The initial logical size used when creating each viewport.
    ///   - dataset: An optional volume dataset to upload and apply to all viewports after initialization.
    ///   - transferFunction: An optional transfer function to configure the volume viewport after initialization.
    /// - Returns: A fully-initialized ClinicalViewportGridController configured with the provided dataset and transfer function (if any).
    /// - Throws: Errors encountered while creating the controller, uploading/applying the dataset, or configuring the transfer function (for example, Metal/unavailability or engine configuration failures).
    public static func make(device: (any MTLDevice)? = nil,
                            initialViewportSize: CGSize = CGSize(width: 512, height: 512),
                            dataset: VolumeDataset? = nil,
                            transferFunction: TransferFunction? = nil) async throws -> ClinicalViewportGridController {
        let controller = try await ClinicalViewportGridController(device: device,
                                                                  initialViewportSize: initialViewportSize)
        if let dataset {
            try await controller.applyDataset(dataset)
        }
        if let transferFunction {
            try await controller.setTransferFunction(transferFunction)
        }
        return controller
    }

    /// Uploads one dataset to the MPR grid and retained on-demand volume viewport using the engine's shared resource handle.
    ///
    /// All MPR viewports and the on-demand volume viewport receive the same `VolumeResourceHandle`.
    /// Applies a volume dataset, initializes window/level, slab, slice/crosshair and camera state, configures MPR rendering, updates per-viewport debug snapshots to "ready", and schedules initial MPR renders.
    /// 
    /// This uploads the dataset to the rendering engine (creating a shared resource handle), resets cached display transforms and timing, sets sensible defaults (window/level, centered slice positions, slab thickness, and volume camera), clears prior render errors, configures all MPR slices, refreshes debug snapshots for every viewport, and enqueues renders for the displayed MPR panes.
    /// - Parameter dataset: The volume dataset to apply; becomes the controller's current dataset and is uploaded to the engine.
    /// - Throws: Any error returned by the engine or by the configuration steps (for example failures when setting the volume, configuring slices, slab, volume window, camera, or render quality).
    public func applyDataset(_ dataset: VolumeDataset) async throws {
        try await applyVolumeDataset(dataset) {
            try await engine.setVolume(dataset, for: allViewportIDs)
        }
    }

    public func applyVolumeUpload<S: AsyncSequence>(
        referenceDataset dataset: VolumeDataset,
        uploadDescriptor: VolumeUploadDescriptor,
        slices: S,
        progress: VolumeUploadProgressHandler? = nil
    ) async throws where S.Element == VolumeUploadSlice {
        try await applyVolumeDataset(dataset) {
            try await engine.setVolume(uploadDescriptor: uploadDescriptor,
                                       slices: slices,
                                       for: allViewportIDs,
                                       progress: progress)
        }
    }

    private func applyVolumeDataset(_ dataset: VolumeDataset,
                                    uploadVolume: () async throws -> VolumeResourceHandle?) async throws {
        if datasetApplied,
           let currentDataset,
           Self.referencesSameDatasetStorage(currentDataset, dataset) {
            return
        }
        let runningRenderTasks = Array(renderTasks.values)
        runningRenderTasks.forEach { $0.cancel() }
        for task in runningRenderTasks {
            await task.value
        }
        renderTasks.removeAll()
        renderPendingViewports.removeAll()
        renderInFlightViewports.removeAll()
        renderGenerations.removeAll()
        presentationInFlightTokens.removeAll()
        presentationFailureCounts.removeAll()
        datasetApplied = false

        var uploadedVolume = false
        do {
            let handle = try await uploadVolume()
            uploadedVolume = true
            sharedResourceHandle = handle
            currentDataset = dataset
            displayTransformsByAxis.removeAll()
            viewportTimings.removeAll()
            latestTimingSnapshot = ClinicalViewportTimingSnapshot()

            let initialWindow = dataset.recommendedWindow ?? dataset.intensityRange
            windowLevel = WindowLevelShift(range: initialWindow)
            mprWindowPreset = .default
            mprCLUTPreset = .defaultPreset
            isMPRWindowInverted = false
            mprColormapTexture = nil
            resetMPRROIAnnotations()
            activeMPRAxis = .axial
            mprInteractionTool = .crosshair
            mprSlabBlendMode = .mean
            mprViewportTransforms = Self.defaultMPRViewportTransforms
            normalizedPositions = Self.centeredNormalizedPositions
            crosshairAngles = [.axial: 0, .coronal: 0, .sagittal: 0]
            mprPlaneRotationsByAxis.removeAll()
            setMPRCursorVoxel(centerCursorVoxel(for: dataset), in: dataset)
            rebuildAllCrosshairOffsets()
            slabThickness = 3
            resetVolumeCamera()
            lastRenderErrors.removeAll()
            lastRenderError = nil

            try await configureAllMPRSlices(window: windowLevel.range)
            committedMPRWindowRange = windowLevel.range
            try await configureMPRSlab()
            datasetApplied = true

            let volumeTextureLabel = await engine.volumeTextureLabel(for: volumeViewportID)
            for viewport in allViewportIDs {
                updateDebugSnapshot(for: viewport) { snapshot in
                    snapshot.viewportType = viewportTypeName(for: viewport)
                    snapshot.renderMode = renderModeName(for: viewport)
                    snapshot.datasetHandle = datasetHandleLabel(for: viewport)
                    snapshot.volumeTextureLabel = volumeTextureLabel
                    snapshot.presentationStatus = "ready"
                    snapshot.lastError = nil
                }
            }
#if DEBUG
            await logResourceSharingDiagnostics()
#endif
            if let hangingProtocolDefinition {
                _ = await applyHangingProtocol(hangingProtocolDefinition,
                                               context: hangingProtocolContext)
            } else {
                scheduleMPRRenderAll()
            }
        } catch {
            if uploadedVolume {
                await engine.clearVolume(for: allViewportIDs)
            }
            sharedResourceHandle = nil
            currentDataset = nil
            currentVolumeTransferFunction = nil
            displayTransformsByAxis.removeAll()
            mprSlabBlendMode = .mean
            resetMPRROIAnnotations()
            viewportTimings.removeAll()
            latestTimingSnapshot = ClinicalViewportTimingSnapshot()
            committedMPRWindowRange = nil
            hangingProtocolResolvedLayout = nil
            hangingProtocolSlotAssignments = []
            datasetApplied = false
            lastRenderErrors.removeAll()
            lastRenderError = nil
            throw error
        }
    }

    private static func referencesSameDatasetStorage(_ lhs: VolumeDataset,
                                                     _ rhs: VolumeDataset) -> Bool {
        lhs.imageData == rhs.imageData &&
            lhs.data.count == rhs.data.count &&
            lhs.data.withUnsafeBytes { lhsBuffer in
                rhs.data.withUnsafeBytes { rhsBuffer in
                    lhsBuffer.baseAddress == rhsBuffer.baseAddress
                }
            }
    }

    /// Signals the start of an adaptive-sampling user interaction and applies the resulting render quality.
    /// 
    /// This tells the adaptive-quality scheduler that an interaction has begun, then updates render quality and schedules any necessary renders.
    public func beginAdaptiveSamplingInteraction() async {
        beginNativeVolumeCameraInteraction(scheduleRenderQualityUpdate: false)
        await applyRenderQualityAndSchedule()
    }

    func beginNativeVolumeCameraInteraction(scheduleRenderQualityUpdate: Bool = true) {
        logClinicalInteractionInfo("[MTKMPRInteraction] adaptive.begin before=\(qualityScheduler.state) \(nativeVolumeCameraInteractionDiagnostics())")
        qualityScheduler.beginInteraction()
        logClinicalInteractionInfo("[MTKMPRInteraction] adaptive.begin after=\(qualityScheduler.state) samplingStep=\(qualityScheduler.currentParameters.volumeSamplingStep) tier=\(qualityScheduler.currentParameters.qualityTier) \(nativeVolumeCameraInteractionDiagnostics())")
        guard scheduleRenderQualityUpdate else { return }
        Task { @MainActor [weak self] in
            await self?.applyRenderQualityAndSchedule()
        }
    }

    /// Marks the end of an adaptive-sampling interaction so the controller can allow render quality to transition back toward its settled/production state.
    public func endAdaptiveSamplingInteraction() async {
        endNativeVolumeCameraInteraction()
    }

    func endNativeVolumeCameraInteraction() {
        logClinicalInteractionInfo("[MTKMPRInteraction] adaptive.end before=\(qualityScheduler.state) \(nativeVolumeCameraInteractionDiagnostics())")
        qualityScheduler.endInteraction()
        logClinicalInteractionInfo("[MTKMPRInteraction] adaptive.end after=\(qualityScheduler.state) samplingStep=\(qualityScheduler.currentParameters.volumeSamplingStep) tier=\(qualityScheduler.currentParameters.qualityTier) \(nativeVolumeCameraInteractionDiagnostics())")
    }

    /// Forces the render-quality scheduler to transition to its settled (final) state, causing the controller to apply the final render-quality settings.
    public func forceFinalRenderQuality() async {
        logClinicalInteractionInfo("[MTKMPRInteraction] adaptive.forceFinal before=\(qualityScheduler.state)")
        qualityScheduler.forceSettled()
        logClinicalInteractionInfo("[MTKMPRInteraction] adaptive.forceFinal after=\(qualityScheduler.state) samplingStep=\(qualityScheduler.currentParameters.volumeSamplingStep) tier=\(qualityScheduler.currentParameters.qualityTier)")
    }

    /// Applies a transfer function to the retained on-demand volume viewport only.
    ///
    /// This intentionally does not update MPR window/level or MPR presentation state; the volume
    /// transfer function is consumed by explicit snapshot/export rendering.
    /// - Parameter transferFunction: The transfer function to apply to the volume rendering; pass `nil` to clear it.
    /// - Throws: Any error returned by the rendering engine while configuring the volume viewport.
    public func setTransferFunction(_ transferFunction: TransferFunction?) async throws {
        lastTransferFunction = transferFunction
        let converted = transferFunction.map(Self.volumeTransferFunction)
        try await engine.configure(volumeViewportID,
                                   transferFunction: converted)
        currentVolumeTransferFunction = converted
    }

    public func adjustTransferFunctionShift(screenDelta: CGSize) async {
        guard var tf = lastTransferFunction else { return }
        let range = tf.maximumValue - tf.minimumValue
        let scale: Float = range > 0 ? range / 500.0 : 1.0
        let deltaShift = Float(screenDelta.width) * scale
        tf.shift += deltaShift
        lastTransferFunction = tf
        try? await setTransferFunction(tf)
    }

    public func setVolumeLayers(_ layers: [MTKCore.VolumeLayer]) async {
        volumeLayers = layers
        await commitVolumeLayers()
    }

    public func setSurfaceMeshLayers(_ layers: [SurfaceMeshLayer]) async {
        surfaceMeshLayers = layers
        try? await engine.configure(volumeViewportID, surfaceMeshLayers: layers)
    }

    public func setVolumeClipping(_ clipping: VolumeClippingState) async throws {
        volumeClipping = clipping
        try await configureVolumeClipping()
        updateDebugSnapshot(for: volumeViewportID) { snapshot in
            snapshot.lastPassExecuted = "configureVolumeClipping"
            snapshot.presentationStatus = "ready"
            snapshot.lastError = nil
        }
    }

    public func clearVolumeClipping() async throws {
        try await setVolumeClipping(.disabled)
    }

    public func setVolumeLayerVisibility(id: String, isVisible: Bool) async {
        guard let index = volumeLayers.firstIndex(where: { $0.id == id }),
              volumeLayers[index].isVisible != isVisible else {
            return
        }
        volumeLayers[index].isVisible = isVisible
        await commitVolumeLayers()
    }

    public func setVolumeLayerOpacity(id: String, opacity: Float) async {
        guard let index = volumeLayers.firstIndex(where: { $0.id == id }),
              volumeLayers[index].opacity != opacity else {
            return
        }
        volumeLayers[index].opacity = opacity
        await commitVolumeLayers()
    }

    public func setVolumeLayerBlendMode(id: String, blendMode: MTKCore.VolumeLayerBlendMode) async {
        guard let index = volumeLayers.firstIndex(where: { $0.id == id }),
              volumeLayers[index].blendMode != blendMode else {
            return
        }
        volumeLayers[index].blendMode = blendMode
        await commitVolumeLayers()
    }

    func commitVolumeLayers() async {
        do {
            try await engine.configure(allViewportIDs, volumeLayers: volumeLayers)
            clearError(for: volumeViewportID)
            scheduleRendersForVolumeLayers()
        } catch {
            recordError(error, for: volumeViewportID)
        }
    }

    private func scheduleRendersForVolumeLayers() {
        scheduleMPRRenderAll()
    }

    public func setSurfaceMeshLayerVisibility(id: String, isVisible: Bool) async {
        guard let index = surfaceMeshLayers.firstIndex(where: { $0.id == id }),
              surfaceMeshLayers[index].isVisible != isVisible else {
            return
        }
        surfaceMeshLayers[index].isVisible = isVisible
        try? await engine.configure(volumeViewportID, surfaceMeshLayers: surfaceMeshLayers)
    }

    public func setSurfaceMeshLayerOpacity(id: String, opacity: Float) async {
        guard let index = surfaceMeshLayers.firstIndex(where: { $0.id == id }),
              surfaceMeshLayers[index].opacity != opacity else {
            return
        }
        surfaceMeshLayers[index].opacity = opacity
        try? await engine.configure(volumeViewportID, surfaceMeshLayers: surfaceMeshLayers)
    }

    /// Reconfigures the retained on-demand volume viewport to the given mode, validates the engine's resolved descriptor, and updates debug state.
    ///
    /// If the requested mode is already active this method returns immediately. On change, the engine viewport descriptor is updated and the engine's resolved viewport type is validated; the controller's `volumeViewportMode` and the corresponding debug snapshot are updated without scheduling hidden presentation work.
    /// - Throws: `RenderGraphError.invalidViewportConfiguration` if the engine's resolved viewport type does not match the requested mode's viewport type.
    public func setVolumeViewportMode(_ mode: ClinicalVolumeViewportMode) async throws {
        guard volumeViewportMode != mode else { return }
        logger.info("Updating volume viewport mode from=\(volumeViewportMode.rawValue) to=\(mode.rawValue)")
        try await engine.configure(volumeViewportID,
                                   type: mode.viewportType,
                                   label: mode.displayName)
        let resolvedType = try await engine.viewportType(for: volumeViewportID)
        guard resolvedType == mode.viewportType else {
            let error = RenderGraphError.invalidViewportConfiguration(
                volumeViewportID,
                reason: "Engine descriptor mismatch after mode change. Expected \(mode.viewportType.debugName), got \(resolvedType.debugName)."
            )
            recordError(error, for: volumeViewportID)
            throw error
        }
        volumeViewportMode = mode
        updateDebugSnapshot(for: volumeViewportID) { snapshot in
            snapshot.viewportType = mode.viewportType.debugName
            snapshot.renderMode = mode.rawValue
            snapshot.lastPassExecuted = "configureVolumeMode"
            snapshot.presentationStatus = "ready"
            snapshot.lastError = nil
        }
#if DEBUG
        await assertVolumeViewportConfigured()
#endif
    }

    /// Update the MPR window/level and commit the change if it differs from the current values.
    /// - Parameters:
    ///   - window: Desired window width; values less than 1 are clamped to 1 before applying.
    ///   - level: Desired window level (center).
    /// - Discussion: If the resolved window/level equals the controller's current `windowLevel`, no commit is performed.
    public func setMPRWindowLevel(window: Double, level: Double) async {
        await setMPRWindowLevel(window: window, level: level, selectedPreset: .other)
    }

    private func setMPRWindowLevel(window: Double,
                                   level: Double,
                                   selectedPreset: MPRWindowPreset?) async {
        guard window.isFinite, level.isFinite else { return }
        let resolvedWindow = max(window, 1)
        let lower = level - resolvedWindow / 2
        let upper = level + resolvedWindow / 2
        guard lower.isFinite, upper.isFinite else { return }

        let int32Min = Double(Int32.min)
        let int32Max = Double(Int32.max)
        let clampedLower = min(max(lower.rounded(), int32Min), int32Max)
        let clampedUpper = min(max(upper.rounded(), int32Min), int32Max)
        let resolvedRange = Int32(clampedLower)...Int32(clampedUpper)
        await setMPRWindowLevel(range: min(resolvedRange.lowerBound, resolvedRange.upperBound)...max(resolvedRange.lowerBound, resolvedRange.upperBound),
                                selectedPreset: selectedPreset)
    }

    private func setMPRWindowLevel(range: ClosedRange<Int32>,
                                   selectedPreset: MPRWindowPreset?) async {
        let resolved = WindowLevelShift(range: range)
        if let selectedPreset {
            mprWindowPreset = selectedPreset
        }
        guard resolved != windowLevel else { return }
        windowLevel = resolved
        await commitWindowLevel()
    }

    /// Commits the controller's current MPR window range to the displayed MPR viewports.
    ///
    /// If the current committed range already matches the controller's window range, this method does nothing. It configures each MPR axis with the new range; if any step fails, the method restores the previously committed range, records the corresponding error, and aborts without updating the committed range or scheduling renders. On success, the committed range is updated and all MPR viewports are scheduled for rendering.
    public func commitWindowLevel() async {
        let range = windowLevel.range
        guard committedMPRWindowRange != range else { return }
        let previousRange = committedMPRWindowRange
        var failures: [(ViewportID, any Error)] = []

        for axis in MTKCore.Axis.allCases {
            do {
                try await configureSlice(axis: axis, window: range)
            } catch {
                failures.append((viewportID(for: axis), error))
            }
        }

        guard failures.isEmpty else {
            let restoreFailures = await restoreCommittedWindowRange(previousRange)
            failures.append(contentsOf: restoreFailures)
            restoreWindowState(to: previousRange)
            for (viewport, error) in failures {
                recordError(error, for: viewport)
            }
            return
        }
        committedMPRWindowRange = range
        scheduleMPRRenderAll()
    }

    private func restoreCommittedWindowRange(_ range: ClosedRange<Int32>?) async -> [(ViewportID, any Error)] {
        var failures: [(ViewportID, any Error)] = []
        for axis in MTKCore.Axis.allCases {
            do {
                try await configureSlice(axis: axis, window: range)
            } catch {
                failures.append((viewportID(for: axis), error))
            }
        }
        return failures
    }

    private func restoreWindowState(to range: ClosedRange<Int32>?) {
        committedMPRWindowRange = range
        if let range {
            windowLevel = WindowLevelShift(range: range)
        }
    }

    /// Updates the MPR slab thickness (in slices) and applies the corresponding slab steps to all MPR viewports.
    /// 
    /// This method ignores non-finite input and no-ops if the resolved thickness matches the current value. It converts
    /// the requested thickness into a resolved ClinicalSlabConfiguration, updates the quality scheduler's base slab steps,
    /// computes effective slab steps from the scheduler's current parameters, and configures each MPR viewport with the
    /// resolved thickness and steps. Per-viewport configuration failures are recorded; rendering is scheduled only if all
    /// viewport configurations succeed.
    /// - Parameter thickness: Desired slab thickness in slices (floating-point value; will be converted to an integer configuration).
    public func setMPRSlabThickness(_ thickness: Double) async {
        guard thickness.isFinite else { return }
        let safeThickness = min(max(thickness, 0), Double(Int32.max))
        let resolved = ClinicalSlabConfiguration(thickness: Int(safeThickness.rounded(.towardZero)))
        let nextThickness = Double(resolved.thickness)
        guard nextThickness != slabThickness else { return }
        slabThickness = nextThickness
        do {
            try await configureMPRSlabResolved(configuration: resolved)
        } catch {
            for viewport in mprViewportIDs {
                recordError(error, for: viewport)
            }
            return
        }
        scheduleMPRRenderAll()
    }

    public func setMPRSlabBlendMode(_ blendMode: MPRSlabBlendOption) async {
        guard blendMode != mprSlabBlendMode else { return }
        mprSlabBlendMode = blendMode
        do {
            try await configureMPRSlabResolved()
        } catch {
            for viewport in mprViewportIDs {
                recordError(error, for: viewport)
            }
            return
        }
        scheduleMPRRenderAll()
    }

    /// Rotates the volume camera by applying incremental yaw and pitch derived from a screen-space delta.
    ///
    /// Updates the controller's `volumeCameraOffset` and `volumeCameraUp` vectors and reconfigures the retained volume camera for future explicit snapshots. If `screenDelta` components are not finite or the computed rotation is effectively zero, no changes are made. Pitch is clamped to avoid camera inversion at the poles. Any error during camera configuration is recorded against the volume viewport.
    /// - Parameters:
    ///   - screenDelta: The pointer/touch movement in screen coordinates whose x component maps to yaw and y component maps to pitch.
    public func rotateVolumeCamera(screenDelta: CGSize) async {
        guard rotateVolumeCameraInteractively(screenDelta: screenDelta) else { return }
        await configureAndScheduleVolumeCameraRender()
    }

    public func zoomVolumeCamera(scale: Float) async {
        guard zoomVolumeCameraInteractively(scale: scale) else { return }
        await configureAndScheduleVolumeCameraRender()
    }

    @discardableResult
    func rotateVolumeCameraInteractively(screenDelta: CGSize) -> Bool {
        let beforeOffset = Logger.interactionLoggingEnabled ? volumeCameraOffset : .zero
        let beforeUp = Logger.interactionLoggingEnabled ? volumeCameraUp : .zero
        guard let camera = volumeOrbitState.rotate(deltaX: Float(screenDelta.width),
                                                   deltaY: Float(screenDelta.height)) else {
            logClinicalInteractionDebug("[MTKClinicalVolumeInteraction] camera.rotate.drop zero delta=\(screenDelta)")
            return false
        }
        applyVolumeOrbitCamera(camera)
        logClinicalInteractionInfo("[MTKClinicalVolumeInteraction] camera.rotate delta=\(screenDelta) yaw=\(volumeCameraYaw) pitch=\(volumeCameraPitch) beforeOffset=\(beforeOffset) afterOffset=\(volumeCameraOffset) beforeUp=\(beforeUp) afterUp=\(volumeCameraUp)")
        return true
    }

    @discardableResult
    func panVolumeCameraInteractively(screenDelta: CGSize) -> Bool {
        let threshold: CGFloat = 0.01
        guard screenDelta.width.isFinite,
              screenDelta.height.isFinite,
              abs(screenDelta.width) > threshold || abs(screenDelta.height) > threshold else {
            return false
        }
        let beforeTarget = Logger.interactionLoggingEnabled ? volumeCameraTarget : .zero
        var up = safeNormalize(volumeCameraUp, fallback: SIMD3<Float>(0, 1, 0))
        let forward = safeNormalize(-volumeCameraOffset, fallback: SIMD3<Float>(0, 0, -1))
        let right = safeNormalize(simd_cross(forward, up), fallback: SIMD3<Float>(1, 0, 0))
        up = safeNormalize(simd_cross(right, forward), fallback: up)
        
        let distance = max(simd_length(volumeCameraOffset), Float.ulpOfOne)
        let scaleX = (distance * 0.5) / 500.0
        let scaleY = (distance * 0.5) / 500.0
        let translation = (-Float(screenDelta.width) * scaleX) * right + (Float(screenDelta.height) * scaleY) * up
        
        volumeCameraTarget = clampVolumeCameraTarget(volumeCameraTarget + translation)
        volumeCameraUp = up
        volumeOrbitState.syncTarget(volumeCameraTarget)
        applyVolumeOrbitCamera(volumeOrbitState.camera)
        
        logClinicalInteractionInfo("[MTKClinicalVolumeInteraction] camera.pan delta=\(screenDelta) translation=\(translation) beforeTarget=\(beforeTarget) afterTarget=\(volumeCameraTarget)")
        return true
    }

    @discardableResult
    func zoomVolumeCameraInteractively(scale: Float) -> Bool {
        let beforeOffset = Logger.interactionLoggingEnabled ? volumeCameraOffset : .zero
        guard let camera = volumeOrbitState.zoom(scale: scale) else {
            logClinicalInteractionDebug("[MTKClinicalVolumeInteraction] camera.zoom.drop scale=\(scale)")
            return false
        }
        applyVolumeOrbitCamera(camera)
        logClinicalInteractionInfo("[MTKClinicalVolumeInteraction] camera.zoom scale=\(scale) beforeOffset=\(beforeOffset) afterOffset=\(volumeCameraOffset)")
        return true
    }

    @discardableResult
    func tiltVolumeCameraInteractively(roll: Float, pitch: Float) -> Bool {
        let beforeOffset = Logger.interactionLoggingEnabled ? volumeCameraOffset : .zero
        let beforeUp = Logger.interactionLoggingEnabled ? volumeCameraUp : .zero
        guard let camera = volumeOrbitState.tilt(roll: roll, pitch: pitch) else {
            logClinicalInteractionDebug("[MTKClinicalVolumeInteraction] camera.tilt.drop roll=\(roll) pitch=\(pitch)")
            return false
        }
        applyVolumeOrbitCamera(camera)
        logClinicalInteractionInfo("[MTKClinicalVolumeInteraction] camera.tilt roll=\(roll) pitch=\(pitch) yaw=\(volumeCameraYaw) accumulatedPitch=\(volumeCameraPitch) beforeOffset=\(beforeOffset) afterOffset=\(volumeCameraOffset) beforeUp=\(beforeUp) afterUp=\(volumeCameraUp)")
        return true
    }

    func flushVolumeCameraInteractionRender() {
        guard datasetApplied else { return }
        volumeCameraFlushPending = true
        guard volumeCameraFlushTask == nil else { return }
        volumeCameraFlushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.volumeCameraFlushPending, !Task.isCancelled {
                self.volumeCameraFlushPending = false
                await self.configureAndScheduleVolumeCameraRender()
            }
            self.volumeCameraFlushTask = nil
        }
    }

    private func configureAndScheduleVolumeCameraRender() async {
        do {
            try await configureVolumeCamera()
        } catch {
            logger.error("[MTKClinicalVolumeInteraction] camera.configure.error", error: error)
            recordError(error, for: volumeViewportID)
        }
    }

    private func applyVolumeOrbitCamera(_ camera: Volume3DOrbitCamera) {
        volumeCameraTarget = camera.target
        volumeCameraOffset = camera.offset
        volumeCameraUp = safeNormalize(camera.up, fallback: SIMD3<Float>(0, 1, 0))
        volumeCameraYaw = volumeOrbitState.yaw
        volumeCameraPitch = volumeOrbitState.pitch
        volumeCameraInteractionGeneration &+= 1
    }

    private func clampVolumeCameraTarget(_ target: SIMD3<Float>) -> SIMD3<Float> {
        guard target.x.isFinite,
              target.y.isFinite,
              target.z.isFinite else {
            return volumeCameraTarget
        }
        guard let currentDataset else { return target }

        let renderGeometry = VolumeRenderGeometry.make(for: currentDataset)
        let bounds = volumeCameraWorldBounds(for: renderGeometry)
        let padding = SIMD3<Float>(repeating: max(renderGeometry.boundingRadius * 0.25, 1e-3))
        let worldTarget = renderGeometry.worldPosition(forTextureCoordinate: target)
        let clampedWorldTarget = VolumetricMath.clampSIMD3(worldTarget,
                                                           min: bounds.minimum - padding,
                                                           max: bounds.maximum + padding)
        return renderGeometry.textureCoordinate(forWorldPosition: clampedWorldTarget)
    }

    private func volumeCameraWorldBounds(for renderGeometry: VolumeRenderGeometry) -> (minimum: SIMD3<Float>, maximum: SIMD3<Float>) {
        var minimum = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        for x in [Float(0), Float(1)] {
            for y in [Float(0), Float(1)] {
                for z in [Float(0), Float(1)] {
                    let corner = renderGeometry.worldPosition(forTextureCoordinate: SIMD3<Float>(x, y, z))
                    minimum = minComponents(minimum, corner)
                    maximum = maxComponents(maximum, corner)
                }
            }
        }
        return (minimum, maximum)
    }

    private func minComponents(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(min(lhs.x, rhs.x),
                     min(lhs.y, rhs.y),
                     min(lhs.z, rhs.z))
    }

    private func maxComponents(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(max(lhs.x, rhs.x),
                     max(lhs.y, rhs.y),
                     max(lhs.z, rhs.z))
    }

    /// Update the crosshair position on the specified MPR axis and schedule rendering for all affected viewports.
    /// 
    /// Sets the controller's normalized slice position(s) based on `normalizedPoint`, updates perpendicular axes' crosshair offsets, commits slice configuration for each changed axis, records any per-viewport errors that occur during configuration, and schedules renders for all viewports affected by the change.
    /// - Parameters:
    ///   - axis: The MPR axis whose plane the `normalizedPoint` is expressed in (axial, coronal, or sagittal).
    ///   - normalizedPoint: A point in the axis plane using normalized coordinates (typically in the 0–1 range); non-finite components are ignored and cause no change.
    public func setCrosshair(in axis: MTKCore.Axis, normalizedPoint: CGPoint) async {
        setActiveMPRAxis(axis)
        await applyCrosshairChange(from: axis, normalizedPoint: normalizedPoint)
    }

    /// Applies a crosshair drag that originated from a particular MPR axis.
    ///
    /// This method is the single source of truth for translating a gesture-driven crosshair drag into per-axis
    /// normalized slice positions and per-axis drawable pixel offsets. The originating axis always receives an
    /// updated offset so the drag feels responsive, while the two perpendicular axes receive updated normalized
    /// slice positions (and corresponding offsets).
    ///
    /// Update direction rules:
    /// - Drag in `.axial` updates `.sagittal` + `.coronal` slice positions.
    /// - Drag in `.coronal` updates `.sagittal` + `.axial` slice positions.
    /// - Drag in `.sagittal` updates `.coronal` + `.axial` slice positions.
    ///
    /// The `normalizedPositions` dictionary is the shared model. Viewports derive their slice configuration and
    /// crosshair overlays from this shared state, preventing per-pane divergence.
    public func applyCrosshairChange(from axis: MTKCore.Axis, normalizedPoint: CGPoint) async {
        guard normalizedPoint.x.isFinite,
              normalizedPoint.y.isFinite,
              let dataset = currentDataset else { return }

        let surfaceSize = drawableSize(for: axis)
        let clampedX = CGFloat(clampNormalized(Float(normalizedPoint.x)))
        let clampedY = CGFloat(clampNormalized(Float(normalizedPoint.y)))
        let pickPoint = CGPoint(x: clampedX * surfaceSize.width,
                                y: clampedY * surfaceSize.height)
        let previousPositions = normalizedPositions
        do {
            guard let context = mprGeometryDisplayContext(for: axis,
                                                          viewportSize: surfaceSize) else { return }
            let pick = try context.pick(screenPoint: pickPoint,
                                        layers: volumeLayers)
            setMPRCursorVoxel(pick.voxel.continuousIndex, in: dataset)
        } catch VolumePickError.outsideImagedArea {
            return
        } catch {
            let planeUpdates = normalizedPositionUpdates(from: normalizedPoint, in: axis)
            var cursor = mprCursorVoxel
            for (changedAxis, position) in planeUpdates {
                switch changedAxis {
                case .sagittal:
                    cursor.x = position * Float(max(dataset.dimensions.width - 1, 0))
                case .coronal:
                    cursor.y = position * Float(max(dataset.dimensions.height - 1, 0))
                case .axial:
                    cursor.z = position * Float(max(dataset.dimensions.depth - 1, 0))
                }
            }
            setMPRCursorVoxel(cursor, in: dataset)
        }

        rebuildAllCrosshairOffsets()

        var scheduledViewports = Set<ViewportID>([viewportID(for: axis)])
        for changedAxis in MTKCore.Axis.allCases where previousPositions[changedAxis] != normalizedPositions[changedAxis] {
            do {
                try await configureSlice(axis: changedAxis, window: windowLevel.range)
                scheduledViewports.insert(viewportID(for: changedAxis))
            } catch {
                recordError(error, for: viewportID(for: changedAxis))
            }
        }

        for viewport in scheduledViewports {
            scheduleRender(for: viewport)
        }
    }

    /// Scrolls the slice position of the specified MPR axis by a normalized delta.
    /// - Parameters:
    ///   - axis: The MPR axis whose slice position will be adjusted.
    ///   - deltaNormalized: The change to apply to the slice position, expressed in normalized coordinates (0.0–1.0).
    public func scrollSlice(axis: MTKCore.Axis, deltaNormalized: Float) async {
        setActiveMPRAxis(axis)
        await handleSliceScroll(axis: axis, delta: deltaNormalized)
    }

    /// Scrolls the slice position of the specified MPR axis by whole-slice steps.
    /// - Parameters:
    ///   - axis: The MPR axis whose slice position will be adjusted.
    ///   - steps: Signed slice count to move. Positive values advance toward the axis maximum.
    public func scrollSlice(axis: MTKCore.Axis, steps: Int) async {
        setActiveMPRAxis(axis)
        await handleSliceScroll(axis: axis, steps: steps)
    }

    /// Set the normalized slice position for an MPR axis, update dependent crosshair offsets, and schedule rendering for affected viewports.
    /// 
    /// If `normalizedPosition` is not finite or is rejected as unchanged, the method returns without side effects. Otherwise it updates stored normalized positions, adjusts perpendicular axes' crosshair offsets, attempts to configure the slice using the current `windowLevel.range`, and schedules a render for the axis' viewport and any affected perpendicular viewports. If slice configuration fails, the error is recorded for the axis' viewport.
    /// - Parameters:
    ///   - axis: The MPR axis whose slice position to set.
    ///   - normalizedPosition: The new slice position in normalized coordinates (0...1).
    public func setSlicePosition(axis: MTKCore.Axis, normalizedPosition: Float) async {
        setActiveMPRAxis(axis)
        guard normalizedPosition.isFinite, let dataset = currentDataset else { return }
        let previousPositions = normalizedPositions
        var cursor = mprCursorVoxel
        let next = clampNormalized(normalizedPosition)
        switch axis {
        case .sagittal:
            cursor.x = next * Float(max(dataset.dimensions.width - 1, 0))
        case .coronal:
            cursor.y = next * Float(max(dataset.dimensions.height - 1, 0))
        case .axial:
            cursor.z = next * Float(max(dataset.dimensions.depth - 1, 0))
        }
        setMPRCursorVoxel(cursor, in: dataset)
        guard previousPositions != normalizedPositions else { return }
        rebuildAllCrosshairOffsets()
        do {
            var scheduledViewports = Set<ViewportID>()
            for changedAxis in MTKCore.Axis.allCases where previousPositions[changedAxis] != normalizedPositions[changedAxis] {
                try await configureSlice(axis: changedAxis, window: windowLevel.range)
                scheduledViewports.insert(viewportID(for: changedAxis))
            }
            for viewport in scheduledViewports {
                scheduleRender(for: viewport)
            }
        } catch {
            recordError(error, for: viewportID(for: axis))
        }
    }

    /// Scrolls the slice for the specified axis by a normalized offset.
    /// - Parameters:
    ///   - axis: The axis whose slice position will be adjusted.
    ///   - delta: The normalized offset to add to the current slice position; non-finite values are ignored and the resulting position is clamped to the valid range.
    public func handleSliceScroll(axis: MTKCore.Axis, delta: Float) async {
        guard delta.isFinite else { return }
        let current = normalizedPositions[axis] ?? 0.5
        let next = clampNormalized(current + delta)
        await setSlicePosition(axis: axis, normalizedPosition: next)
    }

    /// Scrolls the slice for the specified axis by whole-slice steps.
    /// - Parameters:
    ///   - axis: The axis whose slice position will be adjusted.
    ///   - steps: Signed slice count to move. Non-zero values are quantized to the nearest slice boundary.
    public func handleSliceScroll(axis: MTKCore.Axis, steps: Int) async {
        guard steps != 0, let count = sliceCount(for: axis), count > 1 else { return }
        let maximumIndex = count - 1
        let current = clampNormalized(normalizedPositions[axis] ?? 0.5) * Float(maximumIndex)
        let base = steps > 0 ? floor(current) : ceil(current)
        let nextIndex = min(max(Int(base) + steps, 0), maximumIndex)
        await setSlicePosition(axis: axis,
                               normalizedPosition: Float(nextIndex) / Float(maximumIndex))
    }

    /// Updates crosshair offsets for axes perpendicular to a changed MPR axis based on a new normalized slice position.
    /// - Parameters:
    ///   - changedAxis: The axis whose slice position changed.
    ///   - newNormalizedPosition: The new normalized slice position for `changedAxis` (0.0–1.0, clamped).
    /// - Returns: An array of axes whose crosshair offsets were changed as a result of the update.
    @discardableResult
    public func updateCrosshairPositions(changedAxis: MTKCore.Axis,
                                         newNormalizedPosition: Float) -> [MTKCore.Axis] {
        var changedAxes: [MTKCore.Axis] = []
        if let dataset = currentDataset {
            var cursor = mprCursorVoxel
            let updatedPosition = clampNormalized(newNormalizedPosition)
            switch changedAxis {
            case .sagittal:
                cursor.x = updatedPosition * Float(max(dataset.dimensions.width - 1, 0))
            case .coronal:
                cursor.y = updatedPosition * Float(max(dataset.dimensions.height - 1, 0))
            case .axial:
                cursor.z = updatedPosition * Float(max(dataset.dimensions.depth - 1, 0))
            }
            setMPRCursorVoxel(cursor, in: dataset)
        } else {
            _ = setNormalizedPosition(newNormalizedPosition, for: changedAxis)
        }
        for axis in MTKCore.Axis.allCases {
            let nextOffset = crosshairOffset(for: axis)
            if setCrosshairOffset(nextOffset, for: axis) {
                changedAxes.append(axis)
            }
        }
        return changedAxes
    }

    /// Schedules a render for every displayed MPR viewport in the triplanar grid.
    ///
    /// The retained volume viewport is rendered only by explicit snapshot/export calls.
    public func scheduleRenderAll() {
        for viewport in mprViewportIDs {
            _ = scheduleRender(for: viewport)
        }
    }

    /// Schedules a render for every displayed MPR viewport and waits until all scheduled render tasks complete.
    /// - Note: If no render tasks are scheduled, the method returns immediately.
    public func renderAllAndWait() async {
        let tasks = mprViewportIDs.compactMap { scheduleRender(for: $0) }
        for task in tasks {
            await task.value
        }
    }

    /// Renders the 3D volume pane into a GPU-native frame for explicit snapshot/export.
    ///
    /// The frame is not presented to the viewport and is not converted to a
    /// CPU image here. Use `TextureSnapshotExporter` at the call site that
    /// Renders the volume viewport into a GPU-native frame suitable for snapshotting or export.
    /// - Returns: A `VolumeRenderFrame` containing the rendered texture and metadata (viewport size, viewport ID, `samplingDistance`, compositing mode, quality `.production`, pixel format, and render time).
    /// - Throws:
    ///   - `ClinicalViewportGridControllerError.noDatasetApplied` if no dataset has been applied to the controller.
    ///   - Any error produced while configuring volume render quality, performing the GPU render, or copying the texture for snapshotting. The `samplingDistance` in the returned metadata is derived from the controller's current volume render quality parameters.
    public func renderVolumeSnapshotFrame() async throws -> VolumeRenderFrame {
        guard datasetApplied else {
            throw ClinicalViewportGridControllerError.noDatasetApplied
        }

#if DEBUG
        await assertVolumeViewportConfigured()
#endif
        qualityScheduler.forceSettled()
        try await configureVolumeWindow(windowLevel.range)
        try await configureVolumeCamera()
        try await configureVolumeRenderQuality()
        try await configureVolumeClipping()
        let frame = try await engine.render(volumeViewportID)
        let snapshotTexture: any MTLTexture
        if let lease = frame.outputTextureLease {
            do {
                snapshotTexture = try await makeSnapshotTextureCopy(of: frame.texture)
                lease.release()
            } catch {
                lease.release()
                throw error
            }
        } else {
            snapshotTexture = frame.texture
        }
        let samplingStep = max(qualityScheduler.currentParameters.volumeSamplingStep, 1)
        return VolumeRenderFrame(
            texture: snapshotTexture,
            metadata: VolumeRenderFrame.Metadata(
                viewportSize: frame.metadata.viewportSize,
                viewportID: frame.viewportID,
                samplingDistance: 1 / samplingStep,
                compositing: volumeViewportMode.compositing,
                quality: .production,
                pixelFormat: snapshotTexture.pixelFormat,
                renderTime: frame.metadata.renderTime
            )
        )
    }

    public func canExportMPRSnapshot(axis: MTKCore.Axis) -> Bool {
        guard datasetApplied else { return false }
        let size = surface(for: axis).drawablePixelSize
        return size.width > 0 && size.height > 0
    }

    public func renderMPRSnapshotFrame(axis: MTKCore.Axis) async throws -> VolumeRenderFrame {
        guard datasetApplied else {
            throw ClinicalViewportGridControllerError.noDatasetApplied
        }

        try await configureMPRSlabResolved()
        try await configureSlice(axis: axis, window: windowLevel.range)
        let viewport = viewportID(for: axis)
        let frame = try await engine.render(viewport)
        defer { frame.outputTextureLease?.release() }
        try renderGraph.validateFrame(frame)
        guard let mprFrame = frame.mprFrame,
              let transform = presentationTransform(for: frame.viewportID, frame: mprFrame) else {
            throw RenderGraphError.passProducedNoFrame(frame.viewportID, .mprReslice)
        }

        let surface = surface(for: axis)
        let size = Self.mprSnapshotSize(from: surface.drawablePixelSize,
                                        fallback: frame.metadata.viewportSize)
        var presentationPass = try MPRPresentationPass(device: device,
                                                       commandQueue: surface.commandQueue)
        let startedAt = CFAbsoluteTimeGetCurrent()
        let texture = try presentationPass.makeSnapshotTexture(
            frame: mprFrame,
            window: windowLevel.range,
            transform: transform,
            width: Int(size.width),
            height: Int(size.height),
            invert: isMPRWindowInverted,
            colormap: mprColormapTexture,
            viewportTransform: viewportTransform(for: axis),
            labelmapOverlays: frame.labelmapOverlays,
            scalarOverlays: frame.scalarOverlays,
            shutter: mprPresentationStates[axis]?.shutter
        )

        return VolumeRenderFrame(
            texture: texture,
            metadata: VolumeRenderFrame.Metadata(
                viewportSize: CGSize(width: CGFloat(texture.width),
                                     height: CGFloat(texture.height)),
                viewportID: viewport,
                samplingDistance: 1,
                compositing: .frontToBack,
                quality: .production,
                pixelFormat: texture.pixelFormat,
                renderTime: CFAbsoluteTimeGetCurrent() - startedAt
            )
        )
    }

    private static func mprSnapshotSize(from drawableSize: CGSize,
                                        fallback: CGSize) -> CGSize {
        let width = drawableSize.width.isFinite && drawableSize.width > 0
            ? drawableSize.width
            : fallback.width
        let height = drawableSize.height.isFinite && drawableSize.height > 0
            ? drawableSize.height
            : fallback.height
        return CGSize(width: max(1, width.rounded(.toNearestOrAwayFromZero)),
                      height: max(1, height.rounded(.toNearestOrAwayFromZero)))
    }

    /// Fetches the current render generation counter for the given viewport.
    /// - Parameter viewport: The viewport identifier.
    /// - Returns: The render generation for `viewport`, or `0` if no generation is recorded.
    @_spi(Testing)
    public func debugRenderGeneration(for viewport: ViewportID) -> UInt64 {
        renderGenerations[viewport] ?? 0
    }

    /// Retrieve the cached debug snapshot for a viewport, or a default "unknown" snapshot if none is available.
    /// - Parameters:
    ///   - viewport: The identifier of the viewport to query.
    /// - Returns: The `ClinicalViewportDebugSnapshot` for the given viewport, or a synthesized snapshot with unknown type and render mode when no cached snapshot exists.
    public func debugSnapshot(for viewport: ViewportID) -> ClinicalViewportDebugSnapshot {
        if let snapshot = debugSnapshots[viewport] {
            return snapshot
        }
        return Self.makeDebugSnapshot(viewportID: viewport,
                                      viewportName: "Viewport",
                                      viewportType: "unknown",
                                      renderMode: "unknown")
    }

    /// Create a display contract for the specified MPR axis.
    /// - Parameter axis: The MPR axis (axial, coronal, or sagittal) to build the contract for.
    /// - Returns: A `ClinicalMPRDisplayContract` that wraps the display transform for the specified axis.
    /// - Note: Deprecated — use `displayTransform(for:)` instead.
    @available(*, deprecated, message: "Use displayTransform(for:) instead.")
    public func displayContract(for axis: MTKCore.Axis) -> ClinicalMPRDisplayContract {
        ClinicalMPRDisplayContract(displayTransform(for: axis))
    }

    /// Creates an MPR display transform for the given plane geometry and viewport axis.
    /// - Parameters:
    ///   - geometry: The plane geometry (slice position, spacing, and orientation) to build the transform from.
    ///   - axis: The viewport axis used to determine the plane orientation.
    /// - Returns: An `MPRDisplayTransform` that maps volume coordinates for the specified plane and axis into display space.
    public func displayTransform(for geometry: MPRPlaneGeometry,
                                 axis: MTKCore.Axis) -> MPRDisplayTransform {
        MPRDisplayTransformFactory.makeTransform(for: geometry,
                                                axis: planeAxis(for: axis))
    }

    /// Get the MPR display transform for the specified axis.
    /// 
    /// If a cached transform exists for the axis it is returned; otherwise the transform is created
    /// from the current dataset's plane geometry. If no dataset is applied, a fallback plane geometry
    /// is used to produce the transform.
    /// - Returns: The `MPRDisplayTransform` for the given axis.
    public func displayTransform(for axis: MTKCore.Axis) -> MPRDisplayTransform {
        if let cached = displayTransformsByAxis[axis] {
            return cached
        }
        if let context = mprGeometryDisplayContext(for: axis) {
            displayTransformsByAxis[axis] = context.displayTransform
            return context.displayTransform
        }
        if let plane = currentMPRPlane(for: axis) {
            let transform = displayTransform(for: plane, axis: axis)
            displayTransformsByAxis[axis] = transform
            return transform
        }
        guard let currentDataset else {
            return displayTransform(for: fallbackPlaneGeometry(for: axis), axis: axis)
        }

        let plane = MPRPlaneGeometryFactory.makePlane(for: currentDataset,
                                                      axis: planeAxis(for: axis),
                                                      slicePosition: normalizedPositions[axis] ?? 0.5)
        let transform = displayTransform(for: plane, axis: axis)
        displayTransformsByAxis[axis] = transform
        return transform
    }

    /// Retrieves the most recently recorded render error for the specified viewport.
    /// - Parameter viewport: The identifier of the viewport to query.
    /// - Returns: The last `Error` recorded for `viewport`, or `nil` if no error has been recorded.
    public func lastRenderError(for viewport: ViewportID) -> (any Error)? {
        lastRenderErrors[viewport]
    }
}
