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

@MainActor
final class MPRVolumeTextureCache {
    private var cached: (dataset: VolumeDataset, texture: any MTLTexture)?
    private var pending: (dataset: VolumeDataset, task: Task<any MTLTexture, Error>)?

    func texture(for dataset: VolumeDataset,
                 device: any MTLDevice,
                 commandQueue: any MTLCommandQueue) async throws -> any MTLTexture {
        if let cached,
           cached.dataset == dataset {
            return cached.texture
        }
        if let pending,
           pending.dataset == dataset {
            let texture = try await pending.task.value
            if self.pending?.dataset == dataset {
                cached = (dataset, texture)
                self.pending = nil
            }
            return texture
        }

        let task = Task { @MainActor in
            try await VolumeTextureFactory(dataset: dataset)
                .generateAsync(device: device, commandQueue: commandQueue)
        }
        pending = (dataset, task)
        do {
            let texture = try await task.value
            if pending?.dataset == dataset {
                cached = (dataset, texture)
                pending = nil
            }
            return texture
        } catch {
            if pending?.dataset == dataset {
                pending = nil
            }
            throw error
        }
    }

    func invalidate() {
        cached = nil
        pending = nil
    }

    var textureIdentifier: ObjectIdentifier? {
        guard let texture = cached?.texture else { return nil }
        return ObjectIdentifier(texture as AnyObject)
    }
}

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
    public private(set) var datasetApplied = false
    public private(set) var lastRenderError: (any Swift.Error)?

    public var transferFunctionDomain: ClosedRange<Float>? {
        if let transferFunction {
            return transferFunction.minimumValue...transferFunction.maximumValue
        }
        return dataset.map { Float($0.intensityRange.lowerBound)...Float($0.intensityRange.upperBound) }
    }

    let logger = Logger(category: "Volumetric.Controller")

    private let volumeRenderer: any VolumeRenderingPortExtended
    private let mprRenderer: MetalMPRAdapter
    private let mprVolumeTextureCache: MPRVolumeTextureCache
    private let qualityScheduler: RenderQualityScheduler
    private var renderTask: Task<Void, Never>?
    private var renderGeneration: UInt64 = 0
    private var qualityStateCancellable: AnyCancellable?
    private let mprFrameCache = MPRFrameCache<MPRPlaneAxis>()

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
    }

    public func applyDataset(_ dataset: VolumeDataset) async {
        guard self.dataset != dataset || datasetApplied == false else { return }
        self.dataset = dataset
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

    public func setTransferFunction(_ transferFunction: TransferFunction?) async throws {
        self.transferFunction = transferFunction
        scheduleRender()
    }

    /// Sets the volume rendering method; this is the preferred API for DVR/MIP/MinIP/Avg changes.
    public func setVolumeMethod(_ method: VolumetricRenderMethod) async {
        currentVolumeMethod = method
        if case .volume = currentDisplay {
            currentDisplay = .volume(method: method)
        }
        scheduleRender()
    }

    public func setPreset(_ preset: VolumeRenderingBuiltinPreset) async {
        transferFunction = VolumeTransferFunctionLibrary.transferFunction(for: preset)
        defaultTransferShift = transferFunction?.shift ?? defaultTransferShift
        scheduleRender()
    }

    public func setShift(_ shift: Float) async {
        guard var transferFunction else { return }
        transferFunction.shift = shift
        self.transferFunction = transferFunction
        scheduleRender()
    }

    public func setHuGate(enabled: Bool) async {
        huGateEnabled = enabled
        scheduleRender()
    }

    public func setHuWindow(_ window: VolumetricHUWindowMapping) async {
        huWindow = window
        mprHuWindow = window.minHU...window.maxHU
        statePublisher.recordWindowLevelState(window)
        if presentCachedMPRFrameIfPossible() {
            return
        }
        scheduleRender()
    }

    public func setRenderMode(_ mode: VolumetricRenderMode) async {
        renderMode = mode
        if mode == .active {
            scheduleRender()
        } else {
            renderTask?.cancel()
        }
    }

    public func updateTransferFunctionShift(_ shift: Float) async {
        await setShift(shift)
    }

    public func setAdaptiveSampling(_ enabled: Bool) async {
        statePublisher.setAdaptiveSamplingFlag(enabled)
        if !enabled {
            qualityScheduler.forceSettled()
        }
        scheduleRender()
    }

    public func beginAdaptiveSamplingInteraction() async {
        guard adaptiveSamplingEnabled else { return }
        qualityScheduler.beginInteraction()
        scheduleRender()
    }

    public func endAdaptiveSamplingInteraction() async {
        guard adaptiveSamplingEnabled else { return }
        qualityScheduler.endInteraction()
    }

    public func forceFinalRenderQuality() async {
        qualityScheduler.forceSettled()
    }

    /// Deprecated compatibility alias; use ``setVolumeMethod(_:)`` for volume method changes.
    @available(*, deprecated, message: "Use setVolumeMethod(_:) instead")
    public func setRenderMethod(_ method: VolumetricRenderMethod) async {
        await setVolumeMethod(method)
    }

    public func setLighting(enabled: Bool) async {
        lightingEnabled = enabled
        scheduleRender()
    }

    public func setSamplingStep(_ step: Float) async {
        baseSamplingStep = max(step, 1)
        qualityScheduler.setBaseSamplingStep(baseSamplingStep)
        scheduleRender()
    }

    public func setProjectionsUseTransferFunction(_ enabled: Bool) async {
        projectionsUseTransferFunction = enabled
        scheduleRender()
    }

    public func setProjectionDensityGate(floor: Float, ceil: Float) async {
        projectionDensityGate = min(floor, ceil)...max(floor, ceil)
        scheduleRender()
    }

    public func setProjectionHuGate(enabled: Bool, min: Int32, max: Int32) async {
        projectionHuGate = (enabled, min, max)
        scheduleRender()
    }

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

    public func setMprHuWindow(min: Int32, max: Int32) async {
        mprHuWindow = min...max
        if presentCachedMPRFrameIfPossible() {
            return
        }
        scheduleRender()
    }

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

    public func translate(axis: Axis, deltaNormalized: Float) async {
        await setMprPlane(axis: axis, normalized: mprNormalizedPosition + deltaNormalized)
    }

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

    public func resetCamera() async {
        cameraTarget = initialCameraTarget
        cameraOffset = initialCameraOffset
        cameraUpVector = initialCameraUp
        publishCameraState()
        scheduleRender()
    }

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
        var right = safeNormalize(simd_cross(forward, up), fallback: safePerpendicular(to: forward))

        if abs(pitch) > threshold {
            let pitchRotation = simd_quatf(angle: pitch, axis: right)
            offset = pitchRotation.act(offset)
            up = pitchRotation.act(up)
            forward = safeNormalize(-offset, fallback: forward)
            right = safeNormalize(simd_cross(forward, up), fallback: safePerpendicular(to: forward))
            _ = right
        }

        cameraOffset = clampCameraOffset(offset)
        cameraUpVector = up
        publishCameraState()
        scheduleRender()
    }

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

    public func dollyCamera(delta: Float) async {
        guard delta.isFinite, abs(delta) > Float.ulpOfOne else { return }
        let forward = safeNormalize(-cameraOffset, fallback: SIMD3<Float>(0, 0, -1))
        cameraOffset = clampCameraOffset(cameraOffset - forward * delta)
        publishCameraState()
        scheduleRender()
    }

    /// Renders a production-quality volume frame for explicit snapshot/export workflows.
    ///
    /// The returned frame is still a GPU-native `MTLTexture`; callers that need
    /// PNG/CGImage output must pass it through `TextureSnapshotExporter` at the
    /// explicit export boundary.
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

private extension VolumeViewportController {
    var effectiveQualityState: RenderQualityState {
        adaptiveSamplingEnabled ? qualityScheduler.state : .settled
    }

    func scheduleRender() {
        guard renderMode == .active, datasetApplied else { return }
        renderGeneration &+= 1
        let generation = renderGeneration
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            await self?.render(generation: generation)
        }
    }

    func render(generation: UInt64) async {
        guard let dataset, renderMode == .active else { return }
        let display = currentDisplay ?? .volume(method: currentVolumeMethod)
        let started = Date()
        var telemetryQualityState = effectiveQualityState

        do {
            switch display {
            case let .volume(method):
                let plan = try await makeVolumeTextureRenderPlan(dataset: dataset, method: method)
                telemetryQualityState = plan.qualityState
                RenderingTelemetry.volumeRenderScheduled(qualityState: plan.qualityState)
                let frame = try await renderVolumeFrame(using: plan)
                guard !Task.isCancelled, generation == renderGeneration else { return }
                lastRenderError = nil
                try viewportSurface.present(frame: frame)
                RenderingTelemetry.volumeRenderCompleted(duration: Date().timeIntervalSince(started),
                                                        qualityState: plan.qualityState)
            case let .mpr(axis, index, blend, slab):
                RenderingTelemetry.mprRenderScheduled(blend: blend.coreBlend,
                                                     qualityState: telemetryQualityState)
                let frame = try await renderMpr(dataset: dataset,
                                                axis: axis,
                                                index: index,
                                                blend: blend,
                                                slab: slab)
                guard !Task.isCancelled, generation == renderGeneration else { return }
                try viewportSurface.present(mprFrame: frame,
                                            window: resolvedMPRWindow(for: dataset))
                lastRenderError = nil
                RenderingTelemetry.mprRenderCompleted(duration: Date().timeIntervalSince(started),
                                                      blend: blend.coreBlend,
                                                      qualityState: telemetryQualityState)
            }
        } catch {
            guard !Task.isCancelled, generation == renderGeneration else { return }
            lastRenderError = error
            switch display {
            case .volume:
                RenderingTelemetry.volumeRenderFailed(duration: Date().timeIntervalSince(started),
                                                      qualityState: telemetryQualityState,
                                                      reason: .runtimeError,
                                                      error: error)
            case .mpr:
                RenderingTelemetry.mprRenderFailed(duration: Date().timeIntervalSince(started),
                                                  qualityState: telemetryQualityState,
                                                  reason: .runtimeError,
                                                  error: error)
            }
            logger.error("Render failed", error: error)
        }
    }

    struct VolumeTextureRenderPlan {
        let request: VolumeRenderRequest
        let qualityState: RenderQualityState
    }

    func makeVolumeTextureRenderPlan(dataset: VolumeDataset,
                                     method: VolumetricRenderMethod) async throws -> VolumeTextureRenderPlan {
        try await applyVolumeRendererState(for: dataset)
        let request = makeVolumeRenderRequest(dataset: dataset, method: method)
        return VolumeTextureRenderPlan(request: request,
                                       qualityState: qualityState(for: request))
    }

    func renderVolumeFrame(using plan: VolumeTextureRenderPlan) async throws -> VolumeRenderFrame {
        try await (volumeRenderer as any VolumeRenderingPort).renderFrame(using: plan.request)
    }

    func renderVolumeSnapshot(dataset: VolumeDataset,
                              method: VolumetricRenderMethod) async throws -> CGImage {
        // Snapshot/export requests production quality without mutating interaction tracking.
        try await applyVolumeRendererState(for: dataset)
        let request = makeVolumeRenderRequest(dataset: dataset,
                                              method: method,
                                              forceFinalQuality: true)
        let frame = try await (volumeRenderer as any VolumeRenderingPort).renderFrame(using: request)
        return try await TextureSnapshotExporter().makeCGImage(from: frame)
    }

    func applyVolumeRendererState(for dataset: VolumeDataset) async throws {
        if let huWindow {
            try await volumeRenderer.setHuWindow(min: huWindow.minHU, max: huWindow.maxHU)
        }
        try await volumeRenderer.setLighting(lightingEnabled)
        if projectionHuGate.enabled || huGateEnabled {
            let minHU = projectionHuGate.enabled ? projectionHuGate.min : (huWindow?.minHU ?? dataset.intensityRange.lowerBound)
            let maxHU = projectionHuGate.enabled ? projectionHuGate.max : (huWindow?.maxHU ?? dataset.intensityRange.upperBound)
            try await volumeRenderer.setHuGate(enabled: true, minHU: minHU, maxHU: maxHU)
        } else {
            try await volumeRenderer.setHuGate(enabled: false, minHU: 0, maxHU: 0)
        }
    }

    func makeVolumeRenderRequest(dataset: VolumeDataset,
                                 method: VolumetricRenderMethod,
                                 forceFinalQuality: Bool = false) -> VolumeRenderRequest {
        let viewport = clampedViewportSize()
        let transfer = makeVolumeTransferFunction(for: dataset)
        let parameters = forceFinalQuality
            ? RenderQualityParameters(volumeSamplingStep: max(baseSamplingStep, 1),
                                      mprSlabStepsFactor: 1,
                                      qualityTier: .production)
            : qualityScheduler.currentParameters
        let samplingStep = adaptiveSamplingEnabled || forceFinalQuality
            ? max(1, parameters.volumeSamplingStep)
            : max(baseSamplingStep, 1)
        return VolumeRenderRequest(
            dataset: dataset,
            transferFunction: transfer,
            viewportSize: CGSize(width: viewport.width, height: viewport.height),
            camera: VolumeRenderRequest.Camera(
                position: cameraTarget + cameraOffset,
                target: cameraTarget,
                up: cameraUpVector,
                fieldOfView: 60,
                projectionType: .perspective
            ),
            samplingDistance: 1 / samplingStep,
            compositing: method.compositing,
            quality: forceFinalQuality ? .production : parameters.qualityTier
        )
    }

    func qualityState(for request: VolumeRenderRequest) -> RenderQualityState {
        switch request.quality {
        case .production:
            return .settled
        case .interactive, .preview:
            return .interacting
        }
    }

    func renderMpr(dataset: VolumeDataset,
                   axis: Axis,
                   index: Int,
                   blend: VolumetricMPRBlendMode,
                   slab: SlabConfiguration?) async throws -> MPRTextureFrame {
        let planeIndex = clampedIndex(for: axis, index: index)
        let plane = makeDrawableSizedMprPlane(makeMprPlane(axis: axis, index: planeIndex))
        let effectiveSlabConfig = effectiveMPRSlabConfiguration(for: slab)
        let signature = MPRFrameSignature(planeGeometry: plane,
                                          slabThickness: effectiveSlabConfig.thickness,
                                          slabSteps: effectiveSlabConfig.steps,
                                          blend: blend.coreBlend)
        let axisKey = axis.mprPlaneAxis

        if let frame = mprFrameCache.cachedFrame(for: axisKey, matching: signature) {
            return frame
        }

        let volumeTexture = try await mprVolumeTexture(for: dataset)
        let frame = try await mprRenderer.makeSlabTexture(dataset: dataset,
                                                          volumeTexture: volumeTexture,
                                                          plane: plane,
                                                          thickness: effectiveSlabConfig.thickness,
                                                          steps: effectiveSlabConfig.steps,
                                                          blend: blend.coreBlend)
        try Task.checkCancellation()
        mprFrameCache.store(frame,
                            for: axisKey,
                            signature: signature)
        return frame
    }

    func clampedViewportSize() -> (width: Int, height: Int) {
        let size = viewportSurface.drawablePixelSize
        return (
            max(1, Int(size.width.rounded())),
            max(1, Int(size.height.rounded()))
        )
    }

    func mprVolumeTexture(for dataset: VolumeDataset) async throws -> any MTLTexture {
        try await mprVolumeTextureCache.texture(for: dataset,
                                                device: device,
                                                commandQueue: commandQueue)
    }

    func resolvedMPRWindow(for dataset: VolumeDataset) -> ClosedRange<Int32> {
        mprHuWindow ?? huWindow.map { $0.minHU...$0.maxHU } ?? dataset.intensityRange
    }

    func presentCachedMPRFrameIfPossible() -> Bool {
        guard let dataset,
              case let .mpr(axis, index, blend, slab) = currentDisplay ?? .volume(method: currentVolumeMethod),
              let signature = currentMPRFrameSignature(axis: axis,
                                                       index: index,
                                                       blend: blend,
                                                       slab: slab),
              let frame = mprFrameCache.cachedFrame(for: axis.mprPlaneAxis,
                                                    matching: signature) else {
            return false
        }

        do {
            try viewportSurface.present(mprFrame: frame,
                                        window: resolvedMPRWindow(for: dataset))
            return true
        } catch {
            lastRenderError = error
            return false
        }
    }

    private func effectiveMPRSlabConfiguration(for slab: SlabConfiguration?) -> SlabConfiguration {
        let slabConfig = slab ?? SlabConfiguration(thickness: 1, steps: 1)
        let effectiveSlabSteps = adaptiveSamplingEnabled
            ? max(1, qualityScheduler.currentSlabSteps)
            : slabConfig.steps
        return SlabConfiguration(thickness: slabConfig.thickness,
                                 steps: effectiveSlabSteps)
    }

    private func currentMPRFrameSignature(axis: Axis,
                                          index: Int,
                                          blend: VolumetricMPRBlendMode,
                                          slab: SlabConfiguration?) -> MPRFrameSignature? {
        guard datasetApplied else { return nil }
        let planeIndex = clampedIndex(for: axis, index: index)
        let plane = makeDrawableSizedMprPlane(makeMprPlane(axis: axis, index: planeIndex))
        let effectiveSlab = effectiveMPRSlabConfiguration(for: slab)
        return MPRFrameSignature(planeGeometry: plane,
                                 slabThickness: effectiveSlab.thickness,
                                 slabSteps: effectiveSlab.steps,
                                 blend: blend.coreBlend)
    }

    func makeDrawableSizedMprPlane(_ plane: MPRPlaneGeometry) -> MPRPlaneGeometry {
        let viewport = clampedViewportSize()
        return plane.sizedForOutput(CGSize(width: viewport.width,
                                           height: viewport.height))
    }

    func invalidateMPRCache(axis: MPRPlaneAxis? = nil) {
        if let axis {
            mprFrameCache.invalidate(axis)
        } else {
            mprFrameCache.invalidateAll()
        }
    }

    func makeVolumeTransferFunction(for dataset: VolumeDataset) -> VolumeTransferFunction {
        guard let transferFunction else {
            return VolumeTransferFunction.defaultGrayscale(for: dataset)
        }

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
        let alphaPoints = transferFunction
            .sanitizedAlphaPoints()
            .map { point in
                VolumeTransferFunction.OpacityControlPoint(
                    intensity: point.dataValue + transferFunction.shift,
                    opacity: point.alphaValue
                )
            }

        if colourPoints.isEmpty || alphaPoints.isEmpty {
            return VolumeTransferFunction.defaultGrayscale(for: dataset)
        }
        return VolumeTransferFunction(opacityPoints: alphaPoints, colourPoints: colourPoints)
    }

}

extension VolumeViewportController {
    func currentDisplayTransform(for axis: Axis) -> MPRDisplayTransform {
        let planeAxis = axis.mprPlaneAxis
        if let frame = mprFrameCache.storedFrame(for: planeAxis) {
            return MPRDisplayTransformFactory.makeTransform(for: frame.planeGeometry,
                                                            axis: planeAxis)
        }
        guard datasetApplied else {
            return MPRDisplayTransformFactory.makeTransform(for: .canonical(axis: planeAxis),
                                                            axis: planeAxis)
        }

        let planeIndex: Int
        if case let .mpr(currentAxis, index, _, _) = currentDisplay,
           currentAxis == axis {
            planeIndex = index
        } else {
            planeIndex = clampedIndex(for: axis, index: mprPlaneIndex)
        }

        let plane = makeDrawableSizedMprPlane(makeMprPlane(axis: axis, index: planeIndex))
        return MPRDisplayTransformFactory.makeTransform(for: plane,
                                                        axis: planeAxis)
    }
}

private extension VolumeViewportController {
    func updateVolumeBounds(for dataset: VolumeDataset) {
        volumeWorldCenter = SIMD3<Float>(repeating: 0.5)
        let scale = SIMD3<Float>(
            Float(dataset.scale.x),
            Float(dataset.scale.y),
            Float(dataset.scale.z)
        )
        let maxScale = max(scale.x, max(scale.y, scale.z))
        let normalizedScale = maxScale > Float.ulpOfOne ? scale / maxScale : SIMD3<Float>(repeating: 1)
        volumeBoundingRadius = max(0.5 * simd_length(normalizedScale), 1e-3)
        if let geometry {
            patientLongitudinalAxis = safeNormalize(geometry.iopNorm, fallback: patientLongitudinalAxis)
        }
        cameraDistanceLimits = makeCameraDistanceLimits(radius: volumeBoundingRadius)
    }

    func makeGeometry(from dataset: VolumeDataset) -> DICOMGeometry {
        DICOMGeometry(
            cols: Int32(dataset.dimensions.width),
            rows: Int32(dataset.dimensions.height),
            slices: Int32(dataset.dimensions.depth),
            spacingX: Float(dataset.spacing.x),
            spacingY: Float(dataset.spacing.y),
            spacingZ: Float(dataset.spacing.z),
            iopRow: dataset.orientation.row,
            iopCol: dataset.orientation.column,
            ipp0: dataset.orientation.origin
        )
    }

    func resetCameraState(radius: Float,
                          normal: SIMD3<Float>,
                          up: SIMD3<Float>) {
        let safeNormal = safeNormalize(normal, fallback: SIMD3<Float>(0, 0, 1))
        let safeUp = safeNormalize(up, fallback: SIMD3<Float>(0, 1, 0))
        let distance = max(radius * defaultCameraDistanceFactor, radius * 1.25, 1.5)
        cameraTarget = volumeWorldCenter
        cameraOffset = safeNormal * distance
        cameraUpVector = safeUp
        fallbackWorldUp = safeUp
        fallbackCameraTarget = volumeWorldCenter
        initialCameraTarget = cameraTarget
        initialCameraOffset = cameraOffset
        initialCameraUp = cameraUpVector
        cameraDistanceLimits = makeCameraDistanceLimits(radius: radius)
        publishCameraState()
    }

    func publishCameraState() {
        statePublisher.recordCameraState(position: cameraTarget + cameraOffset,
                                         target: cameraTarget,
                                         up: cameraUpVector)
    }

    func makeCameraDistanceLimits(radius: Float) -> ClosedRange<Float> {
        let minimum = max(radius * 0.25, 0.1)
        let maximum = max(radius * 12, minimum + 0.5)
        return minimum...maximum
    }

    func clampCameraOffset(_ offset: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(offset)
        guard length > Float.ulpOfOne else {
            return SIMD3<Float>(0, 0, max(cameraDistanceLimits.lowerBound, 0.1))
        }
        let clamped = max(cameraDistanceLimits.lowerBound, min(length, cameraDistanceLimits.upperBound))
        return offset / length * clamped
    }

    func clampCameraTarget(_ target: SIMD3<Float>) -> SIMD3<Float> {
        let offset = target - volumeWorldCenter
        let limit = max(volumeBoundingRadius * maximumPanDistanceMultiplier, 1)
        let distance = simd_length(offset)
        guard distance > limit else { return target }
        guard distance > Float.ulpOfOne else { return volumeWorldCenter }
        return volumeWorldCenter + offset / distance * limit
    }

    func screenSpaceScale(distance: Float) -> (horizontal: Float, vertical: Float) {
        let bounds = viewportSurface.view.bounds
        let width = max(Float(bounds.width), 1)
        let height = max(Float(bounds.height), 1)
        let fovRadians = Float.pi / 3
        let verticalScale = 2 * distance * tan(fovRadians / 2) / height
        let horizontalScale = verticalScale * (width / height)
        if !verticalScale.isFinite || !horizontalScale.isFinite || verticalScale <= 0 || horizontalScale <= 0 {
            return (0.002, 0.002)
        }
        return (horizontalScale, verticalScale)
    }

    func safeNormalize(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let lengthSquared = simd_length_squared(vector)
        guard lengthSquared > Float.ulpOfOne else { return fallback }
        return vector / sqrt(lengthSquared)
    }

    func safePerpendicular(to vector: SIMD3<Float>) -> SIMD3<Float> {
        let axis = abs(vector.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        return safeNormalize(simd_cross(vector, axis), fallback: SIMD3<Float>(0, 0, 1))
    }
}

private extension VolumeViewportController {
    func normalizedPosition(for axis: Axis, index: Int) -> Float {
        guard let dataset else { return 0.5 }
        let maxIndex: Float
        switch axis {
        case .x:
            maxIndex = max(1, Float(dataset.dimensions.width - 1))
        case .y:
            maxIndex = max(1, Float(dataset.dimensions.height - 1))
        case .z:
            maxIndex = max(1, Float(dataset.dimensions.depth - 1))
        }
        return VolumetricMath.clampFloat(Float(index) / maxIndex, lower: 0, upper: 1)
    }

    func indexPosition(for axis: Axis, normalized: Float) -> Int {
        guard let dataset else { return 0 }
        let clamped = VolumetricMath.clampFloat(normalized, lower: 0, upper: 1)
        switch axis {
        case .x:
            return Int(round(clamped * Float(max(0, dataset.dimensions.width - 1))))
        case .y:
            return Int(round(clamped * Float(max(0, dataset.dimensions.height - 1))))
        case .z:
            return Int(round(clamped * Float(max(0, dataset.dimensions.depth - 1))))
        }
    }

    func clampedIndex(for axis: Axis, index: Int) -> Int {
        guard let dataset else { return 0 }
        switch axis {
        case .x:
            return VolumetricMath.clamp(index, min: 0, max: max(0, dataset.dimensions.width - 1))
        case .y:
            return VolumetricMath.clamp(index, min: 0, max: max(0, dataset.dimensions.height - 1))
        case .z:
            return VolumetricMath.clamp(index, min: 0, max: max(0, dataset.dimensions.depth - 1))
        }
    }

    func datasetDimensions() -> SIMD3<Float> {
        guard let dataset else { return SIMD3<Float>(1, 1, 1) }
        return MprPlaneComputation.datasetDimensions(width: dataset.dimensions.width,
                                                     height: dataset.dimensions.height,
                                                     depth: dataset.dimensions.depth)
    }

    func rotationQuaternion(for euler: SIMD3<Float>) -> simd_quatf {
        let qx = simd_quatf(angle: euler.x, axis: SIMD3<Float>(1, 0, 0))
        let qy = simd_quatf(angle: euler.y, axis: SIMD3<Float>(0, 1, 0))
        let qz = simd_quatf(angle: euler.z, axis: SIMD3<Float>(0, 0, 1))
        return simd_normalize(qz * qy * qx)
    }

    func makeMprPlane(axis: Axis, index: Int) -> MPRPlaneGeometry {
        let dims = datasetDimensions()
        let plane = MprPlaneComputation.make(axis: axis,
                                             index: index,
                                             dims: dims,
                                             rotation: rotationQuaternion(for: mprEuler))
        if let geometry {
            let world = plane.world(using: geometry)
            let tex = geometry.planeWorldToTex(originW: world.origin,
                                               axisUW: world.axisU,
                                               axisVW: world.axisV)
            let normal = safeNormalize(simd_cross(world.axisU, world.axisV), fallback: SIMD3<Float>(0, 0, 1))
            return MPRPlaneGeometry(originVoxel: plane.originVoxel,
                                    axisUVoxel: plane.axisUVoxel,
                                    axisVVoxel: plane.axisVVoxel,
                                    originWorld: world.origin,
                                    axisUWorld: world.axisU,
                                    axisVWorld: world.axisV,
                                    originTexture: tex.originT,
                                    axisUTexture: tex.axisUT,
                                    axisVTexture: tex.axisVT,
                                    normalWorld: normal)
        } else {
            let tex = plane.tex(dims: dims)
            let normal = safeNormalize(simd_cross(tex.axisU, tex.axisV), fallback: SIMD3<Float>(0, 0, 1))
            return MPRPlaneGeometry(originVoxel: plane.originVoxel,
                                    axisUVoxel: plane.axisUVoxel,
                                    axisVVoxel: plane.axisVVoxel,
                                    originWorld: plane.originVoxel,
                                    axisUWorld: plane.axisUVoxel,
                                    axisVWorld: plane.axisVVoxel,
                                    originTexture: tex.origin,
                                    axisUTexture: tex.axisU,
                                    axisVTexture: tex.axisV,
                                    normalWorld: normal)
        }
    }

    func alignCameraToCurrentMprPlane() {
        guard datasetApplied, let axis = currentMprAxis else { return }
        let plane = makeMprPlane(axis: axis, index: mprPlaneIndex)
        let normal = safeNormalize(plane.normalWorld, fallback: SIMD3<Float>(0, 0, 1))
        let up = safeNormalize(plane.axisVWorld, fallback: fallbackWorldUp)
        let distance = max(volumeBoundingRadius * defaultCameraDistanceFactor, volumeBoundingRadius * 1.25, 1.5)
        cameraTarget = volumeWorldCenter
        cameraOffset = normal * distance
        cameraUpVector = up
        initialCameraTarget = cameraTarget
        initialCameraOffset = cameraOffset
        initialCameraUp = up
        publishCameraState()
    }
}

private extension VolumeViewportController.Axis {
    var mprPlaneAxis: MPRPlaneAxis {
        MPRPlaneAxis(rawValue: rawValue) ?? .z
    }
}
