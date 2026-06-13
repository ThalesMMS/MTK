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
            state.transferCache?.intensityRange == request.dataset.intensityRange &&
            state.transferCache?.shift == extendedState.shift
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
        let toneBuffers = try makeToneBuffers(state: state)
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
            toneBuffers: toneBuffers,
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
                                   request: VolumeRenderRequest,
                                   outputTexture providedOutputTexture: (any MTLTexture)? = nil,
                                   waitsForCompletion: Bool = true) async throws -> VolumeRenderFrame {
        let layers = try request.visibleScalarLayersForRendering(
            resampleCache: state.registeredLayerResampleCache
        )
        guard let firstLayer = layers.first,
              let firstScalar = firstLayer.scalarVolume else {
            return try await renderWithMetal(state: state,
                                             request: request,
                                             outputTexture: providedOutputTexture,
                                             waitsForCompletion: waitsForCompletion)
        }
        let overlayLayers = Array(layers.dropFirst())
        guard !overlayLayers.isEmpty else {
            let baseRequest = request.replacingPrimaryVolume(with: firstLayer,
                                                             scalarVolume: firstScalar)
            return try await renderWithMetal(state: state,
                                             request: baseRequest,
                                             outputTexture: providedOutputTexture,
                                             waitsForCompletion: waitsForCompletion)
        }

        let viewport = VolumetricMath.clampViewportSize(request.viewportSize)
        guard viewport.width > 0, viewport.height > 0 else {
            throw RenderingError.outputTextureUnavailable
        }

        try await state.layerStackRenderLock.acquire()
        defer {
            Task {
                await state.layerStackRenderLock.release()
            }
        }

        let scratchTextureCount = min(3, max(2, layers.count))
        let scratchTextures = try state.layerStackScratchTextures(width: viewport.width,
                                                                  height: viewport.height,
                                                                  count: scratchTextureCount)
        let compositePass = try state.cachedLayerCompositePass()
        let baseRequest = request.replacingPrimaryVolume(with: firstLayer,
                                                         scalarVolume: firstScalar)
        var currentFrame = try await renderWithMetal(
            state: state,
            request: baseRequest,
            outputTexture: scratchTextures[0],
            waitsForCompletion: waitsForCompletion
        )
        var currentScratchIndex: Int? = 0

        for (layerIndex, layer) in overlayLayers.enumerated() {
            guard let scalar = layer.scalarVolume else { continue }
            let isLastLayer = layerIndex == overlayLayers.count - 1
            let availableScratchIndices = scratchTextures.indices.filter { $0 != currentScratchIndex }
            guard let overlayScratchIndex = availableScratchIndices.first else {
                throw RenderingError.outputTextureUnavailable
            }
            let destinationScratchIndex = availableScratchIndices.dropFirst().first
            let overlayTexture = scratchTextures[overlayScratchIndex]
            let destinationTexture: any MTLTexture
            let nextCurrentScratchIndex: Int?
            if isLastLayer, let providedOutputTexture {
                destinationTexture = providedOutputTexture
                nextCurrentScratchIndex = nil
            } else if isLastLayer {
                destinationTexture = try makeStandaloneOutputTexture(width: viewport.width,
                                                                     height: viewport.height,
                                                                     device: state.device)
                nextCurrentScratchIndex = nil
            } else if let destinationScratchIndex {
                destinationTexture = scratchTextures[destinationScratchIndex]
                nextCurrentScratchIndex = destinationScratchIndex
            } else {
                throw RenderingError.outputTextureUnavailable
            }

            let overlayRequest = request.replacingPrimaryVolume(with: layer,
                                                                scalarVolume: scalar)
            let overlayFrame = try await renderWithMetal(
                state: state,
                request: overlayRequest,
                outputTexture: overlayTexture,
                waitsForCompletion: waitsForCompletion
            )
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
                    pixelFormat: destinationTexture.pixelFormat,
                    debugFrameIndex: currentFrame.metadata.debugFrameIndex
                )
            )
            currentScratchIndex = nextCurrentScratchIndex
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

        guard let texture = OutputTextureFactory.makeTexture(
            device: device,
            width: width,
            height: height,
            label: "VolumeCompute.Output"
        ) else {
            throw RenderingError.outputTextureUnavailable
        }
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

    public func renderTexture(using request: VolumeRenderRequest,
                              volumeTexture: any MTLTexture,
                              outputTexture: (any MTLTexture)? = nil) async throws -> VolumeRenderFrame {
        if diagnosticLoggingEnabled {
            logger.info("[DIAG] renderTexture called - viewport: \(request.viewportSize.width)x\(request.viewportSize.height), compositing: \(String(describing: request.compositing)), quality: \(String(describing: request.quality))")
        }

        let presetResolution = applyCurrentPresetIfNeeded(to: request)
        var effectiveRequest = presetResolution.request

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
                                      window: window,
                                      preset: presetResolution.preset)
        return frame
    }

    func logInteractionInfo(_ message: @autoclosure () -> String) {
        guard Logger.performanceLoggingEnabled else { return }
        logger.info(message())
    }

}

extension VolumeRenderRequest {
    func visibleScalarLayerCountForRendering() throws -> Int {
        var count = 0
        for layer in self.layers {
            guard layer.isVisible,
                  layer.clampedOpacity > 0,
                  layer.scalarVolume != nil else {
                continue
            }
            let transform = LayerTransform(baseWorldToLayerWorld: layer.baseWorldToLayerWorld)
            guard transform.supportsCPUResampling else {
                throw MetalVolumeRenderingAdapter.AdapterError.unsupportedScalarLayerTransform(layer.id)
            }
            count += 1
        }
        return max(count, 1)
    }

    func visibleScalarLayersForRendering(resampleCache: RegisteredVolumeLayerResampleCache? = nil) throws -> [VolumeLayer] {
        var layers: [VolumeLayer] = []
        for layer in self.layers {
            guard layer.isVisible,
                  layer.clampedOpacity > 0,
                  layer.scalarVolume != nil else {
                continue
            }
            do {
                if let resampleCache {
                    layers.append(try resampleCache.resampledLayer(layer, into: dataset))
                } else {
                    layers.append(try RegisteredVolumeLayerResampler.resampledLayer(layer, into: dataset))
                }
            } catch RegisteredVolumeLayerResamplingError.unsupportedTransform {
                throw MetalVolumeRenderingAdapter.AdapterError.unsupportedScalarLayerTransform(layer.id)
            }
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
