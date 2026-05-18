//
//  MetalVolumeRenderingAdapter+Dispatch.swift
//  MTK
//
//  Dispatch and output helpers for the Metal volume rendering adapter.
//
//  Thales Matheus Mendonça Santos — April 2026

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@preconcurrency import Metal
import simd

extension MetalVolumeRenderingAdapter {
    func resolveWindow(for dataset: VolumeDataset) throws -> ClosedRange<Int32> {
        if let window = extendedState.huWindow ?? overrides.window ?? dataset.recommendedWindow {
            return window
        }
        throw AdapterError.windowNotSpecified
    }

    func renderWithMetal(state: MetalState,
                         request: VolumeRenderRequest,
                         datasetTexture providedDatasetTexture: (any MTLTexture)? = nil,
                         outputTexture providedOutputTexture: (any MTLTexture)? = nil,
                         waitsForCompletion: Bool = true) async throws -> VolumeRenderFrame {
        let viewport = VolumetricMath.clampViewportSize(request.viewportSize)
        guard viewport.width > 0, viewport.height > 0 else {
            throw RenderingError.outputTextureUnavailable
        }

        try Task.checkCancellation()

        let datasetPreparation: DatasetTexturePreparationResult
        let preparationStartedAt = CFAbsoluteTimeGetCurrent()
        let transferCacheHit = state.transferCache?.transfer == request.transferFunction &&
            state.transferCache?.intensityRange == request.dataset.intensityRange
        let datasetPreparationStartedAt = CFAbsoluteTimeGetCurrent()
        if let providedDatasetTexture {
            datasetPreparation = prepareDatasetTextureResult(for: request.dataset,
                                                             texture: providedDatasetTexture,
                                                             state: state)
        } else {
            datasetPreparation = try await prepareDatasetTextureResult(for: request.dataset, state: state)
        }
        let datasetTexture = datasetPreparation.texture
        let datasetCacheHit = datasetPreparation.cacheHit
        let datasetPreparationMilliseconds = ClinicalProfiler.milliseconds(from: datasetPreparationStartedAt)

        try Task.checkCancellation()

        let transferPreparationStartedAt = CFAbsoluteTimeGetCurrent()
        let transferTexture = try await prepareTransferTexture(for: request.transferFunction,
                                                               dataset: request.dataset,
                                                               state: state)
        let transferPreparationMilliseconds = ClinicalProfiler.milliseconds(from: transferPreparationStartedAt)
        let preparationMilliseconds = ClinicalProfiler.milliseconds(from: preparationStartedAt)

        try Task.checkCancellation()

        let parameterPreparationStartedAt = CFAbsoluteTimeGetCurrent()
        let parameters = try buildRenderingParameters(for: request)
        let optionValue = computeOptionFlags()
        let targetViewSize = UInt16(clamping: max(viewport.width, viewport.height))
        let quaternion = SIMD4<Float>(0, 0, 0, 1)

        let camera = try makeCameraUniforms(for: request,
                                            viewportSize: viewport,
                                            frameIndex: state.frameIndex)
        let parameterPreparationMilliseconds = ClinicalProfiler.milliseconds(from: parameterPreparationStartedAt)
        let debugFrameIndex = UInt64(state.frameIndex)
        if Logger.performanceLoggingEnabled {
            logger.info(
                "[MTKPerf] volume.prepare viewport=\(viewport.width)x\(viewport.height) quality=\(request.quality) compositing=\(request.compositing) samplingDistance=\(formatPerf(request.samplingDistance)) datasetMs=\(formatPerf(datasetPreparationMilliseconds)) transferMs=\(formatPerf(transferPreparationMilliseconds)) paramsMs=\(formatPerf(parameterPreparationMilliseconds)) totalPrepareMs=\(formatPerf(preparationMilliseconds)) datasetCacheHit=\(datasetCacheHit) transferCacheHit=\(transferCacheHit) providedDatasetTexture=\(providedDatasetTexture != nil) providedOutputTexture=\(providedOutputTexture != nil) frameIndex=\(state.frameIndex)"
            )
        }
        let passRenderingParameters = VolumeRaycastPassRenderingParameters(
            quality: request.quality,
            samplingDistance: request.samplingDistance,
            compositingMode: request.compositing
        )
        let passInput = VolumeRaycastPassInput(
            volumeTexture: datasetTexture,
            transferFunctionTexture: transferTexture,
            cameraUniforms: camera,
            renderingParameters: passRenderingParameters,
            shaderParameters: parameters,
            viewportSize: CGSize(width: CGFloat(viewport.width), height: CGFloat(viewport.height)),
            optionValue: optionValue,
            targetViewSize: targetViewSize,
            quaternion: quaternion,
            outputTexture: try providedOutputTexture ?? makeStandaloneOutputTexture(width: viewport.width,
                                                                                   height: viewport.height,
                                                                                   device: state.device),
            debugFrameIndex: debugFrameIndex
        )
        logInteractionInfo(
            "[MTK3DInteraction] adapter.raycast.dispatch frameIndex=\(debugFrameIndex) waitsForCompletion=\(waitsForCompletion) adapterQueueID=\(objectIdentifier(state.commandQueue as AnyObject)) outputTextureID=\(objectIdentifier(passInput.outputTexture.map { $0 as AnyObject })) outputLabel=\(passInput.outputTexture?.label ?? "nil") outputStorage=\(String(describing: passInput.outputTexture?.storageMode)) quality=\(request.quality) compositing=\(request.compositing) cameraPosition=\(request.camera.position) cameraUp=\(request.camera.up)"
        )
        let passOutput: VolumeRaycastPassOutput
        if waitsForCompletion {
            passOutput = try await state.raycastPass.execute(input: passInput,
                                                             commandQueue: state.commandQueue)
        } else {
            passOutput = try await state.raycastPass.enqueue(input: passInput,
                                                             commandQueue: state.commandQueue)
        }
        let outputTexture = passOutput.outputTexture
        state.frameIndex &+= 1
        logInteractionInfo(
            "[MTK3DInteraction] adapter.raycast.return frameIndex=\(debugFrameIndex) nextFrameIndex=\(state.frameIndex) waitsForCompletion=\(waitsForCompletion) outputTextureID=\(objectIdentifier(outputTexture as AnyObject)) outputLabel=\(outputTexture.label ?? "nil") outputStorage=\(outputTexture.storageMode) timingCpuMs=\(formatPerf(passOutput.timing.cpuDurationMilliseconds)) timingGpuMs=\(formatPerf(passOutput.timing.gpuDurationMilliseconds))"
        )

        if ClinicalProfiler.shared.isRecordingEnabled {
            ClinicalProfiler.shared.recordSample(
                stage: .texturePreparation,
                cpuTime: preparationMilliseconds,
                memory: ResourceMemoryEstimator.estimate(for: datasetTexture) + ResourceMemoryEstimator.estimate(for: transferTexture),
                viewport: ProfilingViewportContext(
                    width: viewport.width,
                    height: viewport.height,
                    viewportType: "volume3D",
                    quality: request.quality,
                    renderMode: request.compositing
                ),
                metadata: [
                    "datasetTexture": datasetTexture.label ?? "",
                    "transferTexture": transferTexture.label ?? ""
                ],
                device: state.device
            )
        }

        let metadata = VolumeRenderFrame.Metadata(
            viewportSize: CGSize(width: CGFloat(viewport.width),
                                 height: CGFloat(viewport.height)),
            samplingDistance: request.samplingDistance,
            compositing: request.compositing,
            quality: request.quality,
            pixelFormat: outputTexture.pixelFormat,
            debugFrameIndex: debugFrameIndex
        )
        return VolumeRenderFrame(texture: outputTexture,
                                 metadata: metadata)
    }

    func renderLayerStackWithMetal(state: MetalState,
                                   request: VolumeRenderRequest) async throws -> VolumeRenderFrame {
        let layers = try request.visibleScalarLayersForRendering()
        guard let firstLayer = layers.first,
              let firstScalar = firstLayer.scalarVolume else {
            return try await renderWithMetal(state: state, request: request)
        }

        let viewport = VolumetricMath.clampViewportSize(request.viewportSize)
        guard viewport.width > 0, viewport.height > 0 else {
            throw RenderingError.outputTextureUnavailable
        }

        let baseRequest = request.replacingPrimaryVolume(with: firstLayer,
                                                         scalarVolume: firstScalar)
        var currentFrame = try await renderWithMetal(
            state: state,
            request: baseRequest,
            outputTexture: makeStandaloneOutputTexture(width: viewport.width,
                                                       height: viewport.height,
                                                       device: state.device)
        )
        let compositePass = try VolumeLayerCompositePass(device: state.device)

        for layer in layers.dropFirst() {
            guard let scalar = layer.scalarVolume else { continue }
            let overlayRequest = request.replacingPrimaryVolume(with: layer,
                                                                scalarVolume: scalar)
            let overlayFrame = try await renderWithMetal(
                state: state,
                request: overlayRequest,
                outputTexture: makeStandaloneOutputTexture(width: viewport.width,
                                                           height: viewport.height,
                                                           device: state.device)
            )
            let destinationTexture = try makeStandaloneOutputTexture(width: viewport.width,
                                                                     height: viewport.height,
                                                                     device: state.device)
            try await compositePass.composite(baseTexture: currentFrame.texture,
                                             overlayTexture: overlayFrame.texture,
                                             destinationTexture: destinationTexture,
                                             overlayOpacity: layer.clampedOpacity,
                                             blendMode: layer.blendMode,
                                             commandQueue: state.commandQueue)
            currentFrame = VolumeRenderFrame(
                texture: destinationTexture,
                metadata: VolumeRenderFrame.Metadata(
                    viewportSize: currentFrame.metadata.viewportSize,
                    samplingDistance: request.samplingDistance,
                    compositing: request.compositing,
                    quality: request.quality,
                    pixelFormat: destinationTexture.pixelFormat
                )
            )
        }

        if ClinicalProfiler.shared.isRecordingEnabled {
            ClinicalProfiler.shared.recordSample(
                stage: .volumeRaycast,
                cpuTime: 0,
                memory: layers.reduce(0) { total, layer in
                    total + ResourceMemoryEstimator.estimate(for: layer.scalarVolume?.dataset ?? request.dataset)
                },
                viewport: ProfilingViewportContext(
                    width: viewport.width,
                    height: viewport.height,
                    viewportType: "volume3D",
                    quality: request.quality,
                    renderMode: request.compositing
                ),
                metadata: [
                    "path": "MetalVolumeRenderingAdapter.renderLayerStackWithMetal",
                    "layerCount": String(layers.count),
                    "layerIDs": layers.map(\.id).joined(separator: ",")
                ],
                device: state.device
            )
        }

        return currentFrame
    }

    func makeStandaloneOutputTexture(width: Int,
                                     height: Int,
                                     device: any MTLDevice) throws -> any MTLTexture {
        guard width > 0, height > 0 else {
            throw RenderingError.outputTextureUnavailable
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead, .renderTarget, .pixelFormatView]
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RenderingError.outputTextureUnavailable
        }
        texture.label = "VolumeCompute.Output"
        return texture
    }

    func reusableInteractiveOutputTexture(width: Int,
                                          height: Int,
                                          state: MetalState) throws -> any MTLTexture {
        guard width > 0, height > 0 else {
            throw RenderingError.outputTextureUnavailable
        }

        if let texture = state.interactiveOutputTexture,
           texture.width == width,
           texture.height == height,
           texture.pixelFormat == .bgra8Unorm,
           texture.storageMode == .private {
            return texture
        }

        let texture = try makeStandaloneOutputTexture(width: width,
                                                      height: height,
                                                      device: state.device)
        texture.label = "VolumeCompute.InteractiveOutput"
        state.interactiveOutputTexture = texture
        return texture
    }

    func renderTexture(using request: VolumeRenderRequest,
                       volumeTexture: any MTLTexture,
                       outputTexture: (any MTLTexture)? = nil) async throws -> VolumeRenderFrame {
        if diagnosticLoggingEnabled {
            logger.info("[DIAG] renderTexture called - viewport: \(request.viewportSize.width)x\(request.viewportSize.height), compositing: \(String(describing: request.compositing)), quality: \(String(describing: request.quality))")
        }

        var effectiveRequest = request

        if let compositing = overrides.compositing {
            effectiveRequest.compositing = compositing
        }
        if let samplingDistance = overrides.samplingDistance {
            effectiveRequest.samplingDistance = samplingDistance
        }

        effectiveRequest = try applyCompatibilityClippingIfNeeded(to: effectiveRequest)
        let window = try resolveWindow(for: effectiveRequest.dataset)
        let frame = try await renderWithSharedVolumeTexture(using: effectiveRequest,
                                                            volumeTexture: volumeTexture,
                                                            outputTexture: outputTexture)
        lastSnapshot = RenderSnapshot(dataset: request.dataset,
                                      metadata: frame.metadata,
                                      window: window)
        return frame
    }

    func logInteractionInfo(_ message: @autoclosure () -> String) {
        guard Logger.performanceLoggingEnabled else { return }
        logger.info(message())
    }

}

extension VolumeRenderRequest {
    func visibleScalarLayersForRendering() throws -> [VolumeLayer] {
        var layers: [VolumeLayer] = []
        for layer in self.layers {
            guard layer.isVisible,
                  layer.clampedOpacity > 0,
                  layer.scalarVolume != nil else {
                continue
            }
            guard layer.baseWorldToLayerWorld.isApproximatelyIdentity else {
                throw MetalVolumeRenderingAdapter.AdapterError.unsupportedScalarLayerTransform(layer.id)
            }
            layers.append(layer)
        }
        if layers.isEmpty {
            layers.append(
                VolumeLayer(id: Self.primaryVolumeLayerID,
                            dataset: dataset,
                            transferFunction: transferFunction)
            )
        }
        return layers
    }

    func replacingPrimaryVolume(with layer: VolumeLayer,
                                scalarVolume: ScalarVolumeLayer) -> VolumeRenderRequest {
        var request = self
        request.dataset = scalarVolume.dataset
        request.transferFunction = scalarVolume.transferFunction
        request.layers = [layer]
        return request
    }
}

private func formatPerf(_ value: Double) -> String {
    String(format: "%.3f", value)
}

private func formatPerf(_ value: Double?) -> String {
    value.map(formatPerf) ?? "nil"
}

private func formatPerf(_ value: Float) -> String {
    String(format: "%.5f", value)
}

private func objectIdentifier(_ object: AnyObject?) -> String {
    guard let object else { return "nil" }
    return String(describing: ObjectIdentifier(object))
}

private extension simd_float4x4 {
    var isApproximatelyIdentity: Bool {
        isApproximatelyEqual(to: matrix_identity_float4x4, tolerance: 1e-5)
    }

    func isApproximatelyEqual(to other: simd_float4x4,
                              tolerance: Float) -> Bool {
        columns.0.isApproximatelyEqual(to: other.columns.0, tolerance: tolerance) &&
            columns.1.isApproximatelyEqual(to: other.columns.1, tolerance: tolerance) &&
            columns.2.isApproximatelyEqual(to: other.columns.2, tolerance: tolerance) &&
            columns.3.isApproximatelyEqual(to: other.columns.3, tolerance: tolerance)
    }
}

private extension SIMD4 where Scalar == Float {
    func isApproximatelyEqual(to other: SIMD4<Float>,
                              tolerance: Float) -> Bool {
        abs(x - other.x) <= tolerance &&
            abs(y - other.y) <= tolerance &&
            abs(z - other.z) <= tolerance &&
            abs(w - other.w) <= tolerance
    }
}
