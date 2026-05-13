//
//  VolumeViewportController+Rendering.swift
//  MTKUI
//
//  Rendering helpers for VolumeViewportController.
//

import CoreGraphics
import Foundation
import Metal
import MTKCore

extension VolumeViewportController {
    var effectiveQualityState: RenderQualityState {
        adaptiveSamplingEnabled ? qualityScheduler.state : .settled
    }

    /// Schedules a new render when the controller is active and a dataset is applied.
    /// 
    /// If scheduled, increments the internal render generation and coalesces rapid updates behind a single in-flight render.
    func scheduleRender() {
        guard renderMode == .active, datasetApplied else {
            logger.debug("[MTK3DInteraction] schedule.drop renderMode=\(String(describing: renderMode)) datasetApplied=\(datasetApplied)")
            return
        }
        renderGeneration &+= 1
        let generation = renderGeneration
        let display = currentDisplay ?? .volume(method: currentVolumeMethod)
        let parameters = qualityScheduler.currentParameters
        logger.debug("[MTK3DInteraction] schedule generation=\(generation) display=\(interactionDisplayName(display)) adaptive=\(adaptiveSamplingEnabled) state=\(effectiveQualityState) samplingStep=\(parameters.volumeSamplingStep) tier=\(parameters.qualityTier)")
        renderPending = true
        guard !renderInFlight else {
            logger.debug("[MTK3DInteraction] schedule.coalesce generation=\(generation) display=\(interactionDisplayName(display)) state=\(effectiveQualityState)")
            return
        }
        startRenderDrain()
    }

    func startRenderDrain() {
        guard !renderInFlight else { return }
        renderInFlight = true
        renderTask = Task { [weak self] in
            await self?.drainRenderQueue()
        }
    }

    func drainRenderQueue() async {
        defer {
            renderInFlight = false
            renderTask = nil
            if renderPending, renderMode == .active, datasetApplied {
                startRenderDrain()
            }
        }

        while renderPending, !Task.isCancelled {
            renderPending = false
            let generation = renderGeneration
            await render(generation: generation, allowStalePreviewPresentation: true)
        }
    }

    /// Performs a render for the provided generation using the controller's current display state and presents the result.
    /// 
    /// When a volume or MPR display is active, this method emits corresponding telemetry events for scheduled, completed, and failed renders, and presents the produced frame to the viewport surface. The method guards against stale work by verifying the task has not been cancelled and the supplied `generation` matches the controller's current `renderGeneration`, while allowing preview-quality interactive frames to present when a newer generation is already queued.
    /// - Parameter generation: The render generation identifier used to determine whether the produced result is current or an acceptable coalesced preview.
    func render(generation: UInt64, allowStalePreviewPresentation: Bool = false) async {
        guard let dataset else {
            logger.debug("[MTK3DInteraction] render.drop generation=\(generation) reason=noDataset")
            return
        }
        guard renderMode == .active else {
            logger.debug("[MTK3DInteraction] render.drop generation=\(generation) reason=inactive renderMode=\(String(describing: renderMode))")
            return
        }
        let display = currentDisplay ?? .volume(method: currentVolumeMethod)
        let started = Date()
        let perfStartedAt = CFAbsoluteTimeGetCurrent()
        var telemetryQualityState = effectiveQualityState
        logger.debug("[MTK3DInteraction] render.start generation=\(generation) current=\(renderGeneration) display=\(interactionDisplayName(display)) adaptive=\(adaptiveSamplingEnabled) state=\(telemetryQualityState)")
        guard !Task.isCancelled, generation == renderGeneration else {
            logger.debug("[MTK3DInteraction] render.skip generation=\(generation) current=\(renderGeneration) cancelled=\(Task.isCancelled) stage=start")
            return
        }

        do {
            switch display {
            case let .volume(method):
                let plan = try await makeVolumeTextureRenderPlan(dataset: dataset, method: method)
                telemetryQualityState = plan.qualityState
                logger.info("[MTK3DInteraction] render.volume.plan generation=\(generation) state=\(plan.qualityState) quality=\(plan.request.quality) sampleDistance=\(plan.request.samplingDistance) viewport=\(Int(plan.request.viewportSize.width))x\(Int(plan.request.viewportSize.height)) cameraPosition=\(plan.request.camera.position) cameraTarget=\(plan.request.camera.target) cameraUp=\(plan.request.camera.up)")
                guard !Task.isCancelled, generation == renderGeneration else {
                    logger.debug("[MTK3DInteraction] render.skip generation=\(generation) current=\(renderGeneration) cancelled=\(Task.isCancelled) stage=afterPlan")
                    return
                }
                RenderingTelemetry.volumeRenderScheduled(qualityState: plan.qualityState)
                let frame = try await renderVolumeFrame(using: plan)
                if !surfaceMeshLayers.isEmpty {
                    let renderer = try surfaceMeshRendererInstance()
                    try await renderer.render(layers: surfaceMeshLayers,
                                              dataset: dataset,
                                              camera: plan.request.camera,
                                              targetTexture: frame.texture,
                                              clipping: volumeClipping)
                }
                let presentationGeneration = renderGeneration
                guard canPresentRender(generation: generation,
                                       currentGeneration: presentationGeneration,
                                       qualityState: plan.qualityState,
                                       allowStalePreviewPresentation: allowStalePreviewPresentation) else {
                    logger.debug("[MTK3DInteraction] render.skip generation=\(generation) current=\(renderGeneration) cancelled=\(Task.isCancelled) stage=afterFrame")
                    return
                }
                let frameReadyMilliseconds = mtkPerfMilliseconds(from: perfStartedAt)
                lastRenderError = nil
                let presentDuration = try viewportSurface.present(frame: frame)
                let totalMilliseconds = mtkPerfMilliseconds(from: perfStartedAt)
                logger.info(
                    "[MTKPerf] controller.volume.complete generation=\(generation) current=\(renderGeneration) stalePresented=\(generation != renderGeneration) totalMs=\(mtkPerfFormat(totalMilliseconds)) frameReadyMs=\(mtkPerfFormat(frameReadyMilliseconds)) presentCallMs=\(mtkPerfFormat(presentDuration * 1000.0)) frameRenderMetadataMs=\(mtkPerfFormat(frame.metadata.renderTime.map { $0 * 1000.0 })) quality=\(plan.request.quality) state=\(plan.qualityState) samplingDistance=\(mtkPerfFormat(Double(plan.request.samplingDistance))) viewport=\(Int(plan.request.viewportSize.width))x\(Int(plan.request.viewportSize.height))"
                )
                RenderingTelemetry.volumeRenderCompleted(duration: Date().timeIntervalSince(started),
                                                        qualityState: plan.qualityState)
            case let .mpr(axis, index, blend, slab):
                RenderingTelemetry.mprRenderScheduled(blend: blend.coreBlend,
                                                     qualityState: telemetryQualityState)
                guard !Task.isCancelled, generation == renderGeneration else {
                    logger.debug("[MTK3DInteraction] render.skip generation=\(generation) current=\(renderGeneration) cancelled=\(Task.isCancelled) stage=mprStart")
                    return
                }
                let frame = try await renderMpr(dataset: dataset,
                                                axis: axis,
                                                index: index,
                                                blend: blend,
                                                slab: slab)
                let labelmapOverlays = try await mprLabelmapOverlays(for: frame)
                let presentationGeneration = renderGeneration
                guard canPresentRender(generation: generation,
                                       currentGeneration: presentationGeneration,
                                       qualityState: telemetryQualityState,
                                       allowStalePreviewPresentation: allowStalePreviewPresentation) else {
                    logger.debug("[MTK3DInteraction] render.skip generation=\(generation) current=\(renderGeneration) cancelled=\(Task.isCancelled) stage=mprAfterFrame")
                    return
                }
                let frameReadyMilliseconds = mtkPerfMilliseconds(from: perfStartedAt)
                let presentDuration = try viewportSurface.present(mprFrame: frame,
                                                                  window: resolvedMPRWindow(for: dataset),
                                                                  labelmapOverlays: labelmapOverlays)
                let totalMilliseconds = mtkPerfMilliseconds(from: perfStartedAt)
                lastRenderError = nil
                logger.info(
                    "[MTKPerf] controller.mpr.complete generation=\(generation) current=\(renderGeneration) stalePresented=\(generation != renderGeneration) axis=\(axis) planeIndex=\(index) blend=\(blend.coreBlend) totalMs=\(mtkPerfFormat(totalMilliseconds)) frameReadyMs=\(mtkPerfFormat(frameReadyMilliseconds)) presentCallMs=\(mtkPerfFormat(presentDuration * 1000.0)) texture=\(frame.texture.width)x\(frame.texture.height) overlays=\(labelmapOverlays.count) state=\(telemetryQualityState)"
                )
                RenderingTelemetry.mprRenderCompleted(duration: Date().timeIntervalSince(started),
                                                      blend: blend.coreBlend,
                                                      qualityState: telemetryQualityState)
            }
        } catch {
            guard !Task.isCancelled, generation == renderGeneration else {
                logger.debug("[MTK3DInteraction] render.error.drop generation=\(generation) current=\(renderGeneration) cancelled=\(Task.isCancelled)")
                return
            }
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

    func canPresentRender(generation: UInt64,
                          currentGeneration: UInt64,
                          qualityState: RenderQualityState,
                          allowStalePreviewPresentation: Bool) -> Bool {
        guard !Task.isCancelled else { return false }
        if generation == currentGeneration {
            return true
        }
        return allowStalePreviewPresentation && qualityState != .settled
    }

    struct VolumeTextureRenderPlan {
        let request: VolumeRenderRequest
        let qualityState: RenderQualityState
    }

    /// Prepare a volume texture render plan for a dataset and volumetric render method.
    /// - Parameters:
    ///   - dataset: The volume dataset to render.
    ///   - method: The volumetric rendering method and compositing settings to use.
    /// - Returns: A `VolumeTextureRenderPlan` containing a prepared `VolumeRenderRequest` and the `RenderQualityState` used for telemetry.
    /// - Throws: An error if applying renderer state or building the render request fails.
    func makeVolumeTextureRenderPlan(dataset: VolumeDataset,
                                     method: VolumetricRenderMethod) async throws -> VolumeTextureRenderPlan {
        try await applyVolumeRendererState(for: dataset)
        let request = makeVolumeRenderRequest(dataset: dataset, method: method)
        return VolumeTextureRenderPlan(request: request,
                                       qualityState: qualityState(for: request))
    }

    /// Renders a volume texture frame from a prepared render plan.
    /// - Parameters:
    ///   - plan: A prepared VolumeTextureRenderPlan containing the render request and quality state used for telemetry.
    /// - Returns: The rendered VolumeRenderFrame.
    /// - Throws: Any error produced by the volume renderer while producing the frame.
    func renderVolumeFrame(using plan: VolumeTextureRenderPlan) async throws -> VolumeRenderFrame {
        try await (volumeRenderer as any VolumeRenderingPort).renderFrame(using: plan.request)
    }

    /// Creates a production-quality `CGImage` snapshot of the volume using the provided dataset and volumetric render method.
    ///
    /// - Important: This API performs an explicit GPU→CPU readback for export/debug workflows.
    ///   It must not be used for interactive on-screen rendering.
    ///   Interactive rendering should present the GPU-native `VolumeRenderFrame.texture` via `MetalViewportSurface`.
    ///
    /// This produces a final/export-quality image without altering interaction tracking or adaptive sampling state.
    /// - Parameters:
    ///   - dataset: The volume dataset to render.
    ///   - method: The volumetric rendering method and compositing settings to use.
    /// - Returns: A `CGImage` containing the rendered production-quality snapshot.
    @available(*, deprecated, message: "Export/debug-only. For interactive use, render a VolumeRenderFrame (MTLTexture) and present via MetalViewportSurface; convert to CGImage only via TextureSnapshotExporter when explicitly exporting.")
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

    /// Configure the volume renderer's HU window, lighting, and HU gate using controller state and the provided dataset.
    /// - Parameters:
    ///   - dataset: The volume dataset whose intensity range is used as a fallback for HU gate bounds when no explicit HU window or projection gate values are available.
    /// - Throws: Any error thrown by the underlying `volumeRenderer` configuration calls.
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

    /// Builds a VolumeRenderRequest configured for the current viewport, camera, transfer function, compositing mode, and render quality.
    /// - Parameters:
    ///   - dataset: The volume dataset to render.
    ///   - method: The volumetric render method whose compositing mode will be used.
    ///   - forceFinalQuality: When `true`, produce a request configured for production-quality rendering (overriding adaptive or interactive sampling); when `false`, use the scheduler's current quality parameters and adaptive sampling settings.
    /// - Returns: A VolumeRenderRequest populated with viewport size, camera parameters, transfer function, sampling distance (derived from adaptive/base sampling and quality), compositing mode, and the chosen quality tier.
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
            quality: forceFinalQuality ? .production : parameters.qualityTier,
            clipping: volumeClipping,
            layers: makeVolumeRenderLayers(baseDataset: dataset,
                                           baseTransferFunction: transfer)
        )
    }

    private func makeVolumeRenderLayers(baseDataset: VolumeDataset,
                                        baseTransferFunction: VolumeTransferFunction) -> [MTKCore.VolumeLayer] {
        var layers = [
            MTKCore.VolumeLayer(id: VolumeRenderRequest.primaryVolumeLayerID,
                                dataset: baseDataset,
                                transferFunction: baseTransferFunction)
        ]
        layers.append(contentsOf: volumeLayers.filter { layer in
            layer.scalarVolume != nil && layer.isVisible && layer.clampedOpacity > 0
        })
        return layers
    }

    /// Maps a volume render request's quality tier to the controller's telemetry-oriented render quality state.
    /// - Returns: `.settled` when `request.quality` is `.production`, `.interacting` when `request.quality` is `.interactive` or `.preview`.
    func qualityState(for request: VolumeRenderRequest) -> RenderQualityState {
        switch request.quality {
        case .production:
            return .settled
        case .interactive, .preview:
            return .interacting
        }
    }
}

private func mtkPerfMilliseconds(from start: CFAbsoluteTime,
                                 to end: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Double {
    max(0, (end - start) * 1000.0)
}

private func mtkPerfFormat(_ value: Double) -> String {
    String(format: "%.3f", value)
}

private func mtkPerfFormat(_ value: Double?) -> String {
    guard let value else { return "unavailable" }
    return mtkPerfFormat(value)
}

private func interactionDisplayName(_ display: VolumeViewportController.DisplayConfiguration) -> String {
    switch display {
    case let .volume(method):
        return "volume.\(method)"
    case let .mpr(axis, index, blend, slab):
        let slabDescription = slab.map { "thickness=\($0.thickness),steps=\($0.steps)" } ?? "none"
        return "mpr.axis=\(axis).index=\(index).blend=\(blend).slab=\(slabDescription)"
    }
}
