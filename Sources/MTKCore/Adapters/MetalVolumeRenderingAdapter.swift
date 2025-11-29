//
//  MetalVolumeRenderingAdapter.swift
//  MTK
//
//  Provides a CPU-backed approximation of the Metal volume renderer so unit
//  tests can exercise the domain contracts without depending on GPU
//  availability. The adapter maintains basic rendering state (windowing,
//  compositing, lighting) and returns fallback images alongside rich metadata.
//  Real GPU work will replace these code paths in future milestones.
//
//  Thales Matheus Mendonça Santos — October 2025

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@preconcurrency import Metal
import OSLog
import simd

@preconcurrency
public struct ExtendedRenderingState: Sendable {
    var huWindow: ClosedRange<Int32>?
    var lightingEnabled: Bool = true
    var samplingStep: Float = 1.0 / 512.0
    var shift: Float = 0
    var densityGate: ClosedRange<Float>?
    var adaptiveEnabled: Bool = false
    var adaptiveThreshold: Float = 0
    var jitterAmount: Float = 0
    var earlyTerminationThreshold: Float = 0.99
    var channelIntensities: SIMD4<Float> = SIMD4<Float>(repeating: 1)
    var toneCurvePoints: [Int: [SIMD2<Float>]] = [:]
    var toneCurvePresetKeys: [Int: String] = [:]
    var toneCurveGains: [Int: Float] = [:]
    var clipBounds: ClipBoundsSnapshot = .default
    var clipPlanePreset: Int = 0
    var clipPlaneOffset: Float = 0
    var earlyExit: VolumeRenderRequest.EarlyExitThresholds = .defaults
    var emptySpace: VolumeRenderRequest.EmptySpaceSkipping = .defaults
    var gradientSmoothness: Float = 0.0
    var usePreIntegratedTF: Bool = false
    var adaptiveStepMinScale: Float = 1.0
    var adaptiveStepMaxScale: Float = 1.0
    var adaptiveGradientScale: Float = 0.0
}

public actor MetalVolumeRenderingAdapter: VolumeRenderingPort {
    public enum AdapterError: Error, Equatable {
        case invalidHistogramBinCount
    }

    private typealias ArgumentIndex = ArgumentEncoderManager.ArgumentIndex

    enum RenderingError: Error {
        case datasetTextureUnavailable
        case transferTextureUnavailable
        case commandEncodingFailed
        case outputTextureUnavailable
    }

    public struct Overrides {
        public var compositing: VolumeRenderRequest.Compositing?
        public var samplingDistance: Float?
        public var window: ClosedRange<Int32>?
        public var lightingEnabled: Bool = true
        public var gradientSmoothness: Float?
        public var usePreIntegratedTF: Bool?
        public var adaptiveStepMinScale: Float?
        public var adaptiveStepMaxScale: Float?
        public var adaptiveGradientScale: Float?
        public var adaptiveFlatThreshold: Float?
        public var adaptiveFlatBoost: Float?
        public var preTFBlurRadius: Float?
    }

    public struct RenderSnapshot {
        public var dataset: VolumeDataset
        public var metadata: VolumeRenderResult.Metadata
        public var window: ClosedRange<Int32>
    }

    let logger = Logger(subsystem: "com.mtk.volumerendering",
                        category: "MetalVolumeRenderingAdapter")
    private var overrides = Overrides()
    internal var extendedState = ExtendedRenderingState()
    private var currentPreset: VolumeRenderingPreset?
    private var lastSnapshot: RenderSnapshot?
    private var metalState: MetalState?
    private var diagnosticLoggingEnabled: Bool = false
    var clipPlaneApproximationLogged = false

    private struct DatasetIdentity: Equatable, Sendable {
        let pointer: UInt
        let count: Int

        init(dataset: VolumeDataset) {
            self.count = dataset.data.count
            self.pointer = dataset.data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return UInt(bitPattern: baseAddress)
            }
        }
    }

    private final class MetalState: @unchecked Sendable {
        struct TransferCache {
            var transfer: VolumeTransferFunction
            var sampleDistance: Float
            var texture: any MTLTexture
        }

        let device: any MTLDevice
        let commandQueue: any MTLCommandQueue
        let pipeline: any MTLComputePipelineState
        let argumentManager: ArgumentEncoderManager
        let dispatchOptimizer: ThreadgroupDispatchOptimizer
        let cameraBuffer: any MTLBuffer
        var datasetIdentity: DatasetIdentity?
        var volumeTexture: (any MTLTexture)?
        var transferCache: TransferCache?
        var occupancyTexture: (any MTLTexture)?
        var frameIndex: UInt32 = 0

        init(device: any MTLDevice,
             commandQueue: any MTLCommandQueue,
             pipeline: any MTLComputePipelineState,
             argumentManager: ArgumentEncoderManager,
             dispatchOptimizer: ThreadgroupDispatchOptimizer,
             cameraBuffer: any MTLBuffer) {
            self.device = device
            self.commandQueue = commandQueue
            self.pipeline = pipeline
            self.argumentManager = argumentManager
            self.dispatchOptimizer = dispatchOptimizer
            self.cameraBuffer = cameraBuffer
        }
    }

    public init() {}

    public func enableDiagnosticLogging(_ enabled: Bool) {
        diagnosticLoggingEnabled = enabled
        if enabled {
            logger.info("Diagnostic logging enabled on MetalVolumeRenderingAdapter.")
        } else {
            logger.info("Diagnostic logging disabled on MetalVolumeRenderingAdapter.")
        }
    }

    public func renderImage(using request: VolumeRenderRequest) async throws -> VolumeRenderResult {
        if diagnosticLoggingEnabled {
            logger.info("[DIAG] renderImage called - viewport: \(request.viewportSize.width)x\(request.viewportSize.height), compositing: \(String(describing: request.compositing)), quality: \(String(describing: request.quality))")
        }

        var effectiveRequest = request

        if let compositing = overrides.compositing {
            effectiveRequest.compositing = compositing
            if diagnosticLoggingEnabled {
                logger.info("[DIAG] Applied compositing override: \(String(describing: compositing))")
            }
        }
        if let samplingDistance = overrides.samplingDistance {
            effectiveRequest.samplingDistance = samplingDistance
            if diagnosticLoggingEnabled {
                logger.info("[DIAG] Applied sampling distance override: \(samplingDistance)")
            }
        }
        if let gs = overrides.gradientSmoothness {
            effectiveRequest.gradientSmoothness = gs
        }
        if let pitf = overrides.usePreIntegratedTF {
            effectiveRequest.usePreIntegratedTF = pitf
        }
        if let minScale = overrides.adaptiveStepMinScale {
            effectiveRequest.adaptiveStepMinScale = minScale
        }
        if let maxScale = overrides.adaptiveStepMaxScale {
            effectiveRequest.adaptiveStepMaxScale = maxScale
        }
        if let gradScale = overrides.adaptiveGradientScale {
            effectiveRequest.adaptiveGradientScale = gradScale
        }
        if let flatThresh = overrides.adaptiveFlatThreshold {
            effectiveRequest.adaptiveFlatThreshold = flatThresh
        }
        if let flatBoost = overrides.adaptiveFlatBoost {
            effectiveRequest.adaptiveFlatBoost = flatBoost
        }
        if let blur = overrides.preTFBlurRadius {
            effectiveRequest.preTFBlurRadius = blur
        }

        let window = extendedState.huWindow
            ?? overrides.window
            ?? request.dataset.recommendedWindow
            ?? request.dataset.intensityRange

        if diagnosticLoggingEnabled {
            logger.info("[DIAG] Using window: \(window.lowerBound)...\(window.upperBound)")
        }

        if let state = await resolveMetalState() {
            do {
                let result = try await renderWithMetal(state: state, request: effectiveRequest)
                lastSnapshot = RenderSnapshot(dataset: request.dataset,
                                              metadata: result.metadata,
                                              window: window)
                return result
            } catch {
                logger.error("Metal rendering failed: \(error.localizedDescription)")
                if diagnosticLoggingEnabled {
                    logger.error("[DIAG] Falling back to CPU renderer due to error: \(error.localizedDescription)")
                }
                metalState = nil
            }
        } else if diagnosticLoggingEnabled {
            logger.warning("[DIAG] No Metal state available, falling back to CPU rendering")
        }

        let result = await Task(priority: .userInitiated) {
            let image = Self.makeFallbackImage(dataset: effectiveRequest.dataset,
                                               window: window,
                                               state: extendedState,
                                               request: effectiveRequest)
            let metadata = VolumeRenderResult.Metadata(
                viewportSize: effectiveRequest.viewportSize,
                samplingDistance: effectiveRequest.samplingDistance,
                compositing: effectiveRequest.compositing,
                quality: effectiveRequest.quality
            )
            return VolumeRenderResult(cgImage: image, metadata: metadata)
        }.value

        lastSnapshot = RenderSnapshot(dataset: request.dataset,
                                      metadata: result.metadata,
                                      window: window)
        return result
    }

    public func updatePreset(_ preset: VolumeRenderingPreset,
                             for dataset: VolumeDataset) async throws -> [VolumeRenderingPreset] {
        if diagnosticLoggingEnabled {
            logger.info("[DIAG] updatePreset called - preset: \(preset.name)")
        }
        currentPreset = preset
        return [preset]
    }

    public func refreshHistogram(for dataset: VolumeDataset,
                                 descriptor: VolumeHistogramDescriptor,
                                 transferFunction: VolumeTransferFunction) async throws -> VolumeHistogram {
        guard descriptor.binCount > 0 else {
            throw AdapterError.invalidHistogramBinCount
        }

        let bins = await Task.detached(priority: .userInitiated) {
            dataset.data.withUnsafeBytes { buffer -> [Float] in
                guard let reader = VolumeDataReader(dataset: dataset, buffer: buffer) else {
                    return [Float](repeating: 0, count: descriptor.binCount)
                }

                let binCount = descriptor.binCount
                var histogram = [Float](repeating: 0, count: binCount)

                let lowerBound = descriptor.intensityRange.lowerBound
                let upperBound = descriptor.intensityRange.upperBound
                let span = max(upperBound - lowerBound, Float.leastNonzeroMagnitude)
                let binWidth = span / Float(binCount)

                reader.forEachIntensity { sample in
                    let clamped = min(max(sample, lowerBound), upperBound)
                    var index = Int((clamped - lowerBound) / binWidth)
                    if index >= binCount {
                        index = binCount - 1
                    }
                    histogram[index] += 1
                }

                if descriptor.normalize {
                    let total = histogram.reduce(0, +)
                    if total > 0 {
                        for index in histogram.indices {
                            histogram[index] /= total
                        }
                    }
                }

                return histogram
            }
        }.value

        return VolumeHistogram(descriptor: descriptor, bins: bins)
    }

    public func send(_ command: VolumeRenderingCommand) async throws {
        if diagnosticLoggingEnabled {
            logger.info("[DIAG] send command: \(String(describing: command))")
        }
        switch command {
        case .setCompositing(let compositing):
            overrides.compositing = compositing
            if diagnosticLoggingEnabled {
                logger.info("[DIAG] Set compositing: \(String(describing: compositing))")
            }
        case .setWindow(let minValue, let maxValue):
            overrides.window = minValue...maxValue
            if diagnosticLoggingEnabled {
                logger.info("[DIAG] Set window: \(minValue)...\(maxValue)")
            }
        case .setSamplingStep(let samplingDistance):
            overrides.samplingDistance = samplingDistance
            if diagnosticLoggingEnabled {
                logger.info("[DIAG] Set sampling distance: \(samplingDistance)")
            }
        case .setLighting(let enabled):
            overrides.lightingEnabled = enabled
            if diagnosticLoggingEnabled {
                logger.info("[DIAG] Set lighting: \(enabled)")
            }
        }
    }
}

// MARK: - Testing SPI

extension MetalVolumeRenderingAdapter {
    @_spi(Testing)
    public var debugOverrides: Overrides { overrides }

    @_spi(Testing)
    public var debugLastSnapshot: RenderSnapshot? { lastSnapshot }

    @_spi(Testing)
    public var debugCurrentPreset: VolumeRenderingPreset? { currentPreset }

    func debugInverseViewProjectionMatrix(camera: VolumeRenderRequest.Camera,
                                          viewportSize: (width: Int, height: Int),
                                          dataset: VolumeDataset? = nil) -> simd_float4x4 {
        makeInverseViewProjectionMatrix(camera: camera,
                                        viewportSize: viewportSize,
                                        dataset: dataset)
    }
}

// MARK: - Helpers

private extension MetalVolumeRenderingAdapter {
    private func resolveMetalState() async -> MetalState? {
        if let state = metalState {
            return state
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            logger.error("Metal device or command queue unavailable; compute backend disabled.")
            return nil
        }

        let library = ShaderLibraryLoader.makeDefaultLibrary(on: device) { message in
            if diagnosticLoggingEnabled {
                logger.info("\(message)")
            }
        }

        guard let shaderLibrary = library else {
            logger.error("Unable to resolve shader library for volume_compute kernel.")
            return nil
        }

        guard let function = shaderLibrary.makeFunction(name: "volume_compute") else {
            logger.error("volume_compute function missing in shader library.")
            return nil
        }

        do {
            let pipeline = try await device.makeComputePipelineState(function: function)
            let debugOptions = VolumeRenderingDebugOptions(
                isDebugMode: diagnosticLoggingEnabled,
                histogramBinCount: 512,
                enableDensityDebug: false
            )

            let argumentManager = ArgumentEncoderManager(
                device: device,
                mtlFunction: function,
                debugOptions: debugOptions
            )
            let dispatchOptimizer = ThreadgroupDispatchOptimizer(debugOptions: debugOptions)
            guard let cameraBuffer = device.makeBuffer(length: CameraUniforms.stride,
                                                       options: [.storageModeShared])
            else {
                logger.error("Unable to allocate camera buffer for compute renderer.")
                return nil
            }
            cameraBuffer.label = "VolumeCompute.CameraUniforms"

            let state = MetalState(device: device,
                                   commandQueue: commandQueue,
                                   pipeline: pipeline,
                                   argumentManager: argumentManager,
                                   dispatchOptimizer: dispatchOptimizer,
                                   cameraBuffer: cameraBuffer)
            metalState = state
            if diagnosticLoggingEnabled {
                logger.info("[DIAG] Created compute pipeline on device: \(device.name)")
            }
            return state
        } catch {
            logger.error("Unable to create compute pipeline: \(error.localizedDescription)")
            return nil
        }
    }

    private func renderWithMetal(state: MetalState,
                                 request: VolumeRenderRequest) async throws -> VolumeRenderResult {
        let viewport = sanitizedViewportSize(request.viewportSize)
        guard viewport.width > 0, viewport.height > 0 else {
            throw RenderingError.outputTextureUnavailable
        }

        let datasetTexture = try prepareDatasetTexture(for: request.dataset, state: state)
        var tfForRendering = request.transferFunction
        if request.useDualParameterTF {
            tfForRendering.gradientResolution = max(tfForRendering.gradientResolution, 256)
        }

        let transferTexture = try await prepareTransferTexture(for: tfForRendering,
                                                               dataset: request.dataset,
                                                               sampleDistance: request.samplingDistance,
                                                               state: state)
        let occupancyTexture = try prepareOccupancyTexture(for: request.dataset,
                                                           request: request,
                                                           state: state)

        var parameters = buildRenderingParameters(for: request)
        var optionValue = computeOptionFlags()
        var targetViewSize = UInt16(clamping: max(viewport.width, viewport.height))
        var quaternion = SIMD4<Float>(0, 0, 0, 1)

        state.argumentManager.encodeTexture(datasetTexture, argumentIndex: .mainTexture)
        state.argumentManager.encodeTexture(transferTexture, argumentIndex: .transferTextureCh1)
        state.argumentManager.encodeTexture(transferTexture, argumentIndex: .transferTextureCh2)
        state.argumentManager.encodeTexture(transferTexture, argumentIndex: .transferTextureCh3)
        state.argumentManager.encodeTexture(transferTexture, argumentIndex: .transferTextureCh4)
        if let occupancyTexture {
            state.argumentManager.encodeTexture(occupancyTexture, argumentIndex: .occupancyTexture)
        } else if let fallback = state.occupancyTexture {
            state.argumentManager.encodeTexture(fallback, argumentIndex: .occupancyTexture)
        } else {
            // Bind a 1x1 zero texture to keep argument buffer valid
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type3D
            descriptor.pixelFormat = .rg16Float
            descriptor.width = 1
            descriptor.height = 1
            descriptor.depth = 1
            descriptor.mipmapLevelCount = 1
            descriptor.usage = [.shaderRead]
            let tex = state.device.makeTexture(descriptor: descriptor)
            var zero = SIMD2<Float16>(0, 0)
            tex?.replace(region: MTLRegionMake3D(0, 0, 0, 1, 1, 1),
                         mipmapLevel: 0,
                         slice: 0,
                         withBytes: &zero,
                         bytesPerRow: MemoryLayout<SIMD2<Float16>>.stride,
                         bytesPerImage: MemoryLayout<SIMD2<Float16>>.stride)
            if let tex {
                state.argumentManager.encodeTexture(tex, argumentIndex: .occupancyTexture)
                state.occupancyTexture = tex
            }
        }
        state.argumentManager.encodeSampler(filter: .linear)
        state.argumentManager.encode(&parameters, argumentIndex: .renderParams)
        state.argumentManager.encode(&optionValue, argumentIndex: .optionValue)
        state.argumentManager.encode(&quaternion, argumentIndex: .quaternion)
        state.argumentManager.encode(&targetViewSize, argumentIndex: .targetViewSize)
        state.argumentManager.encode(nil, argumentIndex: .toneBufferCh1)
        state.argumentManager.encode(nil, argumentIndex: .toneBufferCh2)
        state.argumentManager.encode(nil, argumentIndex: .toneBufferCh3)
        state.argumentManager.encode(nil, argumentIndex: .toneBufferCh4)

        let camera = makeCameraUniforms(for: request,
                                        viewportSize: viewport,
                                        frameIndex: state.frameIndex)
        encodeCamera(camera, into: state)

        let outputTexture = try await dispatchCompute(state: state,
                                                      viewportSize: viewport)
        let image = try makeImage(from: outputTexture,
                                  width: viewport.width,
                                  height: viewport.height)
        state.frameIndex &+= 1

        let metadata = VolumeRenderResult.Metadata(
            viewportSize: request.viewportSize,
            samplingDistance: request.samplingDistance,
            compositing: request.compositing,
            quality: request.quality
        )
        return VolumeRenderResult(cgImage: image,
                                  metalTexture: outputTexture,
                                  metadata: metadata)
    }

    private func sanitizedViewportSize(_ size: CGSize) -> (width: Int, height: Int) {
        let width = max(1, Int(size.width.rounded(.toNearestOrEven)))
        let height = max(1, Int(size.height.rounded(.toNearestOrEven)))
        return (width, height)
    }

    private func prepareDatasetTexture(for dataset: VolumeDataset,
                                       state: MetalState) throws -> any MTLTexture {
        let identity = DatasetIdentity(dataset: dataset)
        if let existing = state.volumeTexture,
           state.datasetIdentity == identity {
            return existing
        }

        let factory = VolumeTextureFactory(dataset: dataset)
        guard let texture = factory.generate(device: state.device) else {
            throw RenderingError.datasetTextureUnavailable
        }
        texture.label = "VolumeCompute.Dataset"
        state.volumeTexture = texture
        state.datasetIdentity = identity
        state.argumentManager.markAsNeedsUpdate(argumentIndex: .mainTexture)
        return texture
    }

    private func prepareTransferTexture(for transfer: VolumeTransferFunction,
                                        dataset: VolumeDataset,
                                        sampleDistance: Float,
                                        state: MetalState) async throws -> any MTLTexture {
        if let cache = state.transferCache,
           cache.transfer == transfer,
           abs(cache.sampleDistance - sampleDistance) < 1e-5 {
            return cache.texture
        }

        let unitDistance = OpacityCorrection.scalarOpacityUnitDistance(for: dataset)
        let factor = OpacityCorrection.opacityFactor(sampleDistance: sampleDistance,
                                                    opacityUnitDistance: unitDistance)
        let correctedTransfer = OpacityCorrection.correctedTransferFunction(transfer, factor: factor)
        let resolvedTransfer = makeTransferFunction(from: correctedTransfer,
                                                    dataset: dataset)
        var tfOptions = TransferFunctions.TextureOptions.default
        if transfer.gradientResolution > 1 {
            tfOptions.gradientResolution = transfer.gradientResolution
        }
        let options = tfOptions
        let texture = await MainActor.run {
            TransferFunctions.texture(for: resolvedTransfer,
                                      device: state.device,
                                      options: options)
        }

        guard let texture else {
            throw RenderingError.transferTextureUnavailable
        }
        texture.label = "VolumeCompute.Transfer"
        state.transferCache = MetalState.TransferCache(transfer: transfer,
                                                       sampleDistance: sampleDistance,
                                                       texture: texture)
        return texture
    }

    private func prepareOccupancyTexture(for dataset: VolumeDataset,
                                          request: VolumeRenderRequest,
                                          state: MetalState,
                                          brickSize: Int = 8) throws -> (any MTLTexture)? {
        guard request.emptySpaceSkipping.occupancyEnabled || request.emptySpaceSkipping.minMaxEnabled else {
            state.occupancyTexture = nil
            return nil
        }

        if let existing = state.occupancyTexture,
           state.datasetIdentity == DatasetIdentity(dataset: dataset) {
            return existing
        }

        let dims = dataset.dimensions
        let bricksX = max(1, (dims.width + brickSize - 1) / brickSize)
        let bricksY = max(1, (dims.height + brickSize - 1) / brickSize)
        let bricksZ = max(1, (dims.depth + brickSize - 1) / brickSize)
        let totalBricks = bricksX * bricksY * bricksZ

        // Safety: avoid huge allocations
        if totalBricks > 4_000_000 {
            logger.warning("Occupancy grid skipped: too many bricks (\(totalBricks))")
            state.occupancyTexture = nil
            return nil
        }

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rg16Float
        descriptor.width = bricksX
        descriptor.height = bricksY
        descriptor.depth = bricksZ
        descriptor.usage = [.shaderRead]

        guard let texture = state.device.makeTexture(descriptor: descriptor) else {
            throw RenderingError.datasetTextureUnavailable
        }
        texture.label = "VolumeCompute.Occupancy"

        var data = Data(count: totalBricks * MemoryLayout<SIMD2<Float16>>.stride)

        data.withUnsafeMutableBytes { buffer in
            guard let outPtr = buffer.baseAddress?.assumingMemoryBound(to: SIMD2<Float16>.self) else { return }
            dataset.data.withUnsafeBytes { raw in
                let base = raw.bindMemory(to: Int16.self)
                    let minVal = Float(dataset.intensityRange.lowerBound)
                    let maxVal = Float(dataset.intensityRange.upperBound)
                    let invRange = maxVal - minVal > 1e-5 ? 1.0 / (maxVal - minVal) : 1.0

                for bz in 0..<bricksZ {
                    for by in 0..<bricksY {
                        for bx in 0..<bricksX {
                            var minV: Float = Float.greatestFiniteMagnitude
                            var maxV: Float = -Float.greatestFiniteMagnitude

                            let startZ = bz * brickSize
                            let startY = by * brickSize
                            let startX = bx * brickSize

                            for z in startZ..<min(startZ + brickSize, dims.depth) {
                                for y in startY..<min(startY + brickSize, dims.height) {
                                    let rowOffset = (z * dims.height + y) * dims.width
                                    let startIdx = rowOffset + startX
                                    let endIdx = min(rowOffset + min(startX + brickSize, dims.width), rowOffset + dims.width)
                                    for idx in startIdx..<endIdx {
                                        let v = Float(base[idx])
                                        minV = min(minV, v)
                                        maxV = max(maxV, v)
                                    }
                                }
                            }

                            let normMin = simd_clamp((minV - minVal) * invRange, 0.0, 1.0)
                            let normMax = simd_clamp((maxV - minVal) * invRange, 0.0, 1.0)
                            let brickIndex = (bz * bricksY * bricksX) + (by * bricksX) + bx
                            outPtr[brickIndex] = SIMD2<Float16>(Float16(normMin), Float16(normMax))
                        }
                    }
                }
            }
        }

        data.withUnsafeBytes { buffer in
            guard let src = buffer.baseAddress else { return }
            let region = MTLRegionMake3D(0, 0, 0, bricksX, bricksY, bricksZ)
            texture.replace(region: region,
                             mipmapLevel: 0,
                             slice: 0,
                             withBytes: src,
                             bytesPerRow: bricksX * MemoryLayout<SIMD2<Float16>>.stride,
                             bytesPerImage: bricksX * bricksY * MemoryLayout<SIMD2<Float16>>.stride)
        }

        state.occupancyTexture = texture
        return texture
    }

    private func makeTransferFunction(from transfer: VolumeTransferFunction,
                                      dataset: VolumeDataset) -> TransferFunction {
        var tf = TransferFunction()
        tf.minimumValue = Float(dataset.intensityRange.lowerBound)
        tf.maximumValue = Float(dataset.intensityRange.upperBound)
        tf.shift = 0
        tf.colorSpace = .linear
        tf.colourPoints = sanitizeColourPoints(transfer.colourPoints,
                                               defaultMin: tf.minimumValue,
                                               defaultMax: tf.maximumValue)
        tf.alphaPoints = sanitizeAlphaPoints(transfer.opacityPoints,
                                             defaultMin: tf.minimumValue,
                                             defaultMax: tf.maximumValue)
        return tf
    }

    private func sanitizeColourPoints(_ points: [VolumeTransferFunction.ColourControlPoint],
                                      defaultMin: Float,
                                      defaultMax: Float) -> [TransferFunction.ColorPoint] {
        var mapped = points.map { point -> TransferFunction.ColorPoint in
            let colour = point.colour
            let rgba = TransferFunction.RGBAColor(r: colour.x,
                                                  g: colour.y,
                                                  b: colour.z,
                                                  a: colour.w)
            return TransferFunction.ColorPoint(dataValue: point.intensity,
                                               colourValue: rgba)
        }
        if mapped.isEmpty {
            mapped = [
                TransferFunction.ColorPoint(dataValue: defaultMin,
                                            colourValue: TransferFunction.RGBAColor(r: 1, g: 1, b: 1, a: 1)),
                TransferFunction.ColorPoint(dataValue: defaultMax,
                                            colourValue: TransferFunction.RGBAColor(r: 1, g: 1, b: 1, a: 1))
            ]
        }
        return mapped
    }

    private func sanitizeAlphaPoints(_ points: [VolumeTransferFunction.OpacityControlPoint],
                                     defaultMin: Float,
                                     defaultMax: Float) -> [TransferFunction.AlphaPoint] {
        var mapped = points.map { point in
            TransferFunction.AlphaPoint(dataValue: point.intensity,
                                        alphaValue: point.opacity)
        }
        if mapped.isEmpty {
            mapped = [
                TransferFunction.AlphaPoint(dataValue: defaultMin, alphaValue: 0),
                TransferFunction.AlphaPoint(dataValue: defaultMax, alphaValue: 1)
            ]
        }
        return mapped
    }

    private func buildRenderingParameters(for request: VolumeRenderRequest) -> RenderingParameters {
        var params = RenderingParameters()
        let dataset = request.dataset
        params.material = buildVolumeUniforms(for: request)
        let normalizedStep = SampleDistanceCalculator.normalizedSampleDistance(request.samplingDistance,
                                                                               dataset: request.dataset)
        params.renderingStep = normalizedStep
        params.earlyTerminationThreshold = extendedState.earlyTerminationThreshold
        // Empty-space skipping
        let ess = request.emptySpaceSkipping
        params.zeroRunThreshold = ess.enabled ? ess.alphaThreshold : 1.0 // effectively disable when false
        params.zeroRunLength = ess.zeroRunLength
        params.zeroSkipDistance = ess.zeroSkipDistance
        params.emptySpaceGradientThreshold = ess.enabled ? ess.gradientThreshold : 0.0
        params.emptySpaceDensityThreshold = ess.enabled ? ess.densityThreshold : 0.0
        params.adaptiveGradientThreshold = extendedState.adaptiveThreshold
        params.jitterAmount = extendedState.jitterAmount
        params.intensityRatio = extendedState.channelIntensities
        let clip = extendedState.clipBounds
        params.trimXMin = clip.xMin
        params.trimXMax = clip.xMax
        params.trimYMin = clip.yMin
        params.trimYMax = clip.yMax
        params.trimZMin = clip.zMin
        params.trimZMax = clip.zMax
        let planes = clipPlanes(preset: extendedState.clipPlanePreset,
                                offset: extendedState.clipPlaneOffset)
        params.clipPlane0 = planes.0
        params.clipPlane1 = planes.1
        params.clipPlane2 = planes.2
        params.backgroundColor = SIMD3<Float>(repeating: 0)
        // Spacing (mm)
        let spacing = dataset.spacing
        params.spacingX = Float(spacing.x)
        params.spacingY = Float(spacing.y)
        params.spacingZ = Float(spacing.z)
        // Adaptive step sizing (default identity)
        params.adaptiveStepMinScale = max(0.1, request.adaptiveStepMinScale)
        params.adaptiveStepMaxScale = max(params.adaptiveStepMinScale, request.adaptiveStepMaxScale)
        params.adaptiveGradientScale = max(0.0, request.adaptiveGradientScale)
        params.adaptiveFlatThreshold = max(0.0, request.adaptiveFlatThreshold)
        params.adaptiveFlatBoost = max(1.0, request.adaptiveFlatBoost)
        params.minStepNormalized = Self.computeMinStepNormalized(for: dataset)
        params.preTFBlurRadius = max(0.0, request.preTFBlurRadius)

        // Occupancy grid dimensions (if provided)
        let brickSize = 8
        let bricksX = max(1, (dataset.dimensions.width + brickSize - 1) / brickSize)
        let bricksY = max(1, (dataset.dimensions.height + brickSize - 1) / brickSize)
        let bricksZ = max(1, (dataset.dimensions.depth + brickSize - 1) / brickSize)
        params.occupancyBrickDimX = UInt16(clamping: bricksX)
        params.occupancyBrickDimY = UInt16(clamping: bricksY)
        params.occupancyBrickDimZ = UInt16(clamping: bricksZ)
        params.occupancyInvBrickCountX = 1.0 / Float(bricksX)
        params.occupancyInvBrickCountY = 1.0 / Float(bricksY)
        params.occupancyInvBrickCountZ = 1.0 / Float(bricksZ)
        return params
    }

    /// Minimum normalized step to avoid skipping fine features; derived from smallest voxel spacing.
    private static func computeMinStepNormalized(for dataset: VolumeDataset) -> Float {
        let spacing = dataset.spacing
        let minSpacing = Float(min(spacing.x, min(spacing.y, spacing.z)))
        let bounds = MPRCameraConfiguration.worldBounds(for: dataset)
        guard bounds.count >= 6 else { return 1.0e-5 }
        let dx = bounds[1] - bounds[0]
        let dy = bounds[3] - bounds[2]
        let dz = bounds[5] - bounds[4]
        let worldDiagonal = sqrt(dx * dx + dy * dy + dz * dz)
        guard worldDiagonal > 1.0e-5 else { return 1.0e-5 }
        return max(1.0e-5, (minSpacing * sqrt(3.0)) / worldDiagonal)
    }

    private func buildVolumeUniforms(for request: VolumeRenderRequest) -> VolumeUniforms {
        var uniforms = VolumeUniforms()
        let dataset = request.dataset
        let window = extendedState.huWindow
            ?? overrides.window
            ?? dataset.recommendedWindow
            ?? dataset.intensityRange

        uniforms.voxelMinValue = window.lowerBound
        uniforms.voxelMaxValue = window.upperBound
        uniforms.datasetMinValue = dataset.intensityRange.lowerBound
        uniforms.datasetMaxValue = dataset.intensityRange.upperBound
        uniforms.dimX = Int32(dataset.dimensions.width)
        uniforms.dimY = Int32(dataset.dimensions.height)
        uniforms.dimZ = Int32(dataset.dimensions.depth)

        let normalizedDistance = SampleDistanceCalculator.normalizedSampleDistance(request.samplingDistance,
                                                                                   dataset: dataset)
        let steps = max(1, Int32(roundf(1.0 / max(normalizedDistance, 1e-5))))
        uniforms.renderingQuality = steps

        switch request.compositing {
        case .maximumIntensity:
            uniforms.method = 2
        case .minimumIntensity:
            uniforms.method = 3
        case .averageIntensity:
            uniforms.method = 4
        case .frontToBack:
            uniforms.method = 1
        }

        let lightingEnabled = overrides.lightingEnabled && extendedState.lightingEnabled
        uniforms.isLightingOn = lightingEnabled ? 1 : 0

        // Per-mode early-exit thresholds
        let thresholds = request.earlyExit
        uniforms.earlyExitFTB = thresholds.frontToBack
        uniforms.earlyExitAvgIP = thresholds.averageIntensity
        uniforms.earlyExitMIP = thresholds.maximumIntensity // used for both MIP and MinIP

        uniforms.gradientSmoothness = request.gradientSmoothness
        uniforms.usePreIntegratedTF = request.usePreIntegratedTF ? 1 : 0

        uniforms.samplingMethod = Int32(request.reconstructionKernel.rawValue)
        uniforms.occupancySkipEnabled = request.emptySpaceSkipping.occupancyEnabled ? 1 : 0
        uniforms.minMaxSkipEnabled = request.emptySpaceSkipping.minMaxEnabled ? 1 : 0
        uniforms.dualParameterTFEnabled = request.useDualParameterTF ? 1 : 0
        uniforms.lightOcclusionEnabled = request.useLightOcclusion ? 1 : 0
        uniforms.lightOcclusionStrength = request.lightOcclusionStrength

        if let gate = extendedState.densityGate {
            uniforms.densityFloor = gate.lowerBound
            uniforms.densityCeil = gate.upperBound
        }

        if let huGate = extendedState.densityGate {
            uniforms.useHuGate = 1
            uniforms.gateHuMin = Int32(huGate.lowerBound)
            uniforms.gateHuMax = Int32(huGate.upperBound)
        } else {
            uniforms.useHuGate = 0
        }

        uniforms.useTFProj = 1
        uniforms.isBackwardOn = 0
        return uniforms
    }

    private func clipPlanes(preset: Int, offset: Float) -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        let planeOffset = -offset
        switch preset {
        case 1: // axial
            return (SIMD4<Float>(0, 0, 1, planeOffset), .zero, .zero)
        case 2: // sagittal
            return (SIMD4<Float>(1, 0, 0, planeOffset), .zero, .zero)
        case 3: // coronal
            return (SIMD4<Float>(0, 1, 0, planeOffset), .zero, .zero)
        default:
            return (.zero, .zero, .zero)
        }
    }

    private func computeOptionFlags() -> UInt16 {
        var value: UInt16 = 0
        if extendedState.adaptiveEnabled {
            value |= (1 << 2)
        }
        return value
    }

    private func encodeCamera(_ uniforms: CameraUniforms, into state: MetalState) {
        var localUniforms = uniforms
        let pointer = state.cameraBuffer.contents()
        memcpy(pointer, &localUniforms, CameraUniforms.stride)
    }

    private func dispatchCompute(state: MetalState,
                                 viewportSize: (width: Int, height: Int)) async throws -> any MTLTexture {
        let textureMismatch = state.argumentManager.outputTexture == nil ||
            state.argumentManager.outputTexture?.width != viewportSize.width ||
            state.argumentManager.outputTexture?.height != viewportSize.height

        if textureMismatch {
            state.argumentManager.encodeOutputTexture(width: viewportSize.width,
                                                      height: viewportSize.height)
        }

        guard let texture = state.argumentManager.outputTexture else {
            throw RenderingError.outputTextureUnavailable
        }

        guard let commandBuffer = state.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RenderingError.commandEncodingFailed
        }

        encoder.label = "VolumeCompute.CommandEncoder"
        encoder.setComputePipelineState(state.pipeline)
        encoder.setBuffer(state.argumentManager.argumentBuffer, offset: 0, index: 0)
        encoder.setBuffer(state.cameraBuffer, offset: 0, index: 1)

        let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (viewportSize.width + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width,
                             height: (viewportSize.height + threadsPerThreadgroup.height - 1) / threadsPerThreadgroup.height,
                             depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()

        return try await complete(commandBuffer: commandBuffer, texture: texture)
    }

    private func complete(commandBuffer: any MTLCommandBuffer,
                          texture: any MTLTexture) async throws -> any MTLTexture {
        try await withCheckedThrowingContinuation { continuation in
            commandBuffer.addCompletedHandler { buffer in
                if let error = buffer.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: texture)
                }
            }
            commandBuffer.commit()
        }
    }

    private func makeImage(from texture: any MTLTexture,
                           width: Int,
                           height: Int) throws -> CGImage? {
#if canImport(CoreGraphics)
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = Data(count: bytesPerRow * height)
        data.withUnsafeMutableBytes { pointer in
            let region = MTLRegionMake2D(0, 0, width, height)
            texture.getBytes(pointer.baseAddress!,
                             bytesPerRow: bytesPerRow,
                             from: region,
                             mipmapLevel: 0)
        }

        guard let provider = CGDataProvider(data: data as CFData) else {
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow,
                       space: colorSpace,
                       bitmapInfo: bitmapInfo,
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: true,
                       intent: .defaultIntent)
#else
        return nil
#endif
    }

    private func makeCameraUniforms(for request: VolumeRenderRequest,
                                    viewportSize: (width: Int, height: Int),
                                    frameIndex: UInt32) -> CameraUniforms {
        var camera = CameraUniforms()
        camera.modelMatrix = matrix_identity_float4x4
        camera.inverseModelMatrix = matrix_identity_float4x4
        camera.inverseViewProjectionMatrix = makeInverseViewProjectionMatrix(camera: request.camera,
                                                                             viewportSize: viewportSize,
                                                                             dataset: request.dataset)

        // Compute SCTC matrices from DICOM geometry
        let geometry = request.dataset.dicomGeometry
        camera.worldToTextureMatrix = geometry.worldToTextureMatrix
        camera.textureToWorldMatrix = geometry.textureToWorldMatrix

        camera.cameraPositionLocal = request.camera.position
        camera.frameIndex = frameIndex
        return camera
    }

    private func makeInverseViewProjectionMatrix(camera: VolumeRenderRequest.Camera,
                                                 viewportSize: (width: Int, height: Int),
                                                 dataset: VolumeDataset? = nil) -> simd_float4x4 {
        let aspect = max(Float(viewportSize.width) / Float(viewportSize.height), 1e-3)
        let view = simd_float4x4(lookAt: camera.position,
                                 target: camera.target,
                                 up: camera.up)

        // Calcular clipping planes baseado nos bounds reais do volume
        let (nearZ, farZ) = computeClippingRange(
            camera: camera,
            viewMatrix: view,
            dataset: dataset
        )

        let projection: simd_float4x4
        if camera.parallelProjection {
            let scale = max(camera.parallelScale, 1e-3)
            projection = simd_float4x4(
                orthographicWithParallelScale: scale,
                aspect: aspect,
                nearZ: nearZ,
                farZ: farZ,
                windowCenter: camera.windowCenter
            )
        } else {
            projection = simd_float4x4(
                perspectiveFovY: max(camera.fieldOfView * .pi / 180, 0.01),
                aspect: aspect,
                nearZ: nearZ,
                farZ: farZ
            )
        }
        let matrix = projection * view

        if diagnosticLoggingEnabled {
            logger.info("[DIAG] View Matrix:\n\(view.debugDescription)")
            logger.info("[DIAG] Projection Matrix (\(camera.parallelProjection ? "ortho" : "persp")):\n\(projection.debugDescription)")
            logger.info("[DIAG] Clipping Range: near=\(nearZ), far=\(farZ)")
            logger.info("[DIAG] InvViewProj Matrix:\n\(simd_inverse(matrix).debugDescription)")
        }
        
        return simd_inverse(matrix)
    }
    
    /// Calcula o clipping range baseado nos bounds do volume.
    /// Garante que o near e far sejam calculados corretamente em relação à posição da câmera e aos bounds do volume.
    private func computeClippingRange(camera: VolumeRenderRequest.Camera,
                                      viewMatrix: simd_float4x4,
                                      dataset: VolumeDataset?) -> (near: Float, far: Float) {
        // Se não temos dataset, usar cálculo de fallback
        guard let dataset = dataset else {
            let center = SIMD3<Float>(repeating: 0.5)
            let distanceToCenter = simd_length(camera.position - center)
            let farPadding = max(1.0, distanceToCenter * 0.1 + 1.0)
            let nearZ: Float = 0.01
            let farZ = max(distanceToCenter + farPadding, nearZ + 100.0)
            return (nearZ, farZ)
        }
        
        // Calcular bounds do volume no espaço do mundo
        // O volume está em coordenadas normalizadas [0, 1]³, então precisamos transformar
        // para o espaço do mundo usando a orientação e spacing
        let dims = dataset.dimensions
        let spacing = dataset.spacing
        
        // Bounds em coordenadas de índice (0 a dim-1)
        let maxX = Float(dims.width - 1)
        let maxY = Float(dims.height - 1)
        let maxZ = Float(dims.depth - 1)
        
        // Bounds em coordenadas físicas (considerando spacing)
        let boundsMin = SIMD3<Float>(0, 0, 0)
        let boundsMax = SIMD3<Float>(
            Float(spacing.x) * maxX,
            Float(spacing.y) * maxY,
            Float(spacing.z) * maxZ
        )
        
        // Transformar bounds para o espaço do mundo usando a orientação
        let orientation = dataset.orientation
        let origin = SIMD3<Float>(orientation.origin)
        let row = SIMD3<Float>(orientation.row)
        let col = SIMD3<Float>(orientation.column)
        let normal = simd_normalize(simd_cross(row, col))
        
        // Criar matriz de transformação do espaço do volume para o espaço do mundo
        let volumeToWorld = simd_float4x4(
            columns: (
                SIMD4<Float>(row * Float(spacing.x), 0),
                SIMD4<Float>(col * Float(spacing.y), 0),
                SIMD4<Float>(normal * Float(spacing.z), 0),
                SIMD4<Float>(origin, 1)
            )
        )
        
        // Transformar os 8 cantos do bounding box para o espaço do mundo
        let corners: [SIMD3<Float>] = [
            SIMD3<Float>(boundsMin.x, boundsMin.y, boundsMin.z),
            SIMD3<Float>(boundsMin.x, boundsMin.y, boundsMax.z),
            SIMD3<Float>(boundsMin.x, boundsMax.y, boundsMin.z),
            SIMD3<Float>(boundsMin.x, boundsMax.y, boundsMax.z),
            SIMD3<Float>(boundsMax.x, boundsMin.y, boundsMin.z),
            SIMD3<Float>(boundsMax.x, boundsMin.y, boundsMax.z),
            SIMD3<Float>(boundsMax.x, boundsMax.y, boundsMin.z),
            SIMD3<Float>(boundsMax.x, boundsMax.y, boundsMax.z)
        ]
        
        var worldCorners: [SIMD3<Float>] = []
        for corner in corners {
            let worldCorner = volumeToWorld * SIMD4<Float>(corner, 1)
            worldCorners.append(SIMD3<Float>(worldCorner.x, worldCorner.y, worldCorner.z))
        }
        
        // Calcular distâncias dos cantos ao longo da direção da câmera
        // A direção da câmera é de position para target (normalizada)
        let cameraDirection = simd_normalize(camera.target - camera.position)
        
        var minDistance: Float = .infinity
        var maxDistance: Float = -.infinity
        
        for corner in worldCorners {
            // Vetor da câmera para o canto
            let toCorner = corner - camera.position
            // Projeção ao longo da direção da câmera (distância ao longo do eixo Z da câmera)
            let distance = simd_dot(toCorner, cameraDirection)
            minDistance = min(minDistance, distance)
            maxDistance = max(maxDistance, distance)
        }
        
        // As distâncias são ao longo da direção da câmera
        // near = distância ao ponto mais próximo (menor valor, pode ser negativo se atrás)
        // far = distância ao ponto mais distante (maior valor)
        let nearDistance = max(minDistance, 0.01)  // Garantir que near seja positivo
        let farDistance = max(maxDistance, nearDistance + 0.1)
        
        // Garantir valores mínimos e gap adequado
        let minGap: Float = 0.1
        let nearClippingPlaneTolerance: Float = 0.01
        
        var nearZ = nearDistance
        var farZ = farDistance
        
        // Garantir gap mínimo entre near e far
        if farZ < nearZ + minGap {
            farZ = nearZ + minGap
        }
        
        // Garantir que near seja pelo menos uma fração de far (para resolução do z-buffer)
        let minNear = farZ * nearClippingPlaneTolerance
        if nearZ < minNear {
            nearZ = minNear
            farZ = max(farZ, nearZ + minGap)
        }
        
        return (nearZ, farZ)
    }

    static func makeFallbackImage(dataset: VolumeDataset,
                                  window: ClosedRange<Int32>,
                                  state: ExtendedRenderingState,
                                  request: VolumeRenderRequest) -> CGImage? {
#if canImport(CoreGraphics)
        let width = dataset.dimensions.width
        let height = dataset.dimensions.height
        let depth = dataset.dimensions.depth
        guard width > 0, height > 0, depth > 0 else { return nil }

        let sliceIndex = depth / 2
        let pixelCount = width * height
        var pixels = [UInt8](repeating: 0, count: pixelCount)

        let lower = Float(window.lowerBound)
        let upper = Float(window.upperBound)
        let span = max(upper - lower, Float.leastNonzeroMagnitude)

        dataset.data.withUnsafeBytes { buffer in
            guard let reader = VolumeDataReader(dataset: dataset, buffer: buffer) else { return }

            for y in 0..<height {
                for x in 0..<width {
                    let intensity = reader.intensity(x: x, y: y, z: sliceIndex)
                    let shiftAdjusted = Float(intensity) + state.shift

                    let zNorm = depth > 1 ? Float(sliceIndex) / Float(depth - 1) : 0
                    let xNorm = width > 1 ? Float(x) / Float(width - 1) : 0
                    let yNorm = height > 1 ? Float(y) / Float(height - 1) : 0
                    if !Self.isInsideClipBounds(x: xNorm, y: yNorm, z: zNorm, clip: state.clipBounds) {
                        pixels[y * width + x] = 0
                        continue
                    }

                    if let gate = state.densityGate,
                       shiftAdjusted < gate.lowerBound || shiftAdjusted > gate.upperBound {
                        pixels[y * width + x] = 0
                        continue
                    }

                    var normalized = (shiftAdjusted - lower) / span
                    normalized = max(0, min(1, normalized))
                    normalized = Self.applyToneCurve(normalized,
                                                     points: state.toneCurvePoints[0] ?? [],
                                                     gain: state.toneCurveGains[0] ?? 1)

                    let channelGain = state.channelIntensities[0]
                    normalized *= max(channelGain, 0.001)

                    if !state.lightingEnabled {
                        normalized *= 0.5
                    }

                    let clamped = max(0, min(1, normalized))
                    pixels[y * width + x] = UInt8(clamping: Int(round(clamped * 255)))
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceGray()

        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 8,
                       bytesPerRow: width,
                       space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
#else
        return nil
#endif
    }

    private static func applyToneCurve(_ value: Float, points: [SIMD2<Float>], gain: Float) -> Float {
        guard !points.isEmpty else { return value * gain }
        let safeGain = max(gain, 0)
        let sorted = points.sorted { $0.x < $1.x }
        let clampedValue = max(sorted.first!.x, min(sorted.last!.x, value))

        for index in 0..<(sorted.count - 1) {
            let start = sorted[index]
            let end = sorted[index + 1]
            if clampedValue >= start.x && clampedValue <= end.x {
                let t = (clampedValue - start.x) / max(end.x - start.x, 1e-6)
                let mixed = start.y + t * (end.y - start.y)
                return max(0, min(1, mixed)) * safeGain
            }
        }
        return clampedValue * safeGain
    }

    private static func isInsideClipBounds(x: Float,
                                           y: Float,
                                           z: Float,
                                           clip: ClipBoundsSnapshot) -> Bool {
        return (x >= clip.xMin && x <= clip.xMax) &&
               (y >= clip.yMin && y <= clip.yMax) &&
               (z >= clip.zMin && z <= clip.zMax)
    }
}

extension simd_float4x4 {
    init(lookAt eye: SIMD3<Float>,
         target: SIMD3<Float>,
         up: SIMD3<Float>) {
        let zAxis = simd_normalize(eye - target)
        var xAxis = simd_normalize(simd_cross(up, zAxis))
        if !xAxis.allFinite {
            xAxis = SIMD3<Float>(1, 0, 0)
        }
        var yAxis = simd_cross(zAxis, xAxis)
        if !yAxis.allFinite {
            yAxis = SIMD3<Float>(0, 1, 0)
        }

        let translation = SIMD3<Float>(
            -simd_dot(xAxis, eye),
            -simd_dot(yAxis, eye),
            -simd_dot(zAxis, eye)
        )

        self = simd_float4x4(columns: (
            SIMD4<Float>(xAxis, 0),
            SIMD4<Float>(yAxis, 0),
            SIMD4<Float>(zAxis, 0),
            SIMD4<Float>(translation, 1)
        ))
    }

    init(perspectiveFovY fovY: Float,
         aspect: Float,
         nearZ: Float,
         farZ: Float) {
        let yScale = 1 / tan(fovY * 0.5)
        let xScale = yScale / max(aspect, 1e-3)
        let zRange = farZ - nearZ
        let z = -(farZ + nearZ) / zRange
        let wz = -(2 * farZ * nearZ) / zRange

        self = simd_float4x4(columns: (
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, wz, 0)
        ))
    }

    /// Orthographic projection
    /// - Parameters:
    ///   - parallelScale: Half of the viewport height in world units
    ///   - aspect: Viewport width / height
    ///   - nearZ: Near clipping plane
    ///   - farZ: Far clipping plane
    ///   - windowCenter: Frustum offset defaults to .zero
    init(orthographicWithParallelScale parallelScale: Float,
         aspect: Float,
         nearZ: Float,
         farZ: Float,
         windowCenter: SIMD2<Float> = .zero) {
        let width = parallelScale * aspect
        let height = parallelScale

        let left = (windowCenter.x - 1.0) * width
        let right = (windowCenter.x + 1.0) * width
        let bottom = (windowCenter.y - 1.0) * height
        let top = (windowCenter.y + 1.0) * height

        let rl = right - left
        let tb = top - bottom
        let fn = farZ - nearZ

        self = simd_float4x4(columns: (
            SIMD4<Float>(2.0 / rl, 0, 0, 0),
            SIMD4<Float>(0, 2.0 / tb, 0, 0),
            SIMD4<Float>(0, 0, -2.0 / fn, 0),
            SIMD4<Float>(-(right + left) / rl,
                        -(top + bottom) / tb,
                        -(farZ + nearZ) / fn,
                        1)
        ))
    }
}

private extension SIMD3 where Scalar == Float {
    var allFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}
