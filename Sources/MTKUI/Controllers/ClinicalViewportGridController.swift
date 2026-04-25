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
    public let engine: MTKRenderingEngine
    public let axialViewportID: ViewportID
    public let coronalViewportID: ViewportID
    public let sagittalViewportID: ViewportID
    public let volumeViewportID: ViewportID

    public let axialSurface: MetalViewportSurface
    public let coronalSurface: MetalViewportSurface
    public let sagittalSurface: MetalViewportSurface
    public let volumeSurface: MetalViewportSurface

    @Published public internal(set) var windowLevel = WindowLevelShift(window: 400, level: 40)
    @Published public internal(set) var slabThickness: Double = 3
    @Published public internal(set) var normalizedPositions: [MTKCore.Axis: Float] = ClinicalViewportGridController.centeredNormalizedPositions
    @Published public internal(set) var crosshairOffsets: [MTKCore.Axis: CGPoint] = ClinicalViewportGridController.centeredCrosshairOffsets
    @Published public internal(set) var sharedResourceHandle: VolumeResourceHandle?
    @Published public internal(set) var datasetApplied = false
    @Published public internal(set) var renderQualityState: RenderQualityState = .settled
    @Published public internal(set) var lastRenderErrors: [ViewportID: any Error] = [:]
    @Published public internal(set) var lastRenderError: (any Error)?
    @Published public internal(set) var volumeViewportMode: ClinicalVolumeViewportMode = .dvr
    @Published public internal(set) var latestTimingSnapshot = ClinicalViewportTimingSnapshot()
    @Published public internal(set) var debugSnapshots: [ViewportID: ClinicalViewportDebugSnapshot] = [:]

    var renderTasks: [ViewportID: Task<Void, Never>] = [:]
    var renderGenerations: [ViewportID: UInt64] = [:]
    var viewportTimings: [ViewportID: FrameMetadata] = [:]
    let qualityScheduler = RenderQualityScheduler()
    let renderGraph = ViewportRenderGraph()
    let logger = Logger(category: "ClinicalViewportGridController")
    var qualityStateCancellable: AnyCancellable?
    var committedMPRWindowRange: ClosedRange<Int32>?
    var volumeCameraTarget = SIMD3<Float>(repeating: 0.5)
    var volumeCameraOffset = SIMD3<Float>(0, 0, 2)
    var volumeCameraUp = SIMD3<Float>(0, 1, 0)
    var currentDataset: VolumeDataset?
    var displayTransformsByAxis: [MTKCore.Axis: MPRDisplayTransform] = [:]
    var viewportAxesByID: [ViewportID: MTKCore.Axis] = [:]

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

    /// Uploads one dataset to all four viewports using the engine's shared resource handle.
    ///
    /// All MPR and volume panes receive the same `VolumeResourceHandle`. In debug builds, the
    /// Applies a volume dataset to all viewports, initializes window/level, slab, slice/crosshair and camera state, configures MPR and volume rendering pipelines, updates per-viewport debug snapshots to "ready", and schedules initial renders.
    /// 
    /// This uploads the dataset to the rendering engine (creating a shared resource handle), resets cached display transforms and timing, sets sensible defaults (window/level, centered slice positions, slab thickness, and volume camera), clears prior render errors, configures all MPR slices and volume rendering state, refreshes debug snapshots for every viewport, and enqueues a render for each pane.
    /// - Parameter dataset: The volume dataset to apply; becomes the controller's current dataset and is uploaded to the engine.
    /// - Throws: Any error returned by the engine or by the configuration steps (for example failures when setting the volume, configuring slices, slab, volume window, camera, or render quality).
    public func applyDataset(_ dataset: VolumeDataset) async throws {
        let runningRenderTasks = Array(renderTasks.values)
        runningRenderTasks.forEach { $0.cancel() }
        for task in runningRenderTasks {
            await task.value
        }
        renderTasks.removeAll()
        renderGenerations.removeAll()
        datasetApplied = false

        var uploadedVolume = false
        do {
            let handle = try await engine.setVolume(dataset, for: allViewportIDs)
            uploadedVolume = true
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
            lastRenderErrors.removeAll()
            lastRenderError = nil

            try await configureAllMPRSlices(window: windowLevel.range)
            committedMPRWindowRange = windowLevel.range
            try await configureMPRSlab()
            try await configureVolumeWindow(windowLevel.range)
            try await configureVolumeCamera()
            try await configureVolumeRenderQuality()
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
            scheduleRenderAll()
        } catch {
            if uploadedVolume {
                await engine.clearVolume(for: allViewportIDs)
            }
            sharedResourceHandle = nil
            currentDataset = nil
            displayTransformsByAxis.removeAll()
            viewportTimings.removeAll()
            latestTimingSnapshot = ClinicalViewportTimingSnapshot()
            committedMPRWindowRange = nil
            datasetApplied = false
            lastRenderErrors.removeAll()
            lastRenderError = nil
            throw error
        }
    }

    /// Signals the start of an adaptive-sampling user interaction and applies the resulting render quality.
    /// 
    /// This tells the adaptive-quality scheduler that an interaction has begun, then updates render quality and schedules any necessary renders.
    public func beginAdaptiveSamplingInteraction() async {
        qualityScheduler.beginInteraction()
        await applyRenderQualityAndSchedule()
    }

    /// Marks the end of an adaptive-sampling interaction so the controller can allow render quality to transition back toward its settled/production state.
    public func endAdaptiveSamplingInteraction() async {
        qualityScheduler.endInteraction()
    }

    /// Forces the render-quality scheduler to transition to its settled (final) state, causing the controller to apply the final render-quality settings.
    public func forceFinalRenderQuality() async {
        qualityScheduler.forceSettled()
    }

    /// Applies a transfer function to the volume viewport only.
    ///
    /// This intentionally does not update MPR window/level or MPR presentation state; the volume
    /// Updates the transfer function used to render the 3D volume viewport and schedules a re-render.
    /// - Parameter transferFunction: The transfer function to apply to the volume rendering; pass `nil` to clear it.
    /// - Throws: Any error returned by the rendering engine while configuring the volume viewport.
    public func setTransferFunction(_ transferFunction: TransferFunction?) async throws {
        try await engine.configure(volumeViewportID,
                                   transferFunction: transferFunction.map(Self.volumeTransferFunction))
        scheduleRender(for: volumeViewportID)
    }

    /// Reconfigures the volume viewport to the given mode, validates the engine's resolved descriptor, updates debug state, and schedules a render.
    /// 
    /// If the requested mode is already active this method returns immediately. On change, the engine viewport descriptor is updated and the engine's resolved viewport type is validated; the controller's `volumeViewportMode` and the corresponding debug snapshot are updated. If a dataset is already applied, a forced render is performed and the resulting frame is validated before scheduling a presentation.
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
            snapshot.presentationStatus = "scheduled"
            snapshot.lastError = nil
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

    /// Update the MPR window/level and commit the change if it differs from the current values.
    /// - Parameters:
    ///   - window: Desired window width; values less than 1 are clamped to 1 before applying.
    ///   - level: Desired window level (center).
    /// - Discussion: If the resolved window/level equals the controller's current `windowLevel`, no commit is performed.
    public func setMPRWindowLevel(window: Double, level: Double) async {
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
        let resolved = WindowLevelShift(range: min(resolvedRange.lowerBound, resolvedRange.upperBound)...max(resolvedRange.lowerBound, resolvedRange.upperBound))
        guard resolved != windowLevel else { return }
        windowLevel = resolved
        await commitWindowLevel()
    }

    /// Commits the current MPR window/level to axial, coronal, and sagittal viewports only.
    ///
    /// The controller attempts to configure all three MPR axes before deciding
    /// whether the shared commit succeeded. Any axis-specific failure is stored
    /// Commits the controller's current MPR window range to all three MPR viewports.
    /// 
    /// If the current committed range already matches the controller's window range, this method does nothing. It attempts to configure each MPR axis with the new range; if any axis fails to configure, the method records the corresponding error for that viewport and aborts without updating the committed range or scheduling renders. On success, the committed range is updated and all MPR viewports are scheduled for rendering.
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

    /// Rotates the volume camera by applying a yaw and pitch derived from a screen-space delta.
    ///
    /// Updates the controller's `volumeCameraOffset` and `volumeCameraUp` vectors, reconfigures the volume camera, and schedules a render of the volume viewport. If `screenDelta` components are not finite or the computed rotation is effectively zero, no changes are made. Any error during camera configuration is recorded against the volume viewport.
    /// - Parameters:
    ///   - screenDelta: The pointer/touch movement in screen coordinates whose x component maps to yaw and y component maps to pitch (each scaled by 0.01).
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

    /// Update the crosshair position on the specified MPR axis and schedule rendering for all affected viewports.
    /// 
    /// Sets the controller's normalized slice position(s) based on `normalizedPoint`, updates perpendicular axes' crosshair offsets, commits slice configuration for each changed axis, records any per-viewport errors that occur during configuration, and schedules renders for all viewports affected by the change.
    /// - Parameters:
    ///   - axis: The MPR axis whose plane the `normalizedPoint` is expressed in (axial, coronal, or sagittal).
    ///   - normalizedPoint: A point in the axis plane using normalized coordinates (typically in the 0–1 range); non-finite components are ignored and cause no change.
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

    /// Scrolls the slice position of the specified MPR axis by a normalized delta.
    /// - Parameters:
    ///   - axis: The MPR axis whose slice position will be adjusted.
    ///   - deltaNormalized: The change to apply to the slice position, expressed in normalized coordinates (0.0–1.0).
    public func scrollSlice(axis: MTKCore.Axis, deltaNormalized: Float) async {
        await handleSliceScroll(axis: axis, delta: deltaNormalized)
    }

    /// Set the normalized slice position for an MPR axis, update dependent crosshair offsets, and schedule rendering for affected viewports.
    /// 
    /// If `normalizedPosition` is not finite or is rejected as unchanged, the method returns without side effects. Otherwise it updates stored normalized positions, adjusts perpendicular axes' crosshair offsets, attempts to configure the slice using the current `windowLevel.range`, and schedules a render for the axis' viewport and any affected perpendicular viewports. If slice configuration fails, the error is recorded for the axis' viewport.
    /// - Parameters:
    ///   - axis: The MPR axis whose slice position to set.
    ///   - normalizedPosition: The new slice position in normalized coordinates (0...1).
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

    /// Updates crosshair offsets for axes perpendicular to a changed MPR axis based on a new normalized slice position.
    /// - Parameters:
    ///   - changedAxis: The axis whose slice position changed.
    ///   - newNormalizedPosition: The new normalized slice position for `changedAxis` (0.0–1.0, clamped).
    /// - Returns: An array of axes whose crosshair offsets were changed as a result of the update.
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

    /// Schedules a render for every configured viewport in the grid.
    /// 
    /// This enqueues a render request for each viewport pane so the controller will produce new frames for all viewports.
    public func scheduleRenderAll() {
        for viewport in allViewportIDs {
            _ = scheduleRender(for: viewport)
        }
    }

    /// Schedules a render for every viewport and waits until all scheduled render tasks complete.
    /// - Note: If no render tasks are scheduled, the method returns immediately.
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
        try await configureVolumeRenderQuality()
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
        guard let currentDataset else {
            return displayTransform(for: fallbackPlaneGeometry(for: axis), axis: axis)
        }

        let plane = MPRPlaneGeometryFactory.makePlane(for: currentDataset,
                                                      axis: planeAxis(for: axis),
                                                      slicePosition: normalizedPositions[axis] ?? 0.5)
        return displayTransform(for: plane, axis: axis)
    }

    /// Retrieves the most recently recorded render error for the specified viewport.
    /// - Parameter viewport: The identifier of the viewport to query.
    /// - Returns: The last `Error` recorded for `viewport`, or `nil` if no error has been recorded.
    public func lastRenderError(for viewport: ViewportID) -> (any Error)? {
        lastRenderErrors[viewport]
    }
}
