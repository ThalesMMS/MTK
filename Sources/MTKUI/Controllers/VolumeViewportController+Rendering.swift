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

    func logInteractionDebug(_ message: @autoclosure () -> String) {
        guard Logger.interactionLoggingEnabled else { return }
        logger.debug(message())
    }

    func logInteractionInfo(_ message: @autoclosure () -> String) {
        logger.info(message())
    }

    func logPerformanceInfo(_ message: @autoclosure () -> String) {
        guard MTKCore.Logger.performanceLoggingEnabled else { return }
        logger.info(message())
    }

    func scheduleRenderAfterSurfaceSettles(size: CGSize,
                                           reason: String) {
        surfaceRenderDebounceTask?.cancel()
        surfaceRenderDebounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.surfaceRenderDebounceNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let currentSize = self.viewportSurface.drawablePixelSize
            guard currentSize == size else {
                self.scheduleRenderAfterSurfaceSettles(size: currentSize,
                                                       reason: "\(reason).resized")
                return
            }
            self.surfaceRenderDebounceTask = nil
            self.stableSurfaceRenderScheduleCount += 1
            self.lastStableSurfaceRenderSize = currentSize
            await self.prewarmInteractiveOutputTexturesIfPossible(for: currentSize,
                                                                  reason: reason)
            self.scheduleRender()
        }
    }

    func prewarmInteractiveOutputTexturesIfPossible(for size: CGSize,
                                                    reason: String) async {
        guard datasetApplied,
              case .volume = currentDisplay ?? .volume(method: currentVolumeMethod),
              let adapter = volumeRenderer as? MetalVolumeRenderingAdapter else {
            return
        }
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        do {
            let ready = try await adapter.prewarmInteractiveOutputTextures(width: width,
                                                                           height: height,
                                                                           count: 3)
            if ready {
                pendingInteractiveOutputPrewarmSize = nil
                logInteractionDebug("[MTK3DInteraction] interactive.prewarm.ready reason=\(reason) size=\(width)x\(height)")
            } else {
                pendingInteractiveOutputPrewarmSize = size
                logInteractionDebug("[MTK3DInteraction] interactive.prewarm.defer reason=\(reason) size=\(width)x\(height)")
            }
        } catch {
            logInteractionDebug("[MTK3DInteraction] interactive.prewarm.failure reason=\(reason) size=\(width)x\(height) error=\(error.localizedDescription)")
        }
    }

    func retryPendingInteractiveOutputPrewarm(reason: String) {
        guard let size = pendingInteractiveOutputPrewarmSize else { return }
        interactiveOutputPrewarmTask?.cancel()
        interactiveOutputPrewarmTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prewarmInteractiveOutputTexturesIfPossible(for: size,
                                                                  reason: reason)
            self.interactiveOutputPrewarmTask = nil
        }
    }

    /// Schedules a new render when the controller is active and a dataset is applied.
    /// 
    /// If scheduled, increments the internal render generation and coalesces rapid updates behind a single in-flight render.
    func scheduleRender() {
        if surfaceRenderDebounceTask != nil {
            surfaceRenderDebounceTask?.cancel()
            surfaceRenderDebounceTask = nil
        }
        guard renderMode == .active, datasetApplied else {
            logInteractionDebug("[MTK3DInteraction] schedule.drop renderMode=\(String(describing: renderMode)) datasetApplied=\(datasetApplied) pending=\(renderPending) inFlight=\(renderInFlight) generation=\(renderGeneration)")
            return
        }
        let pendingBefore = renderPending
        let inFlightBefore = renderInFlight
        renderGeneration &+= 1
        let generation = renderGeneration
        let progress = viewportSurface.presentationProgressSnapshot()
        logInteractionDebug("[MTK3DInteraction] schedule generation=\(generation) pendingBefore=\(pendingBefore) inFlightBefore=\(inFlightBefore) presentationInFlightToken=\(describe(presentationInFlightToken)) display=\(interactionDisplayName(currentDisplay ?? .volume(method: currentVolumeMethod))) adaptive=\(adaptiveSamplingEnabled) state=\(effectiveQualityState) samplingStep=\(qualityScheduler.currentParameters.volumeSamplingStep) tier=\(qualityScheduler.currentParameters.qualityTier) submitted=\(progress.submitted) completed=\(progress.completed) failed=\(progress.failed) terminal=\(progress.terminal) presentInFlight=\(progress.inFlight)")
        renderPending = true
        guard !renderInFlight else {
            logInteractionDebug("[MTK3DInteraction] schedule.coalesce generation=\(generation) display=\(interactionDisplayName(currentDisplay ?? .volume(method: currentVolumeMethod))) state=\(effectiveQualityState) pending=\(renderPending) inFlight=\(renderInFlight) presentationInFlightToken=\(describe(presentationInFlightToken))")
            return
        }
        if let presentationInFlightToken {
            logInteractionDebug("[MTK3DInteraction] schedule.deferPresentation generation=\(generation) pending=\(renderPending) inFlight=\(renderInFlight) inFlightToken=\(presentationInFlightToken) submitted=\(progress.submitted) completed=\(progress.completed) failed=\(progress.failed) terminal=\(progress.terminal) presentInFlight=\(progress.inFlight)")
            return
        }
        startRenderDrain()
    }

    func startRenderDrain() {
        guard !renderInFlight else {
            logInteractionDebug("[MTK3DInteraction] drain.start.drop reason=inFlight generation=\(renderGeneration) pending=\(renderPending)")
            return
        }
        if let presentationInFlightToken {
            let progress = viewportSurface.presentationProgressSnapshot()
            logInteractionDebug("[MTK3DInteraction] drain.start.drop reason=presentationInFlight generation=\(renderGeneration) pending=\(renderPending) inFlightToken=\(presentationInFlightToken) submitted=\(progress.submitted) completed=\(progress.completed) failed=\(progress.failed) terminal=\(progress.terminal) presentInFlight=\(progress.inFlight)")
            return
        }
        renderInFlight = true
        logInteractionDebug("[MTK3DInteraction] drain.start generation=\(renderGeneration) pending=\(renderPending) inFlight=\(renderInFlight)")
        renderTask = Task { [weak self] in
            await self?.drainRenderQueue()
        }
    }

    func drainRenderQueue() async {
        let drainStartedAt = CFAbsoluteTimeGetCurrent()
        var iterationCount = 0
        logInteractionDebug("[MTK3DInteraction] drain.enter generation=\(renderGeneration) pending=\(renderPending) inFlight=\(renderInFlight)")
        defer {
            renderInFlight = false
            renderTask = nil
            logInteractionDebug("[MTK3DInteraction] drain.exit generation=\(renderGeneration) pending=\(renderPending) inFlight=\(renderInFlight) iterations=\(iterationCount) durationMs=\(mtkPerfFormat(mtkPerfMilliseconds(from: drainStartedAt)))")
            if renderPending, renderMode == .active, datasetApplied {
                if let presentationInFlightToken {
                    let progress = viewportSurface.presentationProgressSnapshot()
                    logInteractionDebug("[MTK3DInteraction] drain.restart.deferPresentation generation=\(renderGeneration) pending=\(renderPending) inFlightToken=\(presentationInFlightToken) submitted=\(progress.submitted) completed=\(progress.completed) failed=\(progress.failed) terminal=\(progress.terminal) presentInFlight=\(progress.inFlight)")
                } else {
                    logInteractionDebug("[MTK3DInteraction] drain.restart generation=\(renderGeneration) pending=\(renderPending) renderMode=\(String(describing: renderMode)) datasetApplied=\(datasetApplied)")
                    startRenderDrain()
                }
            }
        }

        while renderPending, !Task.isCancelled {
            if let presentationInFlightToken {
                let progress = viewportSurface.presentationProgressSnapshot()
                logInteractionDebug("[MTK3DInteraction] drain.deferPresentation generation=\(renderGeneration) pending=\(renderPending) inFlightToken=\(presentationInFlightToken) submitted=\(progress.submitted) completed=\(progress.completed) failed=\(progress.failed) terminal=\(progress.terminal) presentInFlight=\(progress.inFlight)")
                break
            }
            iterationCount += 1
            renderPending = false
            let generation = renderGeneration
            logInteractionDebug("[MTK3DInteraction] drain.iteration.start index=\(iterationCount) generation=\(generation) current=\(renderGeneration) pending=\(renderPending) inFlight=\(renderInFlight)")
            await render(generation: generation, allowStalePreviewPresentation: true)
            logInteractionDebug("[MTK3DInteraction] drain.iteration.end index=\(iterationCount) generation=\(generation) current=\(renderGeneration) pending=\(renderPending) inFlight=\(renderInFlight) cancelled=\(Task.isCancelled)")
        }
    }

    /// Performs a render for the provided generation using the controller's current display state and presents the result.
    /// 
    /// When a volume or MPR display is active, this method emits corresponding telemetry events for scheduled, completed, and failed renders, and presents the produced frame to the viewport surface. The method guards against stale work by verifying the task has not been cancelled and the supplied `generation` matches the controller's current `renderGeneration`.
    /// - Parameter generation: The render generation identifier used to determine whether the produced result is current enough to present.
    func render(generation: UInt64, allowStalePreviewPresentation: Bool = false) async {
        guard let dataset else {
            logInteractionDebug("[MTK3DInteraction] render.drop generation=\(generation) reason=noDataset")
            return
        }
        guard renderMode == .active else {
            logInteractionDebug("[MTK3DInteraction] render.drop generation=\(generation) reason=inactive renderMode=\(String(describing: renderMode))")
            return
        }
        let display = currentDisplay ?? .volume(method: currentVolumeMethod)
        let started = Date()
        let perfStartedAt = CFAbsoluteTimeGetCurrent()
        var telemetryQualityState = effectiveQualityState
        logInteractionDebug("[MTK3DInteraction] render.start generation=\(generation) current=\(renderGeneration) display=\(interactionDisplayName(display)) adaptive=\(adaptiveSamplingEnabled) state=\(telemetryQualityState)")
        guard !Task.isCancelled, generation == renderGeneration else {
            logInteractionDebug("[MTK3DInteraction] render.skip generation=\(generation) current=\(renderGeneration) cancelled=\(Task.isCancelled) stage=start")
            return
        }

        do {
            switch display {
            case let .volume(method):
                let plan = try await makeVolumeTextureRenderPlan(dataset: dataset, method: method)
                telemetryQualityState = plan.qualityState
                logPerformanceInfo("[MTK3DInteraction] render.volume.plan generation=\(generation) state=\(plan.qualityState) quality=\(plan.request.quality) sampleDistance=\(plan.request.samplingDistance) viewport=\(Int(plan.request.viewportSize.width))x\(Int(plan.request.viewportSize.height)) cameraPosition=\(plan.request.camera.position) cameraTarget=\(plan.request.camera.target) cameraUp=\(plan.request.camera.up)")
                guard canPresentRender(generation: generation,
                                       currentGeneration: renderGeneration,
                                       qualityState: plan.qualityState,
                                       allowStalePreviewPresentation: allowStalePreviewPresentation) else {
                    logInteractionDebug("[MTK3DInteraction] render.skip generation=\(generation) current=\(renderGeneration) cancelled=\(Task.isCancelled) stage=afterPlan")
                    return
                }
                RenderingTelemetry.volumeRenderScheduled(qualityState: plan.qualityState)
                let frame = try await renderVolumeFrame(using: plan)
                var shouldReleaseFrameLease = frame.outputTextureLease != nil
                defer {
                    if shouldReleaseFrameLease {
                        frame.outputTextureLease?.release()
                    }
                }
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
                    logInteractionDebug("[MTK3DInteraction] controller.volume.dropStale generation=\(generation) current=\(renderGeneration) frameIndex=\(describe(frame.metadata.debugFrameIndex)) slotID=\(describe(frame.outputTextureLease?.debugSlotID)) leaseID=\(frame.outputTextureLease?.leaseIdentifier.uuidString ?? "nil") reason=newerGenerationBeforePresent state=\(plan.qualityState)")
                    return
                }
                let frameReadyMilliseconds = mtkPerfMilliseconds(from: perfStartedAt)
                lastRenderError = nil
                let progressBeforePresent = viewportSurface.presentationProgressSnapshot()
                let intentKey = renderIntentKey(generation: generation, request: plan.request)
                logInteractionDebug("[MTK3DInteraction] controller.present.begin generation=\(generation) current=\(renderGeneration) frameIndex=\(describe(frame.metadata.debugFrameIndex)) intentKey=\(intentKey) staleCandidate=\(generation != renderGeneration) submitted=\(progressBeforePresent.submitted) completed=\(progressBeforePresent.completed) failed=\(progressBeforePresent.failed) terminal=\(progressBeforePresent.terminal) presentInFlight=\(progressBeforePresent.inFlight) textureID=\(objectIdentifier(frame.texture as AnyObject)) texture=\(frame.texture.width)x\(frame.texture.height) pixelFormat=\(frame.texture.pixelFormat) storage=\(frame.texture.storageMode)")
                let presentDuration = try viewportSurface.present(frame: frame,
                                                                   presentationToken: generation)
                closePresentationGate(token: generation,
                                      frameIndex: frame.metadata.debugFrameIndex,
                                      slotID: frame.outputTextureLease?.debugSlotID)
                shouldReleaseFrameLease = false
                let progressAfterPresent = viewportSurface.presentationProgressSnapshot()
                let totalMilliseconds = mtkPerfMilliseconds(from: perfStartedAt)
                logPerformanceInfo(
                    "[MTKPerf] controller.volume.complete generation=\(generation) current=\(renderGeneration) frameIndex=\(describe(frame.metadata.debugFrameIndex)) intentKey=\(intentKey) stalePresented=\(generation != renderGeneration) totalMs=\(mtkPerfFormat(totalMilliseconds)) frameReadyMs=\(mtkPerfFormat(frameReadyMilliseconds)) presentCallMs=\(mtkPerfFormat(presentDuration * 1000.0)) frameRenderMetadataMs=\(mtkPerfFormat(frame.metadata.renderTime.map { $0 * 1000.0 })) quality=\(plan.request.quality) state=\(plan.qualityState) samplingDistance=\(mtkPerfFormat(Double(plan.request.samplingDistance))) viewport=\(Int(plan.request.viewportSize.width))x\(Int(plan.request.viewportSize.height)) submittedBefore=\(progressBeforePresent.submitted) completedBefore=\(progressBeforePresent.completed) failedBefore=\(progressBeforePresent.failed) submittedAfter=\(progressAfterPresent.submitted) completedAfter=\(progressAfterPresent.completed) failedAfter=\(progressAfterPresent.failed) terminalAfter=\(progressAfterPresent.terminal) presentInFlightAfter=\(progressAfterPresent.inFlight)"
                )
                RenderingTelemetry.volumeRenderCompleted(duration: Date().timeIntervalSince(started),
                                                        qualityState: plan.qualityState)
            case let .mpr(axis, index, blend, slab):
                RenderingTelemetry.mprRenderScheduled(blend: blend.coreBlend,
                                                     qualityState: telemetryQualityState)
                guard !Task.isCancelled, generation == renderGeneration else {
                    logInteractionDebug("[MTK3DInteraction] render.skip generation=\(generation) current=\(renderGeneration) cancelled=\(Task.isCancelled) stage=mprStart")
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
                    logInteractionDebug("[MTK3DInteraction] render.skip generation=\(generation) current=\(renderGeneration) cancelled=\(Task.isCancelled) stage=mprAfterFrame")
                    return
                }
                let frameReadyMilliseconds = mtkPerfMilliseconds(from: perfStartedAt)
                let progressBeforePresent = viewportSurface.presentationProgressSnapshot()
                logInteractionDebug("[MTK3DInteraction] controller.present.begin generation=\(generation) current=\(renderGeneration) display=mpr submitted=\(progressBeforePresent.submitted) completed=\(progressBeforePresent.completed) failed=\(progressBeforePresent.failed) terminal=\(progressBeforePresent.terminal) presentInFlight=\(progressBeforePresent.inFlight) texture=\(frame.texture.width)x\(frame.texture.height) pixelFormat=\(frame.texture.pixelFormat)")
                let presentDuration = try viewportSurface.present(mprFrame: frame,
                                                                  window: resolvedMPRWindow(for: dataset),
                                                                  labelmapOverlays: labelmapOverlays,
                                                                  presentationToken: generation)
                closePresentationGate(token: generation,
                                      frameIndex: nil,
                                      slotID: nil)
                let progressAfterPresent = viewportSurface.presentationProgressSnapshot()
                let totalMilliseconds = mtkPerfMilliseconds(from: perfStartedAt)
                lastRenderError = nil
                logPerformanceInfo(
                    "[MTKPerf] controller.mpr.complete generation=\(generation) current=\(renderGeneration) stalePresented=\(generation != renderGeneration) axis=\(axis) planeIndex=\(index) blend=\(blend.coreBlend) totalMs=\(mtkPerfFormat(totalMilliseconds)) frameReadyMs=\(mtkPerfFormat(frameReadyMilliseconds)) presentCallMs=\(mtkPerfFormat(presentDuration * 1000.0)) texture=\(frame.texture.width)x\(frame.texture.height) overlays=\(labelmapOverlays.count) state=\(telemetryQualityState) submittedBefore=\(progressBeforePresent.submitted) completedBefore=\(progressBeforePresent.completed) submittedAfter=\(progressAfterPresent.submitted) completedAfter=\(progressAfterPresent.completed)"
                )
                RenderingTelemetry.mprRenderCompleted(duration: Date().timeIntervalSince(started),
                                                      blend: blend.coreBlend,
                                                      qualityState: telemetryQualityState)
            }
        } catch {
            guard !Task.isCancelled, generation == renderGeneration else {
                logInteractionDebug("[MTK3DInteraction] render.error.drop generation=\(generation) current=\(renderGeneration) cancelled=\(Task.isCancelled)")
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
        if allowStalePreviewPresentation && qualityState != .settled {
            logInteractionDebug("[MTK3DInteraction] render.dropStalePreview generation=\(generation) current=\(currentGeneration) state=\(qualityState)")
        }
        return false
    }

    func closePresentationGate(token: UInt64,
                               frameIndex: UInt64?,
                               slotID: Int?) {
        let progress = viewportSurface.presentationProgressSnapshot()
        presentationInFlightToken = token
        logInteractionDebug("[MTK3DInteraction] presentation.gate.close token=\(token) frameIndex=\(describe(frameIndex)) slotID=\(describe(slotID)) submitted=\(progress.submitted) completed=\(progress.completed) failed=\(progress.failed) terminal=\(progress.terminal) presentInFlight=\(progress.inFlight) pending=\(renderPending) inFlight=\(renderInFlight)")
    }

    @discardableResult
    func openPresentationGate(presentationToken: UInt64?,
                              reason: String) -> Bool {
        let inFlightBefore = presentationInFlightToken
        let shouldRelease: Bool
        if let inFlightBefore {
            shouldRelease = presentationToken == nil || presentationToken == inFlightBefore
        } else {
            shouldRelease = false
        }
        if shouldRelease {
            presentationInFlightToken = nil
        }
        let progress = viewportSurface.presentationProgressSnapshot()
        logInteractionDebug("[MTK3DInteraction] presentation.gate.open reason=\(reason) token=\(describe(presentationToken)) inFlightBefore=\(describe(inFlightBefore)) released=\(shouldRelease) current=\(renderGeneration) pending=\(renderPending) inFlight=\(renderInFlight) submitted=\(progress.submitted) completed=\(progress.completed) failed=\(progress.failed) terminal=\(progress.terminal) presentInFlight=\(progress.inFlight)")
        if shouldRelease,
           renderPending,
           !renderInFlight,
           renderMode == .active,
           datasetApplied {
            startRenderDrain()
        }
        return shouldRelease
    }

    func handlePresentationCompleted(_ presentationToken: UInt64?) {
        let released = openPresentationGate(presentationToken: presentationToken,
                                            reason: "complete")
        let progress = viewportSurface.presentationProgressSnapshot()
        retryPendingInteractiveOutputPrewarm(reason: "presentationComplete")
        if let presentationToken, presentationToken != renderGeneration {
            logInteractionDebug("[MTK3DInteraction] presentation.complete.stale token=\(presentationToken) current=\(renderGeneration) gateReleased=\(released) submitted=\(progress.submitted) completed=\(progress.completed) failed=\(progress.failed) terminal=\(progress.terminal) presentInFlight=\(progress.inFlight) pending=\(renderPending) inFlight=\(renderInFlight)")
            return
        }
        logInteractionDebug("[MTK3DInteraction] presentation.complete token=\(presentationToken.map(String.init) ?? "nil") current=\(renderGeneration) gateReleased=\(released) submitted=\(progress.submitted) completed=\(progress.completed) failed=\(progress.failed) terminal=\(progress.terminal) presentInFlight=\(progress.inFlight) pending=\(renderPending) inFlight=\(renderInFlight)")
    }

    @discardableResult
    func handlePresentationFailure(_ error: any Swift.Error,
                                   presentationToken: UInt64?) -> Bool {
        presentationFailureCount &+= 1
        let accepted = presentationToken == nil || presentationToken == renderGeneration
        let released = openPresentationGate(presentationToken: presentationToken,
                                            reason: "failure")
        if accepted {
            lastRenderError = error
        }
        let progress = viewportSurface.presentationProgressSnapshot()
        logInteractionInfo("[MTK3DInteraction] presentation.failure token=\(presentationToken.map(String.init) ?? "nil") current=\(renderGeneration) accepted=\(accepted) gateReleased=\(released) status=\(presentationFailureStatusDescription(error)) submitted=\(progress.submitted) completed=\(progress.completed) failed=\(progress.failed) terminal=\(progress.terminal) presentInFlight=\(progress.inFlight) pending=\(renderPending) inFlight=\(renderInFlight) failures=\(presentationFailureCount) error=\(error.localizedDescription)")
        return accepted
    }

    func nativeCameraInteractionDiagnostics() -> String {
        let progress = viewportSurface.presentationProgressSnapshot()
        return "cameraGeneration=\(cameraInteractionGeneration) generation=\(renderGeneration) pending=\(renderPending) inFlight=\(renderInFlight) inFlightToken=\(describe(presentationInFlightToken)) submitted=\(progress.submitted) completed=\(progress.completed) failed=\(progress.failed) terminal=\(progress.terminal) presentInFlight=\(progress.inFlight) failures=\(presentationFailureCount)"
    }

    private func presentationFailureStatusDescription(_ error: any Swift.Error) -> String {
        if let error = error as? PresentationPassCommandBufferError {
            switch error {
            case let .commandBufferFailed(status, _):
                return String(status)
            }
        }
        if let error = error as? MPRPresentationCommandBufferError {
            switch error {
            case let .commandBufferFailed(status, _):
                return String(status)
            }
        }
        return "unknown"
    }

    func renderIntentKey(generation: UInt64, request: VolumeRenderRequest) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        combine(&hash, generation)
        combine(&hash, qualityCode(request.quality))
        combine(&hash, compositingCode(request.compositing))
        combine(&hash, quantized(request.samplingDistance))
        combine(&hash, quantized(request.camera.position.x))
        combine(&hash, quantized(request.camera.position.y))
        combine(&hash, quantized(request.camera.position.z))
        combine(&hash, quantized(request.camera.target.x))
        combine(&hash, quantized(request.camera.target.y))
        combine(&hash, quantized(request.camera.target.z))
        combine(&hash, quantized(request.camera.up.x))
        combine(&hash, quantized(request.camera.up.y))
        combine(&hash, quantized(request.camera.up.z))
        return String(format: "0x%016llx", hash)
    }

    private func combine(_ hash: inout UInt64, _ value: UInt64) {
        hash ^= value
        hash &*= 0x100000001b3
    }

    private func quantized(_ value: Float) -> UInt64 {
        let scaled = Double(value) * 100_000
        return UInt64(bitPattern: Int64(scaled.rounded()))
    }

    private func qualityCode(_ quality: VolumeRenderRequest.Quality) -> UInt64 {
        switch quality {
        case .preview: return 1
        case .interactive: return 2
        case .production: return 3
        }
    }

    private func compositingCode(_ compositing: VolumeRenderRequest.Compositing) -> UInt64 {
        switch compositing {
        case .maximumIntensity: return 1
        case .minimumIntensity: return 2
        case .averageIntensity: return 3
        case .frontToBack: return 4
        }
    }

    func objectIdentifier(_ object: AnyObject) -> String {
        String(describing: ObjectIdentifier(object))
    }

    func describe(_ value: UInt64?) -> String {
        value.map(String.init) ?? "nil"
    }

    func describe(_ value: Int?) -> String {
        value.map(String.init) ?? "nil"
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
        let startedAt = CFAbsoluteTimeGetCurrent()
        let frame: VolumeRenderFrame
        if let adapter = volumeRenderer as? MetalVolumeRenderingAdapter {
            logInteractionDebug("[MTK3DInteraction] render.volume.texture.start backend=MetalVolumeRenderingAdapter quality=\(plan.request.quality) state=\(plan.qualityState) viewport=\(Int(plan.request.viewportSize.width))x\(Int(plan.request.viewportSize.height)) samplingDistance=\(mtkPerfFormat(Double(plan.request.samplingDistance)))")
            frame = try await adapter.enqueueInteractiveFrame(using: plan.request)
        } else {
            logInteractionDebug("[MTK3DInteraction] render.volume.texture.start backend=\(String(describing: type(of: volumeRenderer))) quality=\(plan.request.quality) state=\(plan.qualityState) viewport=\(Int(plan.request.viewportSize.width))x\(Int(plan.request.viewportSize.height)) samplingDistance=\(mtkPerfFormat(Double(plan.request.samplingDistance)))")
            let texture = try await (volumeRenderer as any VolumeRenderingPort)
                .renderInteractiveTexture(using: plan.request)
            frame = VolumeRenderFrame(
                texture: texture,
                metadata: VolumeRenderFrame.Metadata(request: plan.request,
                                                     texture: texture,
                                                     renderTime: mtkPerfMilliseconds(from: startedAt) / 1000.0)
            )
        }
        let texture = frame.texture
        logPerformanceInfo("[MTK3DInteraction] render.volume.texture.enqueued frameIndex=\(describe(frame.metadata.debugFrameIndex)) slotID=\(describe(frame.outputTextureLease?.debugSlotID)) leaseID=\(frame.outputTextureLease?.leaseIdentifier.uuidString ?? "nil") textureID=\(objectIdentifier(texture as AnyObject)) texture=\(texture.width)x\(texture.height) pixelFormat=\(texture.pixelFormat) storage=\(texture.storageMode) elapsedMs=\(mtkPerfFormat(mtkPerfMilliseconds(from: startedAt))) quality=\(plan.request.quality) state=\(plan.qualityState)")
        return VolumeRenderFrame(
            texture: frame.texture,
            metadata: VolumeRenderFrame.Metadata(request: plan.request,
                                                 texture: frame.texture,
                                                 renderTime: mtkPerfMilliseconds(from: startedAt) / 1000.0,
                                                 gpuStartTime: frame.metadata.gpuStartTime,
                                                 gpuEndTime: frame.metadata.gpuEndTime,
                                                 debugFrameIndex: frame.metadata.debugFrameIndex),
            outputTextureLease: frame.outputTextureLease
        )
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
