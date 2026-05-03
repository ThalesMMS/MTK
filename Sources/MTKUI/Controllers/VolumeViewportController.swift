//
//  VolumeViewportController.swift
//  MTKUI
//
//  Adapter-backed controller for MTKUI volume and MPR presentation.
//

import Combine
import CoreGraphics
import Foundation
import Metal
import MTKCore
import simd

/// Main MTKUI controller for presenting and interacting with a volumetric viewport.
///
/// `VolumeViewportController` is the primary entry point for downstream apps integrating MTKUI.
/// It owns a Metal-backed ``MetalViewportSurface`` plus adapter state used to render:
///
/// - 3D volume views (DVR / MIP / MinIP / AIP)
/// - Multi-planar reconstruction (MPR) slice views
///
/// The controller is `@MainActor` isolated. Update properties and call methods from SwiftUI/UI
/// code, or explicitly hop to the main actor.
@MainActor
public final class VolumeViewportController: VolumeViewportControlling, ObservableObject {
    public enum Error: Swift.Error {
        case metalUnavailable
        case datasetNotLoaded
        case transferFunctionUnavailable
        case presentationFailed
    }

    public enum Axis: Int, CaseIterable, Sendable {
        case x = 0
        case y = 1
        case z = 2
    }

    public struct SlabConfiguration: Equatable, Sendable {
        public var thickness: Int
        public var steps: Int

        public init(thickness: Int, steps: Int) {
            self.thickness = Self.snapToOddVoxelCount(thickness)
            self.steps = Self.snapToOddVoxelCount(max(1, steps))
        }

        /// Snap a requested voxel count to a valid odd voxel count suitable for slab/step configuration.
        /// - Parameters:
        ///   - value: The requested voxel count.
        /// - Returns: `0` if `value` is less than or equal to zero; otherwise an odd integer greater than or equal to `1`. If `value` is even, returns the next odd integer (except when `value == Int.max`, in which case returns `Int.max - 1`).
        public static func snapToOddVoxelCount(_ value: Int) -> Int {
            guard value > 0 else { return 0 }
            var clamped = value
            if clamped % 2 == 0 {
                clamped = clamped == Int.max ? max(1, clamped - 1) : clamped + 1
            }
            return max(1, clamped)
        }
    }

    public enum DisplayConfiguration: Equatable, Sendable {
        case volume(method: VolumetricRenderMethod)
        case mpr(axis: Axis, index: Int, blend: VolumetricMPRBlendMode, slab: SlabConfiguration?)
    }

    public enum VolumeDisplayConfiguration: Equatable, Sendable {
        case method(VolumetricRenderMethod)

        var displayConfiguration: DisplayConfiguration {
            switch self {
            case .method(let method):
                return .volume(method: method)
            }
        }
    }

    public static let manualHotspots: [VolumetricHotspot] = [
        VolumetricHotspot(
            identifier: "volume_compute",
            description: "`MetalVolumeRenderingAdapter` performs per-frame volume ray marching through the compute pipeline",
            suggestion: "Profile request scheduling, transfer preparation, and command-buffer execution before adding another rendering path."
        ),
        VolumetricHotspot(
            identifier: "mpr_resample",
            description: "`MetalMPRAdapter` rebuilds MPR slabs as Metal compute output before display",
            suggestion: "Cache unchanged slice requests and avoid resubmitting identical MPR planes."
        ),
        VolumetricHotspot(
            identifier: "histogram_wwl",
            description: "Window/level suggestions can require histogram or statistics work before renderer updates",
            suggestion: "Use MTKCore histogram/statistics compute helpers when UI controls need fresh intensity summaries."
        )
    ]

    public let viewportSurface: MetalViewportSurface
    public var surface: any ViewportPresenting { viewportSurface }
    public let device: any MTLDevice
    public let commandQueue: any MTLCommandQueue
    public let statePublisher = VolumetricStatePublisher()

    public var cameraState: VolumetricCameraState { statePublisher.cameraState }
    public var sliceState: VolumetricSliceState { statePublisher.sliceState }
    public var windowLevelState: VolumetricWindowLevelState { statePublisher.windowLevelState }
    public var adaptiveSamplingEnabled: Bool { statePublisher.adaptiveSamplingEnabled }
    public var renderQualityState: RenderQualityState { statePublisher.qualityState }
    @Published public internal(set) var datasetApplied = false
    @Published public internal(set) var datasetIntensityRange: ClosedRange<Int32>?
    public internal(set) var lastRenderError: (any Swift.Error)?

    public var transferFunctionDomain: ClosedRange<Float>? {
        if let transferFunction {
            return transferFunction.minimumValue...transferFunction.maximumValue
        }
        return dataset.map { Float($0.intensityRange.lowerBound)...Float($0.intensityRange.upperBound) }
    }

    let logger = Logger(category: "Volumetric.Controller")

    let volumeRenderer: any VolumeRenderingPortExtended
    let mprRenderer: MetalMPRAdapter
    let mprVolumeTextureCache: MPRVolumeTextureCache
    let qualityScheduler: RenderQualityScheduler
    var renderTask: Task<Void, Never>?
    var renderGeneration: UInt64 = 0
    var qualityStateCancellable: AnyCancellable?
    let mprFrameCache = MPRFrameCache<MPRPlaneAxis>()

    var dataset: VolumeDataset?
    var geometry: DICOMGeometry?
    var currentDisplay: DisplayConfiguration?
    var transferFunction: TransferFunction?
    var huWindow: VolumetricHUWindowMapping?
    var mprHuWindow: ClosedRange<Int32>?
    var currentVolumeMethod: VolumetricRenderMethod = .dvr
    var currentMprAxis: Axis?
    var currentMprBlend: VolumetricMPRBlendMode = .single
    var currentMprSlab: SlabConfiguration?
    var mprNormalizedPosition: Float = 0.5
    var mprPlaneIndex = 0
    var mprEuler = SIMD3<Float>.zero
    var baseSamplingStep: Float = 512
    var renderMode: VolumetricRenderMode = .active
    var lightingEnabled = true
    var projectionsUseTransferFunction = true
    var projectionDensityGate: ClosedRange<Float>?
    var projectionHuGate: (enabled: Bool, min: Int32, max: Int32) = (false, 0, 0)
    var huGateEnabled = false
    var defaultTransferShift: Float = 0

    var cameraTarget = SIMD3<Float>(repeating: 0.5)
    var cameraOffset = SIMD3<Float>(0, 0, 2)
    var cameraUpVector = SIMD3<Float>(0, 1, 0)
    var fallbackWorldUp = SIMD3<Float>(0, 1, 0)
    var fallbackCameraTarget = SIMD3<Float>(repeating: 0.5)
    var initialCameraTarget = SIMD3<Float>(repeating: 0.5)
    var initialCameraOffset = SIMD3<Float>(0, 0, 2)
    var initialCameraUp = SIMD3<Float>(0, 1, 0)
    var cameraDistanceLimits: ClosedRange<Float> = 0.1...16
    var volumeWorldCenter = SIMD3<Float>(repeating: 0.5)
    var volumeBoundingRadius: Float = 0.8660254
    var patientLongitudinalAxis = SIMD3<Float>(0, 0, 1)
    let maximumPanDistanceMultiplier: Float = 1.5
    let defaultCameraDistanceFactor: Float = 2.5

    public convenience init(device: (any MTLDevice)? = nil, surface: MetalViewportSurface? = nil) throws {
        try self.init(device: device,
                      surface: surface,
                      mprVolumeTextureCache: nil)
    }

    init(device: (any MTLDevice)? = nil,
         surface: MetalViewportSurface? = nil,
         mprVolumeTextureCache: MPRVolumeTextureCache?) throws {
        let resolvedDevice: any MTLDevice
        if let device {
            resolvedDevice = device
        } else if let systemDevice = MTLCreateSystemDefaultDevice() {
            resolvedDevice = systemDevice
        } else {
            throw Error.metalUnavailable
        }
        guard let queue = resolvedDevice.makeCommandQueue() else {
            throw Error.metalUnavailable
        }

        self.device = resolvedDevice
        self.commandQueue = queue
        self.viewportSurface = try surface ?? MetalViewportSurface(device: resolvedDevice,
                                                                   commandQueue: queue)
        self.mprVolumeTextureCache = mprVolumeTextureCache ?? MPRVolumeTextureCache()
        self.qualityScheduler = RenderQualityScheduler(baseSamplingStep: 512)
        self.volumeRenderer = try MetalVolumeRenderingAdapter(device: resolvedDevice,
                                                              commandQueue: queue)
        self.mprRenderer = try MetalMPRAdapter(device: resolvedDevice,
                                               commandQueue: queue)

        viewportSurface.onDrawableSizeChange = { [weak self] _ in
            self?.invalidateMPRCache()
            self?.scheduleRender()
        }

        qualityStateCancellable = qualityScheduler.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                self.statePublisher.recordRenderQualityState(state)
                self.objectWillChange.send()
                if state == .settled {
                    self.scheduleRender()
                }
            }

        resetCameraState(radius: volumeBoundingRadius,
                         normal: SIMD3<Float>(0, 0, 1),
                         up: SIMD3<Float>(0, 1, 0))
    }

    deinit {
        renderTask?.cancel()
        qualityStateCancellable?.cancel()
    }

    /// Apply a volume dataset to the controller and initialize rendering state for the new data.
    /// 
    /// This stores the provided dataset, invalidates MPR caches, establishes geometry and volume bounds,
    /// resolves and records the HU window mapping (also used for MPR), resets the camera to fit the volume,
    /// marks the dataset as applied, ensures a default display configuration if none is set, and schedules a render.
    /// - Parameter dataset: The volume dataset to apply; replaces any previously applied dataset.
    public func applyDataset(_ dataset: VolumeDataset) async {
        guard self.dataset != dataset || datasetApplied == false else { return }
        self.dataset = dataset
        datasetIntensityRange = dataset.intensityRange
        mprVolumeTextureCache.invalidate()
        invalidateMPRCache()
        geometry = makeGeometry(from: dataset)
        datasetApplied = true

        let resolvedWindow = huWindow ?? VolumetricHUWindowMapping.makeHuWindowMapping(
            minHU: dataset.recommendedWindow?.lowerBound ?? dataset.intensityRange.lowerBound,
            maxHU: dataset.recommendedWindow?.upperBound ?? dataset.intensityRange.upperBound,
            datasetRange: dataset.intensityRange,
            transferDomain: transferFunctionDomain
        )
        huWindow = resolvedWindow
        mprHuWindow = resolvedWindow.minHU...resolvedWindow.maxHU
        statePublisher.recordWindowLevelState(resolvedWindow)

        updateVolumeBounds(for: dataset)
        if let geometry {
            resetCameraState(radius: volumeBoundingRadius,
                             normal: safeNormalize(geometry.iopNorm, fallback: SIMD3<Float>(0, 0, 1)),
                             up: safeNormalize(geometry.iopCol, fallback: SIMD3<Float>(0, 1, 0)))
        } else {
            resetCameraState(radius: volumeBoundingRadius,
                             normal: SIMD3<Float>(0, 0, 1),
                             up: SIMD3<Float>(0, 1, 0))
        }
        currentDisplay = currentDisplay ?? .volume(method: currentVolumeMethod)
        scheduleRender()
    }

    /// Updates the controller's active display configuration (volume or MPR) and applies the corresponding controller state changes.
    /// 
    /// If no dataset has been applied, the call is ignored and no state is changed.
    /// 
    /// For a volume configuration, updates the active volume rendering method. For an MPR configuration, updates the active MPR axis, slice index/normalized position, blend mode, and slab configuration; invalidates cached MPR data for the affected axis, aligns the camera to the selected MPR plane, records slice state, and schedules a render.
    /// - Parameters:
    ///   - configuration: The new display configuration to apply.
    public func setDisplayConfiguration(_ configuration: DisplayConfiguration) async {
        guard datasetApplied else {
            logger.warning("Attempted to configure display before dataset load")
            return
        }
        currentDisplay = configuration
        switch configuration {
        case let .volume(method):
            currentVolumeMethod = method
        case let .mpr(axis, index, blend, slab):
            currentMprAxis = axis
            currentMprBlend = blend
            currentMprSlab = slab
            qualityScheduler.setBaseSlabSteps((slab ?? SlabConfiguration(thickness: 1, steps: 1)).steps)
            mprPlaneIndex = clampedIndex(for: axis, index: index)
            mprNormalizedPosition = normalizedPosition(for: axis, index: mprPlaneIndex)
            mprEuler = .zero
            invalidateMPRCache(axis: axis.mprPlaneAxis)
            alignCameraToCurrentMprPlane()
            statePublisher.recordSliceState(axis: axis, normalized: mprNormalizedPosition)
        }
        scheduleRender()
    }

    /// Provide the current dataset's voxel dimensions and spacing as SIMD vectors.
    /// - Returns: A tuple where `dimension` is (width, height, depth) as `SIMD3<Int32>` and `resolution` is (spacing.x, spacing.y, spacing.z) as `SIMD3<Float>`, or `nil` if no dataset is available.
    public func metadata() -> (dimension: SIMD3<Int32>, resolution: SIMD3<Float>)? {
        guard let dataset else { return nil }
        return (
            SIMD3<Int32>(Int32(dataset.dimensions.width),
                         Int32(dataset.dimensions.height),
                         Int32(dataset.dimensions.depth)),
            SIMD3<Float>(Float(dataset.spacing.x),
                         Float(dataset.spacing.y),
                         Float(dataset.spacing.z))
        )
    }

    /// Sets the active transfer function used for volume rendering and schedules a re-render.
    /// - Parameter transferFunction: The transfer function to apply; pass `nil` to clear any currently applied transfer function.
    public func setTransferFunction(_ transferFunction: TransferFunction?) async throws {
        self.transferFunction = transferFunction
        scheduleRender()
    }

    /// Set the active volume rendering method and schedule a re-render.
    /// - Parameters:
    ///   - method: The volume rendering method to use; updates the controller's active method and, if the current display is a volume configuration, updates that display to use this method.
    public func setVolumeMethod(_ method: VolumetricRenderMethod) async {
        currentVolumeMethod = method
        if case .volume = currentDisplay {
            currentDisplay = .volume(method: method)
        }
        scheduleRender()
    }

    /// Applies a built-in volume rendering preset to the controller's transfer function and schedules a render.
    /// - Parameter preset: The built-in preset to apply; updates the controller's transfer function and default transfer shift (if the preset provides one), then schedules a redraw.
    public func setPreset(_ preset: VolumeRenderingBuiltinPreset) async {
        transferFunction = VolumeTransferFunctionLibrary.transferFunction(for: preset)
        defaultTransferShift = transferFunction?.shift ?? defaultTransferShift
        scheduleRender()
    }

    /// Updates the active transfer function's intensity shift and schedules a rerender.
    /// - Parameters:
    ///   - shift: New shift value applied to the currently set transfer function. If no transfer function is set, the call has no effect.
    public func setShift(_ shift: Float) async {
        guard var transferFunction else { return }
        transferFunction.shift = shift
        self.transferFunction = transferFunction
        scheduleRender()
    }

    /// Enables or disables the HU (Hounsfield unit) gate used during projection rendering and triggers a new render.
    /// - Parameter enabled: `true` to enable HU gating, `false` to disable it.
    public func setHuGate(enabled: Bool) async {
        huGateEnabled = enabled
        scheduleRender()
    }

    /// Updates the Hounsfield-unit window mapping used for volume rendering and MPR presentation.
    /// - Parameters:
    ///   - window: The new HU window mapping (defines min and max HU) to apply. This updates the active window state, records the window/level into the state publisher, and either presents a cached MPR frame if available or schedules a new render.
    public func setHuWindow(_ window: VolumetricHUWindowMapping) async {
        huWindow = window
        mprHuWindow = window.minHU...window.maxHU
        statePublisher.recordWindowLevelState(window)
        if presentCachedMPRFrameIfPossible() {
            return
        }
        scheduleRender()
    }

    /// Update the controller's render mode and start or stop rendering accordingly.
    /// - Parameters:
    ///   - mode: The desired render mode; when `.active`, a render is scheduled, otherwise any in-flight render task is cancelled.
    public func setRenderMode(_ mode: VolumetricRenderMode) async {
        renderMode = mode
        if mode == .active {
            scheduleRender()
        } else {
            renderTask?.cancel()
        }
    }

    /// Updates the current transfer function's shift.
    /// - Parameter shift: The shift value to apply to the current transfer function's mapping.
    public func updateTransferFunctionShift(_ shift: Float) async {
        await setShift(shift)
    }

    /// Enable or disable adaptive sampling for subsequent renders.
    /// 
    /// When disabling adaptive sampling this forces the render-quality scheduler to settle immediately; the controller's state is updated and a render is scheduled.
    /// - Parameter enabled: `true` to enable adaptive sampling, `false` to disable it.
    public func setAdaptiveSampling(_ enabled: Bool) async {
        statePublisher.setAdaptiveSamplingFlag(enabled)
        if !enabled {
            qualityScheduler.forceSettled()
        }
        scheduleRender()
    }

    /// Begins an interactive adaptive-sampling session and schedules a render when adaptive sampling is enabled.
    /// - Note: No action is taken if adaptive sampling is disabled.
    public func beginAdaptiveSamplingInteraction() async {
        guard adaptiveSamplingEnabled else { return }
        qualityScheduler.beginInteraction()
        scheduleRender()
    }

    /// Ends the current adaptive-sampling interaction if adaptive sampling is enabled.
    /// 
    /// When adaptive sampling is active, signals the render-quality scheduler to end user interaction so the scheduler can transition back toward settled sampling. If adaptive sampling is disabled, this call has no effect.
    public func endAdaptiveSamplingInteraction() async {
        guard adaptiveSamplingEnabled else { return }
        qualityScheduler.endInteraction()
    }

    /// Forces the render-quality scheduler to move to its settled (final) state.
    /// 
    /// Signals that any in-progress adaptive quality transitions should complete immediately so subsequent renders use the settled final quality.
    public func forceFinalRenderQuality() async {
        qualityScheduler.forceSettled()
    }

    /// Updates the controller's selected volume rendering method.
    /// - Parameter method: The volume rendering method to apply.
    @available(*, deprecated, message: "Use setVolumeMethod(_:) instead")
    public func setRenderMethod(_ method: VolumetricRenderMethod) async {
        await setVolumeMethod(method)
    }

    /// Sets whether lighting is applied to volume and MPR renders.
    /// 
    /// When changed, schedules a new render so the updated lighting state takes effect.
    /// - Parameter enabled: `true` to enable lighting, `false` to disable.
    public func setLighting(enabled: Bool) async {
        lightingEnabled = enabled
        scheduleRender()
    }

    /// Sets the base sampling step used for volume rendering and requests a re-render.
    /// 
    /// The provided `step` is clamped to a minimum of `1` before being applied. This updates the render quality scheduler's base sampling step and schedules a new render.
    /// - Parameter step: Desired base sampling step; values less than `1` will be treated as `1`.
    public func setSamplingStep(_ step: Float) async {
        baseSamplingStep = max(step, 1)
        qualityScheduler.setBaseSamplingStep(baseSamplingStep)
        scheduleRender()
    }

    /// Enable or disable applying the current transfer function to projection renderings.
    /// 
    /// Setting this updates the controller's projection rendering mode and schedules a re-render to apply the change.
    /// - Parameter enabled: `true` to apply the active transfer function to projection renders; `false` to render projections without the transfer function.
    public func setProjectionsUseTransferFunction(_ enabled: Bool) async {
        projectionsUseTransferFunction = enabled
        scheduleRender()
    }

    /// Updates the projection density gate to the closed range defined by the provided endpoints and schedules a render.
    /// - Parameters:
    ///   - floor: One endpoint of the projection density gate (interpreted as a normalized density in [0, 1]); the function will order this value with `ceil`.
    ///   - ceil: The other endpoint of the projection density gate (interpreted as a normalized density in [0, 1]); the function will order this value with `floor`.
    public func setProjectionDensityGate(floor: Float, ceil: Float) async {
        projectionDensityGate = min(floor, ceil)...max(floor, ceil)
        scheduleRender()
    }

    /// Set the projection Hounsfield-unit (HU) gate and trigger a render.
    /// - Parameters:
    ///   - enabled: Whether projection HU gating is applied.
    ///   - min: The lower HU bound for the gate.
    ///   - max: The upper HU bound for the gate.
    public func setProjectionHuGate(enabled: Bool, min: Int32, max: Int32) async {
        projectionHuGate = (enabled, Swift.min(min, max), Swift.max(min, max))
        scheduleRender()
    }

    /// Sets the multislice planar reconstruction (MPR) blending mode and updates presentation state.
    /// 
    /// If an MPR axis is currently active, the cached MPR for that axis is invalidated and the active display configuration is updated to reflect the new blend mode (preserving current axis, plane index, and slab). A render is scheduled after the change.
    /// - Parameter mode: The new MPR blending mode to apply.
    public func setMprBlend(_ mode: VolumetricMPRBlendMode) async {
        currentMprBlend = mode
        if let axis = currentMprAxis {
            invalidateMPRCache(axis: axis.mprPlaneAxis)
            currentDisplay = .mpr(axis: axis,
                                  index: mprPlaneIndex,
                                  blend: mode,
                                  slab: currentMprSlab)
        }
        scheduleRender()
    }

    /// Updates the MPR slab configuration and triggers cache invalidation and a render.
    /// 
    /// Sets the current multi-planar reconstruction (MPR) slab using the provided thickness and sampling steps, updates the render-quality scheduler's base slab steps, invalidates cached MPR data (for the active axis if one is selected, otherwise for all axes), updates the active display configuration when applicable, and schedules a render.
    /// - Parameters:
    ///   - thickness: Slab thickness in voxels (will be normalized by the slab configuration constructor).
    ///   - steps: Number of sampling steps through the slab (will be normalized by the slab configuration constructor).
    public func setMprSlab(thickness: Int, steps: Int) async {
        currentMprSlab = SlabConfiguration(thickness: thickness, steps: steps)
        qualityScheduler.setBaseSlabSteps(currentMprSlab?.steps ?? 1)
        if let axis = currentMprAxis {
            invalidateMPRCache(axis: axis.mprPlaneAxis)
            currentDisplay = .mpr(axis: axis,
                                  index: mprPlaneIndex,
                                  blend: currentMprBlend,
                                  slab: currentMprSlab)
        } else {
            invalidateMPRCache()
        }
        scheduleRender()
    }

    /// Updates the HU window used for MPR rendering and triggers presentation or a re-render as needed.
    /// - Parameters:
    ///   - min: The minimum HU (Hounsfield unit) value for the MPR window.
    ///   - max: The maximum HU (Hounsfield unit) value for the MPR window.
    public func setMprHuWindow(min: Int32, max: Int32) async {
        mprHuWindow = Swift.min(min, max)...Swift.max(min, max)
        if presentCachedMPRFrameIfPossible() {
            return
        }
        scheduleRender()
    }

    /// Set the current MPR plane position for the specified axis using a normalized coordinate in [0, 1].
    /// If the dataset has not been applied or the provided axis does not match the controller's current MPR axis, the call is ignored.
    /// - Parameters:
    ///   - axis: The axis (x, y, or z) whose MPR plane will be set.
    ///   - normalized: The desired plane position normalized to the volume extent; values outside [0, 1] are clamped.
    /// - Discussion: This updates the controller's active MPR plane index and normalized position, invalidates cached MPR data for the axis, updates the current display to the corresponding MPR configuration, aligns the camera to the selected plane, records the new slice state, and schedules a render.
    public func setMprPlane(axis: Axis, normalized: Float) async {
        guard datasetApplied, currentMprAxis == axis else { return }
        let clamped = VolumetricMath.clampFloat(normalized, lower: 0, upper: 1)
        mprPlaneIndex = clampedIndex(for: axis, index: indexPosition(for: axis, normalized: clamped))
        mprNormalizedPosition = normalizedPosition(for: axis, index: mprPlaneIndex)
        invalidateMPRCache(axis: axis.mprPlaneAxis)
        currentDisplay = .mpr(axis: axis,
                              index: mprPlaneIndex,
                              blend: currentMprBlend,
                              slab: currentMprSlab)
        alignCameraToCurrentMprPlane()
        statePublisher.recordSliceState(axis: axis, normalized: mprNormalizedPosition)
        scheduleRender()
    }

    /// Moves the current MPR plane along the specified axis by a normalized offset.
    /// - Parameters:
    ///   - axis: The axis (x, y, or z) along which to translate the MPR plane.
    ///   - deltaNormalized: Change to apply to the plane's normalized position; added to the current normalized position.
    public func translate(axis: Axis, deltaNormalized: Float) async {
        await setMprPlane(axis: axis, normalized: mprNormalizedPosition + deltaNormalized)
    }

    /// Rotates the current MPR plane around the specified axis and updates rendering state.
    /// - Parameters:
    ///   - axis: The MPR axis (`.x`, `.y`, or `.z`) to rotate around.
    ///   - radians: The angle, in radians, to add to the plane's Euler rotation for that axis.
    public func rotate(axis: Axis, radians: Float) async {
        guard datasetApplied else { return }
        switch axis {
        case .x:
            mprEuler.x += radians
        case .y:
            mprEuler.y += radians
        case .z:
            mprEuler.z += radians
        }
        if let axis = currentMprAxis {
            invalidateMPRCache(axis: axis.mprPlaneAxis)
        } else {
            invalidateMPRCache()
        }
        alignCameraToCurrentMprPlane()
        scheduleRender()
    }

    /// Resets view state to sensible defaults for the currently applied dataset and schedules a render.
    /// 
    /// Updates the HU window to a mapping derived from the dataset intensity range (or the active transfer-function domain when available), records the new window/level state, resets the transfer function's shift to the controller's default if a transfer function is present, resets the camera to its initial pose, aligns the camera to the current MPR plane, and schedules a render.
    /// - Note: Does nothing if no dataset has been applied.
    public func resetView() async {
        guard datasetApplied else { return }
        if let dataset {
            let range = dataset.intensityRange
            let mapping = VolumetricHUWindowMapping.makeHuWindowMapping(
                minHU: range.lowerBound,
                maxHU: range.upperBound,
                datasetRange: range,
                transferDomain: transferFunctionDomain
            )
            huWindow = mapping
            mprHuWindow = mapping.minHU...mapping.maxHU
            statePublisher.recordWindowLevelState(mapping)
        }
        if var transferFunction {
            transferFunction.shift = defaultTransferShift
            self.transferFunction = transferFunction
        }
        await resetCamera()
        alignCameraToCurrentMprPlane()
        scheduleRender()
    }

    /// Resets the camera to its initial target, offset, and up vector.
    /// Updates published camera state and schedules a render with the restored camera parameters.
    public func resetCamera() async {
        cameraTarget = initialCameraTarget
        cameraOffset = initialCameraOffset
        cameraUpVector = initialCameraUp
        publishCameraState()
        scheduleRender()
    }

    /// Rotates the camera according to a screen-space drag and updates the published camera state.
    /// - Parameter screenDelta: Screen-space displacement where `x` controls yaw (horizontal rotation) and `y` controls pitch (vertical rotation); the values are interpreted as motion and converted internally into small rotation angles.
    public func rotateCamera(screenDelta: SIMD2<Float>) async {
        let yaw = screenDelta.x * 0.01
        let pitch = screenDelta.y * 0.01
        let threshold = Float.ulpOfOne
        guard abs(yaw) > threshold || abs(pitch) > threshold else { return }

        var offset = cameraOffset
        var up = safeNormalize(cameraUpVector, fallback: fallbackWorldUp)

        if abs(yaw) > threshold {
            let yawAxis = safeNormalize(patientLongitudinalAxis, fallback: fallbackWorldUp)
            let yawRotation = simd_quatf(angle: yaw, axis: yawAxis)
            offset = yawRotation.act(offset)
            up = yawRotation.act(up)
        }

        var forward = safeNormalize(-offset, fallback: SIMD3<Float>(0, 0, -1))
        let right = safeNormalize(simd_cross(forward, up), fallback: safePerpendicular(to: forward))

        if abs(pitch) > threshold {
            let pitchRotation = simd_quatf(angle: pitch, axis: right)
            offset = pitchRotation.act(offset)
            up = pitchRotation.act(up)
            forward = safeNormalize(-offset, fallback: forward)
        }

        cameraOffset = clampCameraOffset(offset)
        cameraUpVector = up
        publishCameraState()
        scheduleRender()
    }

    /// Applies a combined roll and pitch rotation to the current camera orientation.
    /// - Parameters:
    ///   - roll: Rotation in radians about the camera's forward axis (positive rotates the up vector toward the right). Small values near zero are ignored.
    ///   - pitch: Rotation in radians about the camera's right axis (positive pitches the camera upward). Small values near zero are ignored.
    /// - Note: Updates the controller's camera offset and up vector, clamps the offset to valid bounds, publishes the new camera state, and schedules a render.
    public func tiltCamera(roll: Float, pitch: Float) async {
        let threshold = Float.ulpOfOne
        guard abs(roll) > threshold || abs(pitch) > threshold else { return }

        var offset = cameraOffset
        var up = cameraUpVector
        let forward = safeNormalize(-offset, fallback: SIMD3<Float>(0, 0, -1))
        var right = safeNormalize(simd_cross(forward, up), fallback: safePerpendicular(to: forward))

        if abs(roll) > threshold {
            let rollRotation = simd_quatf(angle: roll, axis: forward)
            up = rollRotation.act(up)
            right = rollRotation.act(right)
        }

        if abs(pitch) > threshold {
            let pitchRotation = simd_quatf(angle: pitch, axis: right)
            offset = pitchRotation.act(offset)
            up = pitchRotation.act(up)
        }

        cameraOffset = clampCameraOffset(offset)
        cameraUpVector = safeNormalize(up, fallback: fallbackWorldUp)
        publishCameraState()
        scheduleRender()
    }

    /// Translates the camera target parallel to the current view plane according to a screen-space displacement.
    /// 
    /// Updates the controller's camera target and up vector, publishes the new camera state, and schedules a re-render.
    /// - Parameters:
    ///   - screenDelta: Screen-space displacement where `x` is the horizontal movement and `y` is the vertical movement; the vector is converted to a world-space translation before applying to the camera target.
    public func panCamera(screenDelta: SIMD2<Float>) async {
        let threshold = Float.ulpOfOne
        guard abs(screenDelta.x) > threshold || abs(screenDelta.y) > threshold else { return }

        var up = safeNormalize(cameraUpVector, fallback: fallbackWorldUp)
        let forward = safeNormalize(-cameraOffset, fallback: SIMD3<Float>(0, 0, -1))
        let right = safeNormalize(simd_cross(forward, up), fallback: safePerpendicular(to: forward))
        up = safeNormalize(simd_cross(right, forward), fallback: up)

        let distance = max(simd_length(cameraOffset), Float.ulpOfOne)
        let scales = screenSpaceScale(distance: distance)
        let translation = (-screenDelta.x * scales.horizontal) * right + (screenDelta.y * scales.vertical) * up
        cameraTarget = clampCameraTarget(cameraTarget + translation)
        cameraUpVector = up
        publishCameraState()
        scheduleRender()
    }

    /// Moves the camera along its view direction by the specified distance.
    /// 
    /// Positive values move the camera toward the scene (dolly in); negative values move it away (dolly out). Non-finite or values within machine epsilon are ignored.
    /// - Parameters:
    ///   - delta: Signed distance in world units to translate the camera along its forward vector. The resulting camera offset is clamped to the valid range; the updated camera state is published and a render is scheduled.
    public func dollyCamera(delta: Float) async {
        guard delta.isFinite, abs(delta) > Float.ulpOfOne else { return }
        let forward = safeNormalize(-cameraOffset, fallback: SIMD3<Float>(0, 0, -1))
        cameraOffset = clampCameraOffset(cameraOffset - forward * delta)
        publishCameraState()
        scheduleRender()
    }

    /// Renders a production-quality volume frame for explicit snapshot/export workflows.
    ///
    /// Renders a final-quality snapshot frame of the currently configured volume display.
    ///
    /// The returned frame is a GPU-native `MTLTexture`. Callers that need PNG or
    /// CGImage output should pass the texture through `TextureSnapshotExporter`.
    /// The controller's current display configuration determines the effective
    /// volume rendering method used for the snapshot.
    /// - Returns: A `VolumeRenderFrame` containing the rendered image and associated metadata.
    /// - Throws: `Error.datasetNotLoaded` if no dataset has been applied; rethrows any error produced by the underlying volume renderer.
    public func renderVolumeSnapshotFrame() async throws -> VolumeRenderFrame {
        guard let dataset else {
            throw Error.datasetNotLoaded
        }
        let display = currentDisplay ?? .volume(method: currentVolumeMethod)
        let method: VolumetricRenderMethod
        switch display {
        case let .volume(activeMethod):
            method = activeMethod
        case .mpr:
            method = currentVolumeMethod
        }

        try await applyVolumeRendererState(for: dataset)
        let request = makeVolumeRenderRequest(dataset: dataset,
                                              method: method,
                                              forceFinalQuality: true)
        return try await (volumeRenderer as any VolumeRenderingPort).renderFrame(using: request)
    }

    @_spi(Testing)
    public var debugRenderedTexture: (any MTLTexture)? {
        viewportSurface.presentedTexture
    }

    @_spi(Testing)
    public var debugCachedMPRFrameCount: Int {
        mprFrameCache.entryCount
    }

    /// Get the object identifier of the cached MPR plane texture for the specified MPR axis.
    /// - Parameter axis: The MPR axis to query.
    /// - Returns: The `ObjectIdentifier` of the cached texture for that axis, or `nil` if no cached frame exists.
    @_spi(Testing)
    public func debugCachedMPRFrameTextureIdentifier(axis: Axis) -> ObjectIdentifier? {
        guard let texture = mprFrameCache.storedFrame(for: axis.mprPlaneAxis)?.texture else { return nil }
        return ObjectIdentifier(texture as AnyObject)
    }

    @_spi(Testing)
    public var debugCachedMPRVolumeTextureIdentifier: ObjectIdentifier? {
        mprVolumeTextureCache.textureIdentifier
    }

    @_spi(Testing)
    public var debugSamplingStep: Float {
        guard adaptiveSamplingEnabled else { return max(baseSamplingStep, 1) }
        return max(1, qualityScheduler.currentParameters.volumeSamplingStep)
    }

    @_spi(Testing)
    public var debugVolumeMethodID: Int32 {
        currentVolumeMethod.methodID
    }

    @_spi(Testing)
    public var debugMprBlendID: Int32 {
        Int32(currentMprBlend.rawValue)
    }

    @_spi(Testing)
    public var debugTransferFunctionShift: Float? {
        transferFunction?.shift
    }

    /// Resolve the effective volume transfer function for a given dataset.
    /// - Parameter dataset: The dataset to resolve the transfer function for.
    /// - Returns: The `VolumeTransferFunction` that the controller would use for rendering the provided dataset, resolved from the controller's current transfer-function state (including any shift) and the dataset's intensity domain.
    @_spi(Testing)
    public func debugResolvedVolumeTransferFunction(for dataset: VolumeDataset) -> VolumeTransferFunction {
        makeVolumeTransferFunction(for: dataset)
    }

    @_spi(Testing)
    public var debugLightingEnabled: Bool {
        lightingEnabled
    }

    @_spi(Testing)
    public var debugProjectionDensityGate: ClosedRange<Float>? {
        projectionDensityGate
    }

    @_spi(Testing)
    public var debugProjectionHuGate: (enabled: Bool, min: Int32, max: Int32) {
        projectionHuGate
    }

    @_spi(Testing)
    public var debugHuWindow: VolumetricHUWindowMapping? {
        huWindow
    }
}
