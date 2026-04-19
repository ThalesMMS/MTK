//
//  VolumetricSceneController.swift
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
public final class VolumetricSceneController: VolumetricSceneControlling, ObservableObject {
    public enum Error: Swift.Error {
        case metalUnavailable
        case transferFunctionUnavailable
        case imageCreationFailed
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

    public let imageSurface: ImageSurface
    public var surface: any RenderSurface { imageSurface }
    public let device: any MTLDevice
    public let commandQueue: any MTLCommandQueue
    public let statePublisher = VolumetricStatePublisher()

    public var cameraState: VolumetricCameraState { statePublisher.cameraState }
    public var sliceState: VolumetricSliceState { statePublisher.sliceState }
    public var windowLevelState: VolumetricWindowLevelState { statePublisher.windowLevelState }
    public var adaptiveSamplingEnabled: Bool { statePublisher.adaptiveSamplingEnabled }
    public private(set) var datasetApplied = false
    public private(set) var lastRenderError: (any Swift.Error)?

    public var transferFunctionDomain: ClosedRange<Float>? {
        if let transferFunction {
            return transferFunction.minimumValue...transferFunction.maximumValue
        }
        return dataset.map { Float($0.intensityRange.lowerBound)...Float($0.intensityRange.upperBound) }
    }

    let logger = Logger(category: "Volumetric.Controller")

    private let volumeRenderer: MetalVolumeRenderingAdapter
    private let mprRenderer: MetalMPRAdapter
    private var renderTask: Task<Void, Never>?
    private var renderGeneration: UInt64 = 0

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
    var isAdaptiveSamplingActive = false
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
    let adaptiveInteractionFactor: Float = 0.5
    let defaultCameraDistanceFactor: Float = 2.5

    public init(device: (any MTLDevice)? = nil, surface: ImageSurface? = nil) throws {
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
        self.imageSurface = surface ?? ImageSurface()
        self.volumeRenderer = try MetalVolumeRenderingAdapter(device: resolvedDevice,
                                                              commandQueue: queue)
        self.mprRenderer = try MetalMPRAdapter(device: resolvedDevice,
                                               commandQueue: queue)

        imageSurface.onDrawableSizeChange = { [weak self] _ in
            self?.scheduleRender()
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
        geometry = makeGeometry(from: dataset)
        datasetApplied = true

        if transferFunction == nil {
            transferFunction = VolumeTransferFunctionLibrary.transferFunction(for: .ctSoftTissue)
            defaultTransferShift = transferFunction?.shift ?? 0
        }

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
            mprPlaneIndex = clampedIndex(for: axis, index: index)
            mprNormalizedPosition = normalizedPosition(for: axis, index: mprPlaneIndex)
            mprEuler = .zero
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
            isAdaptiveSamplingActive = false
        }
        scheduleRender()
    }

    public func beginAdaptiveSamplingInteraction() async {
        guard adaptiveSamplingEnabled else { return }
        isAdaptiveSamplingActive = true
        scheduleRender()
    }

    public func endAdaptiveSamplingInteraction() async {
        guard isAdaptiveSamplingActive else { return }
        isAdaptiveSamplingActive = false
        scheduleRender()
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
            currentDisplay = .mpr(axis: axis,
                                  index: mprPlaneIndex,
                                  blend: mode,
                                  slab: currentMprSlab)
        }
        scheduleRender()
    }

    public func setMprSlab(thickness: Int, steps: Int) async {
        currentMprSlab = SlabConfiguration(thickness: thickness, steps: steps)
        scheduleRender()
    }

    public func setMprHuWindow(min: Int32, max: Int32) async {
        mprHuWindow = min...max
        scheduleRender()
    }

    public func setMprPlane(axis: Axis, normalized: Float) async {
        guard datasetApplied, currentMprAxis == axis else { return }
        let clamped = VolumetricMath.clampFloat(normalized, lower: 0, upper: 1)
        mprPlaneIndex = clampedIndex(for: axis, index: indexPosition(for: axis, normalized: clamped))
        mprNormalizedPosition = normalizedPosition(for: axis, index: mprPlaneIndex)
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

    @_spi(Testing)
    public var debugRenderedImage: CGImage? {
        imageSurface.renderedImage
    }

    @_spi(Testing)
    public var debugSamplingStep: Float {
        effectiveSamplingStep
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

private extension VolumetricSceneController {
    var effectiveSamplingStep: Float {
        guard adaptiveSamplingEnabled, isAdaptiveSamplingActive else { return max(baseSamplingStep, 1) }
        return max(64, baseSamplingStep * adaptiveInteractionFactor)
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

        do {
            let image: CGImage?
            switch display {
            case let .volume(method):
                RenderingTelemetry.volumeRenderScheduled()
                image = try await renderVolume(dataset: dataset, method: method)
                RenderingTelemetry.volumeRenderCompleted(duration: Date().timeIntervalSince(started))
            case let .mpr(axis, index, blend, slab):
                RenderingTelemetry.mprRenderScheduled(blend: blend.coreBlend)
                image = try await renderMpr(dataset: dataset,
                                            axis: axis,
                                            index: index,
                                            blend: blend,
                                            slab: slab)
                RenderingTelemetry.mprRenderCompleted(duration: Date().timeIntervalSince(started),
                                                      blend: blend.coreBlend)
            }

            guard !Task.isCancelled, generation == renderGeneration else { return }
            guard let image else { throw Error.imageCreationFailed }
            lastRenderError = nil
            imageSurface.display(image)
        } catch {
            guard !Task.isCancelled, generation == renderGeneration else { return }
            lastRenderError = error
            switch display {
            case .volume:
                RenderingTelemetry.volumeRenderFailed(duration: Date().timeIntervalSince(started),
                                                      reason: .runtimeError,
                                                      error: error)
            case .mpr:
                RenderingTelemetry.mprRenderFailed(duration: Date().timeIntervalSince(started),
                                                  reason: .runtimeError,
                                                  error: error)
            }
            logger.error("Render failed", error: error)
        }
    }

    func renderVolume(dataset: VolumeDataset,
                      method: VolumetricRenderMethod) async throws -> CGImage? {
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

        let viewport = clampedViewportSize()
        let transfer = makeVolumeTransferFunction(for: dataset)
        let request = VolumeRenderRequest(
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
            samplingDistance: 1 / effectiveSamplingStep,
            compositing: method.compositing,
            quality: isAdaptiveSamplingActive ? .interactive : .production
        )
        let result = try await volumeRenderer.renderImage(using: request)
        return result.cgImage
    }

    func renderMpr(dataset: VolumeDataset,
                   axis: Axis,
                   index: Int,
                   blend: VolumetricMPRBlendMode,
                   slab: SlabConfiguration?) async throws -> CGImage? {
        let planeIndex = clampedIndex(for: axis, index: index)
        let plane = makeMprPlane(axis: axis, index: planeIndex)
        let slabConfig = slab ?? SlabConfiguration(thickness: 1, steps: 1)
        let slice = try await mprRenderer.makeSlab(dataset: dataset,
                                                   plane: plane,
                                                   thickness: slabConfig.thickness,
                                                   steps: slabConfig.steps,
                                                   blend: blend.coreBlend)
        return makeImage(from: slice,
                         window: mprHuWindow ?? huWindow.map { $0.minHU...$0.maxHU } ?? dataset.intensityRange)
    }

    func clampedViewportSize() -> (width: Int, height: Int) {
        let size = imageSurface.drawablePixelSize
        return (
            max(1, Int(size.width.rounded())),
            max(1, Int(size.height.rounded()))
        )
    }

    func makeVolumeTransferFunction(for dataset: VolumeDataset) -> VolumeTransferFunction {
        guard let transferFunction else {
            return defaultVolumeTransferFunction(for: dataset)
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
            return defaultVolumeTransferFunction(for: dataset)
        }
        return VolumeTransferFunction(opacityPoints: alphaPoints, colourPoints: colourPoints)
    }

    func defaultVolumeTransferFunction(for dataset: VolumeDataset) -> VolumeTransferFunction {
        let lower = Float(dataset.intensityRange.lowerBound)
        let upper = Float(dataset.intensityRange.upperBound)
        return VolumeTransferFunction(
            opacityPoints: [
                VolumeTransferFunction.OpacityControlPoint(intensity: lower, opacity: 0),
                VolumeTransferFunction.OpacityControlPoint(intensity: upper, opacity: 1)
            ],
            colourPoints: [
                VolumeTransferFunction.ColourControlPoint(intensity: lower, colour: SIMD4<Float>(0, 0, 0, 1)),
                VolumeTransferFunction.ColourControlPoint(intensity: upper, colour: SIMD4<Float>(1, 1, 1, 1))
            ]
        )
    }

    func makeImage(from slice: MPRSlice,
                   window: ClosedRange<Int32>) -> CGImage? {
        let width = max(slice.width, 1)
        let height = max(slice.height, 1)
        let pixelCount = width * height
        let lower = Float(window.lowerBound)
        let upper = Float(window.upperBound)
        let span = max(upper - lower, Float.leastNonzeroMagnitude)
        var pixels = [UInt8](repeating: 0, count: pixelCount)

        slice.pixels.withUnsafeBytes { buffer in
            switch slice.pixelFormat {
            case .int16Signed:
                guard let pointer = buffer.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
                for index in 0..<min(pixelCount, slice.pixels.count / MemoryLayout<Int16>.stride) {
                    let value = Float(pointer[index])
                    let normalized = VolumetricMath.clampFloat((value - lower) / span, lower: 0, upper: 1)
                    pixels[index] = UInt8(clamping: Int(round(normalized * 255)))
                }
            case .int16Unsigned:
                guard let pointer = buffer.baseAddress?.assumingMemoryBound(to: UInt16.self) else { return }
                for index in 0..<min(pixelCount, slice.pixels.count / MemoryLayout<UInt16>.stride) {
                    let value = Float(pointer[index])
                    let normalized = VolumetricMath.clampFloat((value - lower) / span, lower: 0, upper: 1)
                    pixels[index] = UInt8(clamping: Int(round(normalized * 255)))
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            return nil
        }
        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 8,
                       bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}

private extension VolumetricSceneController {
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
        let bounds = imageSurface.view.bounds
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

private extension VolumetricSceneController {
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
