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

private extension WindowLevelShift {
    init(range: ClosedRange<Int32>) {
        let lower = Double(range.lowerBound)
        let upper = Double(range.upperBound)
        self.init(window: max(upper - lower, 1), level: (lower + upper) / 2)
    }

    var range: ClosedRange<Int32> {
        let lower = Int32((level - window / 2).rounded())
        let upper = Int32((level + window / 2).rounded())
        return min(lower, upper)...max(lower, upper)
    }
}

public enum ClinicalVolumeViewportMode: String, CaseIterable, Sendable {
    case dvr
    case mip
    case minip
    case aip

    var viewportType: ViewportType {
        switch self {
        case .dvr:
            return .volume3D
        case .mip:
            return .projection(mode: .mip)
        case .minip:
            return .projection(mode: .minip)
        case .aip:
            return .projection(mode: .aip)
        }
    }

    var displayName: String {
        switch self {
        case .dvr:
            return "3D"
        case .mip:
            return "MIP"
        case .minip:
            return "MinIP"
        case .aip:
            return "AIP"
        }
    }

    var compositing: VolumeRenderRequest.Compositing {
        switch self {
        case .dvr:
            return .frontToBack
        case .mip:
            return .maximumIntensity
        case .minip:
            return .minimumIntensity
        case .aip:
            return .averageIntensity
        }
    }
}

public struct ClinicalViewportTimingSnapshot: Equatable, Sendable {
    public var renderTime: CFAbsoluteTime?
    public var presentationTime: CFAbsoluteTime?
    public var uploadTime: CFAbsoluteTime?

    public init(renderTime: CFAbsoluteTime? = nil,
                presentationTime: CFAbsoluteTime? = nil,
                uploadTime: CFAbsoluteTime? = nil) {
        self.renderTime = renderTime
        self.presentationTime = presentationTime
        self.uploadTime = uploadTime
    }
}

public struct ClinicalSlabConfiguration: Equatable, Sendable {
    public var thickness: Int
    public var steps: Int

    public init(thickness: Int = 3, steps: Int? = nil) {
        let resolvedThickness = Self.snapToOddVoxelCount(max(1, thickness))
        self.thickness = resolvedThickness
        self.steps = Self.snapToOddVoxelCount(max(1, steps ?? max(resolvedThickness * 2, 6)))
    }

    private static func snapToOddVoxelCount(_ value: Int) -> Int {
        guard value > 0 else { return 1 }
        if value % 2 == 0 {
            return value == Int.max ? value - 1 : value + 1
        }
        return value
    }
}

public enum ClinicalViewportGridControllerError: Error, Equatable, LocalizedError {
    case metalUnavailable
    case noDatasetApplied
    case viewportSurfaceNotFound

    public var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            return "Metal device unavailable"
        case .noDatasetApplied:
            return "No dataset is loaded in the clinical viewport grid"
        case .viewportSurfaceNotFound:
            return "Viewport surface not found"
        }
    }
}

public struct ClinicalViewportDebugSnapshot: Equatable, Sendable, Identifiable {
    public let viewportID: ViewportID
    public let viewportName: String
    public let viewportType: String
    public let renderMode: String
    public let datasetHandle: String?
    public let volumeTextureLabel: String?
    public let outputTextureLabel: String?
    public let lastPassExecuted: String?
    public let presentationStatus: String
    public let lastError: String?
    public let lastRenderRequestTime: CFAbsoluteTime?
    public let lastRenderCompletionTime: CFAbsoluteTime?
    public let lastPresentationTime: CFAbsoluteTime?

    public var id: ViewportID { viewportID }

    public init(viewportID: ViewportID,
                viewportName: String,
                viewportType: String,
                renderMode: String,
                datasetHandle: String? = nil,
                volumeTextureLabel: String? = nil,
                outputTextureLabel: String? = nil,
                lastPassExecuted: String? = nil,
                presentationStatus: String = "idle",
                lastError: String? = nil,
                lastRenderRequestTime: CFAbsoluteTime? = nil,
                lastRenderCompletionTime: CFAbsoluteTime? = nil,
                lastPresentationTime: CFAbsoluteTime? = nil) {
        self.viewportID = viewportID
        self.viewportName = viewportName
        self.viewportType = viewportType
        self.renderMode = renderMode
        self.datasetHandle = datasetHandle
        self.volumeTextureLabel = volumeTextureLabel
        self.outputTextureLabel = outputTextureLabel
        self.lastPassExecuted = lastPassExecuted
        self.presentationStatus = presentationStatus
        self.lastError = lastError
        self.lastRenderRequestTime = lastRenderRequestTime
        self.lastRenderCompletionTime = lastRenderCompletionTime
        self.lastPresentationTime = lastPresentationTime
    }
}

@available(*, deprecated, message: "Use MPRDisplayTransform instead.")
public struct ClinicalMPRDisplayContract: Equatable, Sendable {
    public let flipHorizontal: Bool
    public let flipVertical: Bool
    public let labels: (leading: String, trailing: String, top: String, bottom: String)

    public init(flipHorizontal: Bool,
                flipVertical: Bool,
                labels: (leading: String, trailing: String, top: String, bottom: String)) {
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.labels = labels
    }

    public init(_ transform: MPRDisplayTransform) {
        self.init(flipHorizontal: transform.presentationFlipHorizontal,
                  flipVertical: transform.presentationFlipVertical,
                  labels: transform.labels)
    }

    public static func `default`(for axis: MTKCore.Axis) -> ClinicalMPRDisplayContract {
        ClinicalMPRDisplayContract(defaultClinicalMPRDisplayTransform(for: axis))
    }

    public static func == (lhs: ClinicalMPRDisplayContract, rhs: ClinicalMPRDisplayContract) -> Bool {
        lhs.flipHorizontal == rhs.flipHorizontal &&
        lhs.flipVertical == rhs.flipVertical &&
        lhs.labels.leading == rhs.labels.leading &&
        lhs.labels.trailing == rhs.labels.trailing &&
        lhs.labels.top == rhs.labels.top &&
        lhs.labels.bottom == rhs.labels.bottom
    }
}

private extension ViewportType {
    var debugName: String {
        switch self {
        case .volume3D:
            return "volume3D"
        case .mpr(let axis):
            return "mpr(\(axis.debugName))"
        case .projection(let mode):
            return "projection(\(mode.debugName))"
        }
    }
}

private extension ProjectionMode {
    var debugName: String {
        switch self {
        case .mip:
            return "mip"
        case .minip:
            return "minip"
        case .aip:
            return "aip"
        }
    }
}

private extension MTKCore.Axis {
    var debugName: String {
        switch self {
        case .axial:
            return "axial"
        case .coronal:
            return "coronal"
        case .sagittal:
            return "sagittal"
        }
    }
}

/// Metal-native controller for the fixed 2x2 clinical viewport grid.
///
/// The controller is isolated to `@MainActor` because it owns SwiftUI-observed state and
/// `MetalViewportSurface` presentation objects. Call public methods from the main actor; methods
/// that cross into `MTKRenderingEngine` perform GPU work through that engine actor.
@MainActor
public final class ClinicalViewportGridController: ObservableObject {
    public let engine: MTKRenderingEngine
    public let axialViewportID: ViewportID
    public let coronalViewportID: ViewportID
    public let sagittalViewportID: ViewportID
    public let volumeViewportID: ViewportID

    public let axialSurface: MetalViewportSurface
    public let coronalSurface: MetalViewportSurface
    public let sagittalSurface: MetalViewportSurface
    public let volumeSurface: MetalViewportSurface

    @Published public private(set) var windowLevel = WindowLevelShift(window: 400, level: 40)
    @Published public private(set) var slabThickness: Double = 3
    @Published public private(set) var normalizedPositions: [MTKCore.Axis: Float] = ClinicalViewportGridController.centeredNormalizedPositions
    @Published public private(set) var crosshairOffsets: [MTKCore.Axis: CGPoint] = ClinicalViewportGridController.centeredCrosshairOffsets
    @Published public private(set) var sharedResourceHandle: VolumeResourceHandle?
    @Published public private(set) var datasetApplied = false
    @Published public private(set) var renderQualityState: RenderQualityState = .settled
    @Published public private(set) var lastRenderErrors: [ViewportID: any Error] = [:]
    @Published public private(set) var lastRenderError: (any Error)?
    @Published public private(set) var volumeViewportMode: ClinicalVolumeViewportMode = .dvr
    @Published public private(set) var latestTimingSnapshot = ClinicalViewportTimingSnapshot()
    @Published public private(set) var debugSnapshots: [ViewportID: ClinicalViewportDebugSnapshot] = [:]

    private var renderTasks: [ViewportID: Task<Void, Never>] = [:]
    private var renderGenerations: [ViewportID: UInt64] = [:]
    private var viewportTimings: [ViewportID: FrameMetadata] = [:]
    private let qualityScheduler = RenderQualityScheduler()
    private let renderGraph = ViewportRenderGraph()
    private let logger = Logger(category: "ClinicalViewportGridController")
    private var qualityStateCancellable: AnyCancellable?
    private var committedMPRWindowRange: ClosedRange<Int32>?
    private var volumeCameraTarget = SIMD3<Float>(repeating: 0.5)
    private var volumeCameraOffset = SIMD3<Float>(0, 0, 2)
    private var volumeCameraUp = SIMD3<Float>(0, 1, 0)
    private var currentDataset: VolumeDataset?
    private var displayTransformsByAxis: [MTKCore.Axis: MPRDisplayTransform] = [:]
    private var viewportAxesByID: [ViewportID: MTKCore.Axis] = [:]

    private static let centeredNormalizedPositions: [MTKCore.Axis: Float] = [
        .axial: 0.5,
        .coronal: 0.5,
        .sagittal: 0.5
    ]

    private static let centeredCrosshairOffsets: [MTKCore.Axis: CGPoint] = [
        .axial: .zero,
        .coronal: .zero,
        .sagittal: .zero
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
        self.engine = engine
        self.axialViewportID = try await engine.createViewport(
            ViewportDescriptor(type: .mpr(axis: .axial),
                               initialSize: initialViewportSize,
                               label: "Axial MPR")
        )
        self.coronalViewportID = try await engine.createViewport(
            ViewportDescriptor(type: .mpr(axis: .coronal),
                               initialSize: initialViewportSize,
                               label: "Coronal MPR")
        )
        self.sagittalViewportID = try await engine.createViewport(
            ViewportDescriptor(type: .mpr(axis: .sagittal),
                               initialSize: initialViewportSize,
                               label: "Sagittal MPR")
        )
        self.volumeViewportID = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D,
                               initialSize: initialViewportSize,
                               label: "Volume 3D")
        )

        self.axialSurface = try MetalViewportSurface(device: resolvedDevice)
        self.coronalSurface = try MetalViewportSurface(device: resolvedDevice)
        self.sagittalSurface = try MetalViewportSurface(device: resolvedDevice)
        self.volumeSurface = try MetalViewportSurface(device: resolvedDevice)
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

        configureSurfaceCallbacks()
        qualityStateCancellable = qualityScheduler.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                self.renderQualityState = state
                if state == .settled {
                    Task { @MainActor in
                        await self.applyRenderQualityAndSchedule()
                    }
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
    /// remaining tasks and ask the engine to destroy already-known viewport identifiers.
    public func shutdown() async {
        renderTasks.values.forEach { $0.cancel() }
        renderTasks.removeAll()
        renderGenerations.removeAll()
        for viewport in allViewportIDs {
            await engine.destroyViewport(viewport)
        }
        sharedResourceHandle = nil
        currentDataset = nil
        displayTransformsByAxis.removeAll()
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

    /// Convenience factory for the common "create controller, then apply dataset" path.
    ///
    /// - Parameters:
    ///   - device: Optional Metal device. When omitted, the system default device is used.
    ///   - initialViewportSize: Initial size used when creating engine viewports.
    ///   - dataset: Optional dataset to upload to all four viewports.
    ///   - transferFunction: Optional transfer function for the 3D volume pane only.
    /// - Returns: A configured clinical viewport grid controller.
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

    /// Uploads one dataset to all four viewports using the engine's shared resource handle.
    ///
    /// All MPR and volume panes receive the same `VolumeResourceHandle`. In debug builds, the
    /// controller logs resource diagnostics and asserts that all viewports resolve to one texture.
    public func applyDataset(_ dataset: VolumeDataset) async throws {
        let handle = try await engine.setVolume(dataset, for: allViewportIDs)
        sharedResourceHandle = handle
        currentDataset = dataset
        displayTransformsByAxis.removeAll()
        viewportTimings.removeAll()
        latestTimingSnapshot = ClinicalViewportTimingSnapshot()

        let initialWindow = dataset.recommendedWindow ?? dataset.intensityRange
        windowLevel = WindowLevelShift(range: initialWindow)
        normalizedPositions = Self.centeredNormalizedPositions
        rebuildAllCrosshairOffsets()
        slabThickness = 3
        resetVolumeCamera()
        datasetApplied = true
        lastRenderErrors.removeAll()
        lastRenderError = nil

        try await configureAllMPRSlices(window: windowLevel.range)
        committedMPRWindowRange = windowLevel.range
        try await configureMPRSlab()
        try await configureVolumeWindow(windowLevel.range)
        try await configureVolumeCamera()
        try await configureVolumeRenderQuality()
        let volumeTextureLabel = await engine.volumeTextureLabel(for: volumeViewportID)
        for viewport in allViewportIDs {
            updateDebugSnapshot(for: viewport) { snapshot in
                snapshot = ClinicalViewportDebugSnapshot(
                    viewportID: snapshot.viewportID,
                    viewportName: snapshot.viewportName,
                    viewportType: viewportTypeName(for: viewport),
                    renderMode: renderModeName(for: viewport),
                    datasetHandle: datasetHandleLabel(for: viewport),
                    volumeTextureLabel: volumeTextureLabel,
                    outputTextureLabel: snapshot.outputTextureLabel,
                    lastPassExecuted: snapshot.lastPassExecuted,
                    presentationStatus: "ready",
                    lastError: nil,
                    lastRenderRequestTime: snapshot.lastRenderRequestTime,
                    lastRenderCompletionTime: snapshot.lastRenderCompletionTime,
                    lastPresentationTime: snapshot.lastPresentationTime
                )
            }
        }
#if DEBUG
        await logResourceSharingDiagnostics()
#endif
        scheduleRenderAll()
    }

    public func beginAdaptiveSamplingInteraction() async {
        qualityScheduler.beginInteraction()
        await applyRenderQualityAndSchedule()
    }

    public func endAdaptiveSamplingInteraction() async {
        qualityScheduler.endInteraction()
    }

    public func forceFinalRenderQuality() async {
        qualityScheduler.forceSettled()
    }

    /// Applies a transfer function to the volume viewport only.
    ///
    /// This intentionally does not update MPR window/level or MPR presentation state; the volume
    /// pane's transfer function is independent from MPR windowing.
    public func setTransferFunction(_ transferFunction: TransferFunction?) async throws {
        try await engine.configure(volumeViewportID,
                                   transferFunction: transferFunction.map(Self.volumeTransferFunction))
        scheduleRender(for: volumeViewportID)
    }

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
            snapshot = ClinicalViewportDebugSnapshot(
                viewportID: snapshot.viewportID,
                viewportName: snapshot.viewportName,
                viewportType: mode.viewportType.debugName,
                renderMode: mode.rawValue,
                datasetHandle: snapshot.datasetHandle,
                volumeTextureLabel: snapshot.volumeTextureLabel,
                outputTextureLabel: snapshot.outputTextureLabel,
                lastPassExecuted: "configureVolumeMode",
                presentationStatus: "scheduled",
                lastError: nil,
                lastRenderRequestTime: snapshot.lastRenderRequestTime,
                lastRenderCompletionTime: snapshot.lastRenderCompletionTime,
                lastPresentationTime: snapshot.lastPresentationTime
            )
        }
        if datasetApplied {
            let frame = try await engine.render(volumeViewportID)
            frame.outputTextureLease?.release()
            try renderGraph.validateFrame(frame)
        }
#if DEBUG
        await assertVolumeViewportConfigured()
#endif
        scheduleRender(for: volumeViewportID)
    }

    /// Updates the shared MPR window/level and schedules MPR presentation updates.
    public func setMPRWindowLevel(window: Double, level: Double) async {
        let resolved = WindowLevelShift(window: max(window, 1), level: level)
        guard resolved != windowLevel else { return }
        windowLevel = resolved
        await commitWindowLevel()
    }

    /// Commits the current MPR window/level to axial, coronal, and sagittal viewports only.
    ///
    /// The controller attempts to configure all three MPR axes before deciding
    /// whether the shared commit succeeded. Any axis-specific failure is stored
    /// against that viewport and prevents the follow-up render scheduling.
    public func commitWindowLevel() async {
        let range = windowLevel.range
        guard committedMPRWindowRange != range else { return }
        var failures: [(ViewportID, any Error)] = []
        for axis in MTKCore.Axis.allCases {
            do {
                try await configureSlice(axis: axis, window: range)
            } catch {
                failures.append((viewportID(for: axis), error))
            }
        }
        guard failures.isEmpty else {
            for (viewport, error) in failures {
                recordError(error, for: viewport)
            }
            return
        }
        committedMPRWindowRange = range
        scheduleMPRRenderAll()
    }

    /// Updates slab thickness for the three MPR viewports.
    public func setMPRSlabThickness(_ thickness: Double) async {
        guard thickness.isFinite else { return }
        let resolved = ClinicalSlabConfiguration(thickness: Int(thickness))
        let nextThickness = Double(resolved.thickness)
        guard nextThickness != slabThickness else { return }
        slabThickness = nextThickness
        let base = resolved
        qualityScheduler.setBaseSlabSteps(base.steps)
        let effectiveSteps = Int(round(Float(base.steps) * qualityScheduler.currentParameters.mprSlabStepsFactor))
        let configured = ClinicalSlabConfiguration(thickness: base.thickness,
                                                   steps: max(effectiveSteps, 1))
        var hadFailures = false
        for viewport in mprViewportIDs {
            do {
                try await engine.configure(viewport,
                                           slabThickness: configured.thickness,
                                           slabSteps: configured.steps)
            } catch {
                recordError(error, for: viewport)
                hadFailures = true
            }
        }
        guard !hadFailures else { return }
        scheduleMPRRenderAll()
    }

    /// Rotates the independent 3D volume viewport camera.
    public func rotateVolumeCamera(screenDelta: CGSize) async {
        guard screenDelta.width.isFinite, screenDelta.height.isFinite else { return }
        let yaw = Float(screenDelta.width) * 0.01
        let pitch = Float(screenDelta.height) * 0.01
        guard abs(yaw) > Float.ulpOfOne || abs(pitch) > Float.ulpOfOne else { return }

        let yawRotation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        volumeCameraOffset = yawRotation.act(volumeCameraOffset)
        volumeCameraUp = yawRotation.act(volumeCameraUp)

        let forward = safeNormalize(-volumeCameraOffset, fallback: SIMD3<Float>(0, 0, -1))
        let right = safeNormalize(simd_cross(forward, volumeCameraUp), fallback: SIMD3<Float>(1, 0, 0))
        let pitchRotation = simd_quatf(angle: pitch, axis: right)
        volumeCameraOffset = pitchRotation.act(volumeCameraOffset)
        volumeCameraUp = safeNormalize(pitchRotation.act(volumeCameraUp), fallback: SIMD3<Float>(0, 1, 0))

        do {
            try await configureVolumeCamera()
            scheduleRender(for: volumeViewportID)
        } catch {
            recordError(error, for: volumeViewportID)
        }
    }

    /// Moves the crosshair in one MPR pane and synchronizes the two perpendicular slices.
    public func setCrosshair(in axis: MTKCore.Axis, normalizedPoint: CGPoint) async {
        guard normalizedPoint.x.isFinite, normalizedPoint.y.isFinite else { return }
        let planeUpdates = normalizedPositionUpdates(from: normalizedPoint, in: axis)
        var scheduledViewports = Set<ViewportID>()

        for (changedAxis, position) in planeUpdates {
            guard setNormalizedPosition(position, for: changedAxis) else { continue }
            let affectedAxes = updateCrosshairPositions(changedAxis: changedAxis,
                                                        newNormalizedPosition: position)
            do {
                try await configureSlice(axis: changedAxis, window: windowLevel.range)
                scheduledViewports.insert(viewportID(for: changedAxis))
                for affectedAxis in affectedAxes {
                    scheduledViewports.insert(viewportID(for: affectedAxis))
                }
            } catch {
                recordError(error, for: viewportID(for: changedAxis))
            }
        }

        for viewport in scheduledViewports {
            scheduleRender(for: viewport)
        }
    }

    public func scrollSlice(axis: MTKCore.Axis, deltaNormalized: Float) async {
        await handleSliceScroll(axis: axis, delta: deltaNormalized)
    }

    /// Sets the absolute normalized slice position for one MPR axis.
    public func setSlicePosition(axis: MTKCore.Axis, normalizedPosition: Float) async {
        guard normalizedPosition.isFinite else { return }
        guard setNormalizedPosition(normalizedPosition, for: axis) else { return }
        let next = normalizedPositions[axis] ?? 0.5
        let affectedAxes = updateCrosshairPositions(changedAxis: axis,
                                                    newNormalizedPosition: next)
        do {
            try await configureSlice(axis: axis, window: windowLevel.range)
            var scheduledViewports = Set([viewportID(for: axis)])
            for affectedAxis in affectedAxes {
                scheduledViewports.insert(viewportID(for: affectedAxis))
            }
            for viewport in scheduledViewports {
                scheduleRender(for: viewport)
            }
        } catch {
            recordError(error, for: viewportID(for: axis))
        }
    }

    /// Scrolls one MPR slice by a normalized delta and synchronizes affected crosshairs.
    public func handleSliceScroll(axis: MTKCore.Axis, delta: Float) async {
        guard delta.isFinite else { return }
        let current = normalizedPositions[axis] ?? 0.5
        let next = clampNormalized(current + delta)
        await setSlicePosition(axis: axis, normalizedPosition: next)
    }

    /// Recomputes crosshair offsets for the two views perpendicular to the changed axis.
    @discardableResult
    public func updateCrosshairPositions(changedAxis: MTKCore.Axis,
                                         newNormalizedPosition: Float) -> [MTKCore.Axis] {
        let updatedPosition = clampNormalized(newNormalizedPosition)
        let positions = normalizedPositions.merging([changedAxis: updatedPosition]) { _, new in new }
        let affectedAxes = perpendicularAxes(to: changedAxis)
        var changedAxes: [MTKCore.Axis] = []

        for axis in affectedAxes {
            let nextOffset = crosshairOffset(for: axis, positions: positions)
            if setCrosshairOffset(nextOffset, for: axis) {
                changedAxes.append(axis)
            }
        }
        return changedAxes
    }

    public func scheduleRenderAll() {
        for viewport in allViewportIDs {
            _ = scheduleRender(for: viewport)
        }
    }

    public func renderAllAndWait() async {
        let tasks = allViewportIDs.compactMap { scheduleRender(for: $0) }
        for task in tasks {
            await task.value
        }
    }

    /// Renders the 3D volume pane into a GPU-native frame for explicit snapshot/export.
    ///
    /// The frame is not presented to the viewport and is not converted to a
    /// CPU image here. Use `TextureSnapshotExporter` at the call site that
    /// handles the user-initiated export action.
    public func renderVolumeSnapshotFrame() async throws -> VolumeRenderFrame {
        guard datasetApplied else {
            throw ClinicalViewportGridControllerError.noDatasetApplied
        }

#if DEBUG
        await assertVolumeViewportConfigured()
#endif
        qualityScheduler.forceSettled()
        try await configureVolumeRenderQuality()
        let frame = try await engine.render(volumeViewportID)
        let snapshotTexture: any MTLTexture
        if let lease = frame.outputTextureLease {
            do {
                snapshotTexture = try makeSnapshotTextureCopy(of: frame.texture)
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

    @_spi(Testing)
    public func debugRenderGeneration(for viewport: ViewportID) -> UInt64 {
        renderGenerations[viewport] ?? 0
    }

    public func debugSnapshot(for viewport: ViewportID) -> ClinicalViewportDebugSnapshot {
        if let snapshot = debugSnapshots[viewport] {
            return snapshot
        }
        return Self.makeDebugSnapshot(viewportID: viewport,
                                      viewportName: "Viewport",
                                      viewportType: "unknown",
                                      renderMode: "unknown")
    }

    @available(*, deprecated, message: "Use displayTransform(for:) instead.")
    public func displayContract(for axis: MTKCore.Axis) -> ClinicalMPRDisplayContract {
        ClinicalMPRDisplayContract(displayTransform(for: axis))
    }

    public func displayTransform(for geometry: MPRPlaneGeometry,
                                 axis: MTKCore.Axis) -> MPRDisplayTransform {
        MPRDisplayTransformFactory.makeTransform(for: geometry,
                                                axis: planeAxis(for: axis))
    }

    public func displayTransform(for axis: MTKCore.Axis) -> MPRDisplayTransform {
        if let cached = displayTransformsByAxis[axis] {
            return cached
        }
        guard let currentDataset else {
            return displayTransform(for: fallbackPlaneGeometry(for: axis), axis: axis)
        }

        let plane = MPRPlaneGeometryFactory.makePlane(for: currentDataset,
                                                      axis: planeAxis(for: axis),
                                                      slicePosition: normalizedPositions[axis] ?? 0.5)
        return displayTransform(for: plane, axis: axis)
    }

    public func lastRenderError(for viewport: ViewportID) -> (any Error)? {
        lastRenderErrors[viewport]
    }
}

private extension ClinicalViewportGridController {
    func makeSnapshotTextureCopy(of source: any MTLTexture) throws -> any MTLTexture {
        guard volumeSurface.commandQueue.device.registryID == source.device.registryID,
              let commandBuffer = volumeSurface.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeBlitCommandEncoder()
        else {
            throw SnapshotExportError.readbackFailed("Could not create snapshot copy command resources.")
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.pixelFormat,
                                                                  width: source.width,
                                                                  height: source.height,
                                                                  mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]

        guard let destination = source.device.makeTexture(descriptor: descriptor) else {
            throw SnapshotExportError.readbackFailed("Could not create snapshot copy texture.")
        }
        destination.label = "ClinicalViewportGridController.SnapshotCopy"

        encoder.copy(from: source,
                     sourceSlice: 0,
                     sourceLevel: 0,
                     sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                     sourceSize: MTLSize(width: source.width,
                                         height: source.height,
                                         depth: 1),
                     to: destination,
                     destinationSlice: 0,
                     destinationLevel: 0,
                     destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw SnapshotExportError.readbackFailed(error.localizedDescription)
        }

        return destination
    }

    func configureSurfaceCallbacks() {
        let pairs: [(ViewportID, MetalViewportSurface)] = [
            (axialViewportID, axialSurface),
            (coronalViewportID, coronalSurface),
            (sagittalViewportID, sagittalSurface),
            (volumeViewportID, volumeSurface)
        ]

        for (viewportID, surface) in pairs {
            surface.onDrawableSizeChange = { [weak self] size in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await self.engine.resize(viewportID, to: size)
                        self.rebuildAllCrosshairOffsets()
                        self.scheduleRender(for: viewportID)
                    } catch {
                        self.recordError(error, for: viewportID)
                    }
                }
            }
            surface.onPresentationFailure = { [weak self] error, presentationToken in
                guard let self else { return false }
                if let presentationToken,
                   self.renderGenerations[viewportID] != presentationToken {
                    self.logger.debug("Ignoring stale presentation failure viewport=\(self.viewportName(for: viewportID)) token=\(presentationToken)")
                    return false
                }
                self.handlePresentationFailure(error, for: viewportID)
                return true
            }
        }
    }

    func configureAllMPRSlices(window: ClosedRange<Int32>?) async throws {
        for axis in MTKCore.Axis.allCases {
            try await configureSlice(axis: axis, window: window)
        }
    }

    func configureSlice(axis: MTKCore.Axis, window: ClosedRange<Int32>?) async throws {
        try await engine.configure(
            viewportID(for: axis),
            slicePosition: normalizedPositions[axis] ?? 0.5,
            window: window
        )
    }

    func scheduleMPRRenderAll() {
        for viewport in mprViewportIDs {
            scheduleRender(for: viewport)
        }
    }

    func configureMPRSlab(_ configuration: ClinicalSlabConfiguration? = nil) async throws {
        let base = configuration ?? ClinicalSlabConfiguration(thickness: Int(slabThickness))
        qualityScheduler.setBaseSlabSteps(base.steps)
        let effectiveSteps = Int(round(Float(base.steps) * qualityScheduler.currentParameters.mprSlabStepsFactor))
        let resolved = ClinicalSlabConfiguration(thickness: base.thickness,
                                                 steps: max(effectiveSteps, 1))
        for viewport in mprViewportIDs {
            try await engine.configure(viewport,
                                       slabThickness: resolved.thickness,
                                       slabSteps: resolved.steps)
        }
    }

    func configureVolumeWindow(_ window: ClosedRange<Int32>?) async throws {
        try await engine.configure(volumeViewportID, window: window)
    }

    func resetVolumeCamera() {
        volumeCameraTarget = SIMD3<Float>(repeating: 0.5)
        volumeCameraOffset = SIMD3<Float>(0, 0, 2)
        volumeCameraUp = SIMD3<Float>(0, 1, 0)
    }

    func configureVolumeCamera() async throws {
        try await engine.configure(
            volumeViewportID,
            camera: Camera(
                position: volumeCameraTarget + volumeCameraOffset,
                target: volumeCameraTarget,
                up: volumeCameraUp,
                fieldOfView: 45,
                projectionType: .perspective
            )
        )
    }

    func configureVolumeRenderQuality() async throws {
        let parameters = qualityScheduler.currentParameters
        let samplingStep = max(parameters.volumeSamplingStep, 1)
        try await engine.configure(volumeViewportID,
                                   samplingDistance: 1 / samplingStep,
                                   quality: parameters.qualityTier)
    }

    func applyRenderQualityAndSchedule() async {
        guard datasetApplied else {
            logger.warning("Skipping render quality application because datasetApplied=false")
            return
        }
        var scheduleVolume = false
        var scheduleMPR = false

        do {
            try await configureVolumeRenderQuality()
            scheduleVolume = true
        } catch {
            recordError(error, for: volumeViewportID)
            logger.error("Failed to apply volume render quality state volumeViewportID=\(volumeViewportID)", error: error)
        }

        let base = ClinicalSlabConfiguration(thickness: Int(slabThickness))
        qualityScheduler.setBaseSlabSteps(base.steps)
        let effectiveSteps = Int(round(Float(base.steps) * qualityScheduler.currentParameters.mprSlabStepsFactor))
        let resolved = ClinicalSlabConfiguration(thickness: base.thickness,
                                                 steps: max(effectiveSteps, 1))
        var mprFailures: [(ViewportID, any Error)] = []
        for viewport in mprViewportIDs {
            do {
                try await engine.configure(viewport,
                                           slabThickness: resolved.thickness,
                                           slabSteps: resolved.steps)
            } catch {
                mprFailures.append((viewport, error))
                logger.error("Failed to apply MPR slab state viewport=\(viewportName(for: viewport))", error: error)
            }
        }
        if mprFailures.isEmpty {
            scheduleMPR = true
        } else {
            for (viewport, error) in mprFailures {
                recordError(error, for: viewport)
            }
        }

        if scheduleVolume {
            scheduleRender(for: volumeViewportID)
        }
        if scheduleMPR {
            scheduleMPRRenderAll()
        }
    }

    @discardableResult
    func scheduleRender(for viewport: ViewportID) -> Task<Void, Never>? {
        guard datasetApplied else {
            logger.warning("Skipping render schedule viewport=\(viewportName(for: viewport)) datasetApplied=false")
            return nil
        }
        let generation = (renderGenerations[viewport] ?? 0) &+ 1
        renderGenerations[viewport] = generation
        renderTasks[viewport]?.cancel()
        let now = CFAbsoluteTimeGetCurrent()
        updateDebugSnapshot(for: viewport) { snapshot in
            snapshot = ClinicalViewportDebugSnapshot(
                viewportID: snapshot.viewportID,
                viewportName: snapshot.viewportName,
                viewportType: viewportTypeName(for: viewport),
                renderMode: renderModeName(for: viewport),
                datasetHandle: datasetHandleLabel(for: viewport),
                volumeTextureLabel: snapshot.volumeTextureLabel,
                outputTextureLabel: snapshot.outputTextureLabel,
                lastPassExecuted: "scheduleRender",
                presentationStatus: "scheduled",
                lastError: nil,
                lastRenderRequestTime: now,
                lastRenderCompletionTime: snapshot.lastRenderCompletionTime,
                lastPresentationTime: snapshot.lastPresentationTime
            )
        }
        logger.info("Scheduling viewport render viewport=\(viewportName(for: viewport)) generation=\(generation) type=\(viewportTypeName(for: viewport)) mode=\(renderModeName(for: viewport))")
        let task = Task { [weak self] in
            guard let self else { return }
            await self.render(viewport: viewport, generation: generation)
        }
        renderTasks[viewport] = task
        return task
    }

    func render(viewport: ViewportID, generation: UInt64) async {
#if DEBUG
        if viewport == volumeViewportID {
            await assertVolumeViewportConfigured()
        }
#endif
        logger.debug("Starting viewport render viewport=\(viewportName(for: viewport)) generation=\(generation)")
        updateDebugSnapshot(for: viewport) { snapshot in
            snapshot = ClinicalViewportDebugSnapshot(
                viewportID: snapshot.viewportID,
                viewportName: snapshot.viewportName,
                viewportType: viewportTypeName(for: viewport),
                renderMode: renderModeName(for: viewport),
                datasetHandle: datasetHandleLabel(for: viewport),
                volumeTextureLabel: snapshot.volumeTextureLabel,
                outputTextureLabel: snapshot.outputTextureLabel,
                lastPassExecuted: "engine.render",
                presentationStatus: "rendering",
                lastError: nil,
                lastRenderRequestTime: snapshot.lastRenderRequestTime,
                lastRenderCompletionTime: snapshot.lastRenderCompletionTime,
                lastPresentationTime: snapshot.lastPresentationTime
            )
        }
        do {
            let frame = try await engine.render(viewport)
            var shouldReleaseLease = frame.outputTextureLease != nil
            defer {
                if shouldReleaseLease {
                    frame.outputTextureLease?.release()
                }
            }
            try renderGraph.validateFrame(frame)
            guard !Task.isCancelled, renderGenerations[viewport] == generation else {
                return
            }
            let renderCompletedAt = CFAbsoluteTimeGetCurrent()
            updateDebugSnapshot(for: viewport) { snapshot in
                snapshot = ClinicalViewportDebugSnapshot(
                    viewportID: snapshot.viewportID,
                    viewportName: snapshot.viewportName,
                    viewportType: viewportTypeName(for: viewport),
                    renderMode: renderModeName(for: viewport),
                    datasetHandle: datasetHandleLabel(for: viewport),
                    volumeTextureLabel: snapshot.volumeTextureLabel,
                    outputTextureLabel: frame.texture.label,
                    lastPassExecuted: frame.route.primaryPass?.profilingName,
                    presentationStatus: "presenting",
                    lastError: nil,
                    lastRenderRequestTime: snapshot.lastRenderRequestTime,
                    lastRenderCompletionTime: renderCompletedAt,
                    lastPresentationTime: snapshot.lastPresentationTime
                )
            }
            logger.info("Rendered viewport frame viewport=\(viewportName(for: viewport)) generation=\(generation) route=\(frame.route.profilingName) pass=\(frame.route.primaryPass?.profilingName ?? "unknown") texture=\(frame.texture.label ?? "nil") size=\(frame.texture.width)x\(frame.texture.height) pixelFormat=\(frame.texture.pixelFormat)")
            let presentationTime = try present(frame, generation: generation)
            shouldReleaseLease = false
            recordTiming(frame.metadata,
                         for: viewport,
                         presentationTime: presentationTime)
            clearError(for: viewport)
            let presentedAt = CFAbsoluteTimeGetCurrent()
            updateDebugSnapshot(for: viewport) { snapshot in
                snapshot = ClinicalViewportDebugSnapshot(
                    viewportID: snapshot.viewportID,
                    viewportName: snapshot.viewportName,
                    viewportType: viewportTypeName(for: viewport),
                    renderMode: renderModeName(for: viewport),
                    datasetHandle: datasetHandleLabel(for: viewport),
                    volumeTextureLabel: snapshot.volumeTextureLabel,
                    outputTextureLabel: frame.texture.label,
                    lastPassExecuted: frame.route.presentationPass?.profilingName,
                    presentationStatus: "presented",
                    lastError: nil,
                    lastRenderRequestTime: snapshot.lastRenderRequestTime,
                    lastRenderCompletionTime: snapshot.lastRenderCompletionTime,
                    lastPresentationTime: presentedAt
                )
            }
        } catch {
            guard !Task.isCancelled, renderGenerations[viewport] == generation else {
                return
            }
            recordError(error, for: viewport)
            updateDebugSnapshot(for: viewport) { snapshot in
                snapshot = ClinicalViewportDebugSnapshot(
                    viewportID: snapshot.viewportID,
                    viewportName: snapshot.viewportName,
                    viewportType: viewportTypeName(for: viewport),
                    renderMode: renderModeName(for: viewport),
                    datasetHandle: datasetHandleLabel(for: viewport),
                    volumeTextureLabel: snapshot.volumeTextureLabel,
                    outputTextureLabel: snapshot.outputTextureLabel,
                    lastPassExecuted: "renderFailed",
                    presentationStatus: "failed",
                    lastError: errorDescription(error),
                    lastRenderRequestTime: snapshot.lastRenderRequestTime,
                    lastRenderCompletionTime: snapshot.lastRenderCompletionTime,
                    lastPresentationTime: snapshot.lastPresentationTime
                )
            }
            logger.error("Viewport render failed viewport=\(viewportName(for: viewport)) generation=\(generation)", error: error)
        }
    }

    @discardableResult
    func present(_ frame: RenderFrame, generation: UInt64? = nil) throws -> CFAbsoluteTime {
        let presentationPass = frame.route.presentationPass
        logger.debug("Presenting viewport frame viewport=\(viewportName(for: frame.viewportID)) route=\(frame.route.profilingName) pass=\(presentationPass?.profilingName ?? "unknown") texture=\(frame.texture.label ?? "nil") size=\(frame.texture.width)x\(frame.texture.height) pixelFormat=\(frame.texture.pixelFormat)")
        let surface: MetalViewportSurface?
        switch frame.viewportID {
        case axialViewportID:
            surface = axialSurface
        case coronalViewportID:
            surface = coronalSurface
        case sagittalViewportID:
            surface = sagittalSurface
        case volumeViewportID:
            surface = volumeSurface
        default:
            surface = nil
        }
        try renderGraph.validatePresentationSurface(for: frame, surfaceExists: surface != nil)
        guard let surface else {
            throw RenderGraphError.missingPresentationSurface(frame.viewportID)
        }

        switch presentationPass?.kind {
        case .presentation:
            return try surface.present(frame,
                                       presentationToken: generation)

        case .mprPresentation:
            guard let mprFrame = frame.mprFrame else {
                throw RenderGraphError.passProducedNoFrame(frame.viewportID, .mprReslice)
            }
            let transform = presentationTransform(for: frame.viewportID, frame: mprFrame)
            logger.debug("Using MPR presentation transform viewport=\(viewportName(for: frame.viewportID)) orientation=\(transform?.orientation.rawValue ?? 0) flipHorizontal=\(transform?.flipHorizontal == true) flipVertical=\(transform?.flipVertical == true)")
            return try surface.present(mprFrame: mprFrame,
                                       window: windowLevel.range,
                                       transform: transform,
                                       presentationToken: generation)

        case .none:
            throw RenderGraphError.unmappedViewportRoute(frame.route.viewportType)

        case .volumeRaycast, .mprReslice, .overlay:
            throw RenderGraphError.invalidViewportConfiguration(
                frame.viewportID,
                reason: "Presentation pass cannot be \(presentationPass?.kind.profilingName ?? "unknown")."
            )
        }
    }

    func recordTiming(_ metadata: FrameMetadata,
                      for viewport: ViewportID,
                      presentationTime: CFAbsoluteTime?) {
        var updated = metadata
        updated.presentTime = presentationTime
        viewportTimings[viewport] = updated
        latestTimingSnapshot = ClinicalViewportTimingSnapshot(
            renderTime: viewportTimings.values.compactMap(\.renderTime).max(),
            presentationTime: viewportTimings.values.compactMap(\.presentTime).max(),
            uploadTime: viewportTimings.values.compactMap(\.uploadTime).max()
        )
    }

    func surface(for viewport: ViewportID) -> MetalViewportSurface? {
        switch viewport {
        case axialViewportID:
            return axialSurface
        case coronalViewportID:
            return coronalSurface
        case sagittalViewportID:
            return sagittalSurface
        case volumeViewportID:
            return volumeSurface
        default:
            return nil
        }
    }

    func normalizedPositionUpdates(from point: CGPoint,
                                   in axis: MTKCore.Axis) -> [(MTKCore.Axis, Float)] {
        let x = clampNormalized(Float(point.x))
        let y = clampNormalized(Float(point.y))
        let texture = displayTransform(for: axis).textureCoordinates(forScreen: SIMD2<Float>(x, y))
        switch axis {
        case .axial:
            return [(.sagittal, clampNormalized(texture.x)), (.coronal, clampNormalized(texture.y))]
        case .coronal:
            return [(.sagittal, clampNormalized(texture.x)), (.axial, clampNormalized(texture.y))]
        case .sagittal:
            return [(.coronal, clampNormalized(texture.x)), (.axial, clampNormalized(texture.y))]
        }
    }

    func setNormalizedPosition(_ position: Float, for axis: MTKCore.Axis) -> Bool {
        let next = clampNormalized(position)
        guard normalizedPositions[axis] != next else {
            return false
        }
        normalizedPositions[axis] = next
        return true
    }

    func setCrosshairOffset(_ offset: CGPoint, for axis: MTKCore.Axis) -> Bool {
        guard crosshairOffsets[axis] != offset else {
            return false
        }
        crosshairOffsets[axis] = offset
        return true
    }

    func perpendicularAxes(to axis: MTKCore.Axis) -> [MTKCore.Axis] {
        switch axis {
        case .axial:
            return [.coronal, .sagittal]
        case .coronal:
            return [.axial, .sagittal]
        case .sagittal:
            return [.axial, .coronal]
        }
    }

    func rebuildAllCrosshairOffsets() {
        crosshairOffsets = Self.centeredCrosshairOffsets
        for axis in MTKCore.Axis.allCases {
            let offset = crosshairOffset(for: axis, positions: normalizedPositions)
            _ = setCrosshairOffset(offset, for: axis)
        }
    }

    func drawableSize(for axis: MTKCore.Axis) -> CGSize {
        let size = surface(for: axis).drawablePixelSize
        return CGSize(width: max(size.width, 1), height: max(size.height, 1))
    }

    func clampNormalized(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    func updateDebugSnapshot(for viewport: ViewportID,
                             mutate: (inout ClinicalViewportDebugSnapshot) -> Void) {
        var snapshot = debugSnapshots[viewport]
            ?? Self.makeDebugSnapshot(viewportID: viewport,
                                      viewportName: viewportName(for: viewport),
                                      viewportType: viewportTypeName(for: viewport),
                                      renderMode: renderModeName(for: viewport))
        mutate(&snapshot)
        debugSnapshots[viewport] = snapshot
    }

    static func makeDebugSnapshot(viewportID: ViewportID,
                                  viewportName: String,
                                  viewportType: String,
                                  renderMode: String) -> ClinicalViewportDebugSnapshot {
        ClinicalViewportDebugSnapshot(viewportID: viewportID,
                                      viewportName: viewportName,
                                      viewportType: viewportType,
                                      renderMode: renderMode)
    }

    func viewportName(for viewport: ViewportID) -> String {
        switch viewport {
        case axialViewportID:
            return "Axial"
        case coronalViewportID:
            return "Coronal"
        case sagittalViewportID:
            return "Sagittal"
        case volumeViewportID:
            return "Volume"
        default:
            return "Viewport"
        }
    }

    func viewportTypeName(for viewport: ViewportID) -> String {
        if viewport == volumeViewportID {
            return volumeViewportMode.viewportType.debugName
        }
        if let axis = viewportAxesByID[viewport] {
            return "mpr(\(axis.debugName))"
        }
        return "unknown"
    }

    func renderModeName(for viewport: ViewportID) -> String {
        if viewport == volumeViewportID {
            return volumeViewportMode.rawValue
        }
        return "single"
    }

    func presentationTransform(for viewport: ViewportID,
                               frame: MPRTextureFrame) -> MPRDisplayTransform? {
        guard let axis = viewportAxesByID[viewport] else { return nil }
        let transform = displayTransform(for: frame.planeGeometry, axis: axis)
        displayTransformsByAxis[axis] = transform
        return transform
    }

    func planeAxis(for axis: MTKCore.Axis) -> MPRPlaneAxis {
        clinicalPlaneAxis(for: axis)
    }

    func fallbackPlaneGeometry(for axis: MTKCore.Axis) -> MPRPlaneGeometry {
        clinicalFallbackPlaneGeometry(for: axis)
    }

    func textureCoordinates(for axis: MTKCore.Axis,
                            positions: [MTKCore.Axis: Float]) -> SIMD2<Float> {
        switch axis {
        case .axial:
            return SIMD2<Float>(positions[.sagittal] ?? 0.5,
                                positions[.coronal] ?? 0.5)
        case .coronal:
            return SIMD2<Float>(positions[.sagittal] ?? 0.5,
                                positions[.axial] ?? 0.5)
        case .sagittal:
            return SIMD2<Float>(positions[.coronal] ?? 0.5,
                                positions[.axial] ?? 0.5)
        }
    }

    func crosshairOffset(for axis: MTKCore.Axis,
                         positions: [MTKCore.Axis: Float]) -> CGPoint {
        let size = drawableSize(for: axis)
        let texture = textureCoordinates(for: axis, positions: positions)
        let screen = displayTransform(for: axis).screenCoordinates(forTexture: texture)
        return CGPoint(x: CGFloat(screen.x - 0.5) * size.width,
                       y: CGFloat(screen.y - 0.5) * size.height)
    }

    func datasetHandleLabel(for viewport: ViewportID) -> String? {
        return sharedResourceHandle.map(String.init(describing:))
    }

    func errorDescription(_ error: (any Error)?) -> String? {
        guard let error else { return nil }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    func refreshAggregateRenderError() {
        let priorityOrder = [volumeViewportID, axialViewportID, coronalViewportID, sagittalViewportID]
        for viewport in priorityOrder {
            if let error = lastRenderErrors[viewport] {
                lastRenderError = error
                return
            }
        }
        lastRenderError = nil
    }

    func recordError(_ error: any Error, for viewport: ViewportID) {
        lastRenderErrors[viewport] = error
        updateDebugSnapshot(for: viewport) { snapshot in
            snapshot = ClinicalViewportDebugSnapshot(
                viewportID: snapshot.viewportID,
                viewportName: snapshot.viewportName,
                viewportType: viewportTypeName(for: viewport),
                renderMode: renderModeName(for: viewport),
                datasetHandle: snapshot.datasetHandle,
                volumeTextureLabel: snapshot.volumeTextureLabel,
                outputTextureLabel: snapshot.outputTextureLabel,
                lastPassExecuted: "error",
                presentationStatus: "failed",
                lastError: errorDescription(error),
                lastRenderRequestTime: snapshot.lastRenderRequestTime,
                lastRenderCompletionTime: snapshot.lastRenderCompletionTime,
                lastPresentationTime: snapshot.lastPresentationTime
            )
        }
        refreshAggregateRenderError()
    }

    func clearError(for viewport: ViewportID) {
        lastRenderErrors.removeValue(forKey: viewport)
        refreshAggregateRenderError()
    }

    func handlePresentationFailure(_ error: any Error, for viewport: ViewportID) {
        recordError(error, for: viewport)
        updateDebugSnapshot(for: viewport) { snapshot in
            snapshot = ClinicalViewportDebugSnapshot(
                viewportID: snapshot.viewportID,
                viewportName: snapshot.viewportName,
                viewportType: viewportTypeName(for: viewport),
                renderMode: renderModeName(for: viewport),
                datasetHandle: snapshot.datasetHandle,
                volumeTextureLabel: snapshot.volumeTextureLabel,
                outputTextureLabel: snapshot.outputTextureLabel,
                lastPassExecuted: "presentationFailed",
                presentationStatus: "failed",
                lastError: errorDescription(error),
                lastRenderRequestTime: snapshot.lastRenderRequestTime,
                lastRenderCompletionTime: snapshot.lastRenderCompletionTime,
                lastPresentationTime: CFAbsoluteTimeGetCurrent()
            )
        }
        logger.error("Viewport presentation failed viewport=\(viewportName(for: viewport))", error: error)
    }

#if DEBUG
    func assertVolumeViewportConfigured() async {
        let viewportType: ViewportType
        do {
            viewportType = try await engine.viewportType(for: volumeViewportID)
        } catch {
            preconditionFailure("Volume viewport descriptor missing for \(volumeViewportID): \(error)")
        }
        precondition(viewportType == volumeViewportMode.viewportType,
                     "Volume viewport misconfigured. Expected \(volumeViewportMode.viewportType.debugName), got \(viewportType.debugName)")
    }
#endif

    static func volumeTransferFunction(from transferFunction: TransferFunction) -> VolumeTransferFunction {
        let colourPoints = transferFunction
            .sanitizedColourPoints()
            .map { point in
                VolumeTransferFunction.ColourControlPoint(
                    intensity: point.dataValue + transferFunction.shift,
                    colour: SIMD4<Float>(
                        point.colourValue.r,
                        point.colourValue.g,
                        point.colourValue.b,
                        point.colourValue.a
                    )
                )
            }
        let opacityPoints = transferFunction
            .sanitizedAlphaPoints()
            .map { point in
                VolumeTransferFunction.OpacityControlPoint(
                    intensity: point.dataValue + transferFunction.shift,
                    opacity: point.alphaValue
                )
            }
        return VolumeTransferFunction(opacityPoints: opacityPoints,
                                      colourPoints: colourPoints)
    }

#if DEBUG
    func logResourceSharingDiagnostics() async {
        let diagnostics = await engine.resourceSharingDiagnostics(for: allViewportIDs)
        let textureIdentifiers = Set(diagnostics.map(\.textureObjectIdentifier))
        let handles = Set(diagnostics.map(\.handle))
        let metrics = await engine.resourceMetrics()
        let expectedVolumeBytes = sharedResourceHandle?.metadata.estimatedBytes ?? 0

        print("ClinicalViewportGrid resource diagnostics:")
        for diagnostic in diagnostics {
            let metadata = diagnostic.metadata
            print("  viewport=\(diagnostic.viewportID) handle=\(diagnostic.handle) texture=\(diagnostic.textureObjectIdentifier) dimensions=\(metadata.dimensions.width)x\(metadata.dimensions.height)x\(metadata.dimensions.depth) estimatedBytes=\(metadata.estimatedBytes)")
        }
        print("  volumeTextureBytes=\(metrics.breakdown.volumeTextures) expectedSingleVolumeBytes=\(expectedVolumeBytes)")

        assert(diagnostics.count == allViewportIDs.count,
               "Expected diagnostics for all clinical viewports.")
        assert(handles.count == 1,
               "ClinicalViewportGrid expected one shared VolumeResourceHandle.")
        assert(textureIdentifiers.count == 1,
               "ClinicalViewportGrid expected all viewports to resolve to one MTLTexture.")
        assert(expectedVolumeBytes == 0 || metrics.breakdown.volumeTextures == expectedVolumeBytes,
               "ClinicalViewportGrid expected one-volume GPU memory footprint.")
    }
#endif

    func safeNormalize(_ value: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(value)
        guard length.isFinite, length > Float.ulpOfOne else {
            return fallback
        }
        return value / length
    }
}

private func defaultClinicalMPRDisplayTransform(for axis: MTKCore.Axis) -> MPRDisplayTransform {
    MPRDisplayTransformFactory.makeTransform(for: clinicalFallbackPlaneGeometry(for: axis),
                                            axis: clinicalPlaneAxis(for: axis))
}

private func clinicalPlaneAxis(for axis: MTKCore.Axis) -> MPRPlaneAxis {
    switch axis {
    case .axial:
        return .z
    case .coronal:
        return .y
    case .sagittal:
        return .x
    }
}

private func clinicalFallbackPlaneGeometry(for axis: MTKCore.Axis) -> MPRPlaneGeometry {
    switch axis {
    case .axial:
        return .canonical(axis: .z)
    case .coronal:
        return .canonical(axis: .y)
    case .sagittal:
        return .canonical(axis: .x)
    }
}
