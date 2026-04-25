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
    /// If scheduled, increments the internal render generation, cancels any currently running render task, and starts a new asynchronous render task tied to the new generation.
    func scheduleRender() {
        guard renderMode == .active, datasetApplied else { return }
        renderGeneration &+= 1
        let generation = renderGeneration
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            await self?.render(generation: generation)
        }
    }

    /// Performs a render for the provided generation using the controller's current display state and presents the result.
    /// 
    /// When a volume or MPR display is active, this method emits corresponding telemetry events for scheduled, completed, and failed renders, and presents the produced frame to the viewport surface. The method guards against stale work by verifying the task has not been cancelled and the supplied `generation` matches the controller's current `renderGeneration` before presenting or reporting completion. On error (that is still relevant to the current generation), `lastRenderError` is set and a failure telemetry event is emitted; the error is also logged.
    /// - Parameter generation: The render generation identifier used to determine whether the produced result is still current; presentation and completion telemetry occur only if this matches the controller's active `renderGeneration` and the task is not cancelled.
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

    /// Creates a production-quality CGImage snapshot of the volume using the provided dataset and volumetric render method.
    /// 
    /// This produces a final/export-quality image without altering interaction tracking or adaptive sampling state.
    /// - Parameters:
    ///   - dataset: The volume dataset to render.
    ///   - method: The volumetric rendering method and compositing settings to use.
    /// - Returns: A `CGImage` containing the rendered production-quality snapshot.
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
            quality: forceFinalQuality ? .production : parameters.qualityTier
        )
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
