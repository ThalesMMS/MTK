//
//  ClinicalViewportGridController+Rendering.swift
//  MTKUI
//
//  Rendering and presentation helpers for ClinicalViewportGridController.
//

import CoreGraphics
import Foundation
@preconcurrency import Metal
import MTKCore

extension ClinicalViewportGridController {
    /// Creates a private GPU texture and copies the full 2D contents of `source` into it.
    /// - Parameter source: The source 2D texture to copy; must be created on the same Metal device used by this controller's `volumeSurface` command queue.
    /// - Returns: A newly allocated private `MTLTexture` containing a full copy of `source` (slice 0, level 0), suitable for shader read/write and pixel-format views.
    /// - Throws: `SnapshotExportError.readbackFailed` if command resources cannot be created, if the destination texture cannot be allocated, or if the blit command buffer completes with an error (error description included).
    func makeSnapshotTextureCopy(of source: any MTLTexture) async throws -> any MTLTexture {
        guard volumeSurface.commandQueue.device.registryID == source.device.registryID,
              let commandBuffer = volumeSurface.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeBlitCommandEncoder()
        else {
            throw SnapshotExportError.readbackFailed("Could not create snapshot copy command resources.")
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.pixelFormat,
                                                                  width: source.width,
                                                                  height: source.height,
                                                                  mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]

        guard let destination = source.device.makeTexture(descriptor: descriptor) else {
            throw SnapshotExportError.readbackFailed("Could not create snapshot copy texture.")
        }
        destination.label = "ClinicalViewportGridController.SnapshotCopy"

        encoder.copy(from: source,
                     sourceSlice: 0,
                     sourceLevel: 0,
                     sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                     sourceSize: MTLSize(width: source.width,
                                         height: source.height,
                                         depth: 1),
                     to: destination,
                     destinationSlice: 0,
                     destinationLevel: 0,
                     destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        encoder.endEncoding()

        return try await withCheckedThrowingContinuation { continuation in
            commandBuffer.addCompletedHandler { completedBuffer in
                if let error = completedBuffer.error {
                    continuation.resume(throwing: SnapshotExportError.readbackFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: destination)
                }
            }
            commandBuffer.commit()
        }
    }


    /// Schedules a render task for the given viewport, increments its render generation, and updates debug state.
    /// 
    /// This cancels any existing scheduled task for the same viewport, increments the per-viewport render generation, and updates the viewport's debug snapshot to reflect a scheduled render.
    /// - Parameters:
    ///   - viewport: The identifier of the viewport to schedule rendering for.
    /// - Returns: A `Task<Void, Never>` that will perform the render, or `nil` if scheduling was skipped (e.g., because the dataset is not applied).
    @discardableResult
    func scheduleRender(for viewport: ViewportID) -> Task<Void, Never>? {
        guard datasetApplied else {
            logger.warning("Skipping render schedule viewport=\(viewportName(for: viewport)) datasetApplied=false")
            return nil
        }
        let generation = (renderGenerations[viewport] ?? 0) &+ 1
        renderGenerations[viewport] = generation
        renderTasks[viewport]?.cancel()
        let now = CFAbsoluteTimeGetCurrent()
        updateDebugSnapshot(for: viewport) { snapshot in
            snapshot.viewportType = viewportTypeName(for: viewport)
            snapshot.renderMode = renderModeName(for: viewport)
            snapshot.datasetHandle = datasetHandleLabel(for: viewport)
            snapshot.lastPassExecuted = "scheduleRender"
            snapshot.presentationStatus = "scheduled"
            snapshot.lastError = nil
            snapshot.lastRenderRequestTime = now
        }
        logger.info("Scheduling viewport render viewport=\(viewportName(for: viewport)) generation=\(generation) type=\(viewportTypeName(for: viewport)) mode=\(renderModeName(for: viewport))")
        let task = Task { [weak self] in
            guard let self else { return }
            await self.render(viewport: viewport, generation: generation)
        }
        renderTasks[viewport] = task
        return task
    }

    /// Render a single frame for the given viewport, present it, and update debug, timing, and error state.
    /// 
    /// This function invokes the render engine to produce a frame, validates the frame, and—if the render task
    /// has not been cancelled and the provided generation matches the current generation—presents the frame,
    /// records presentation and render timing, updates per-viewport debug snapshots, and clears or records errors
    /// as appropriate. If the frame provides an output texture lease it is released automatically unless the
    /// presentation completes successfully.
    ///
    /// - Parameters:
    ///   - viewport: The identifier of the viewport to render.
    ///   - generation: A per-viewport generation token used to detect stale renders and abort processing when a
    ///     newer generation is scheduled.
    func render(viewport: ViewportID, generation: UInt64) async {
#if DEBUG
        if viewport == volumeViewportID {
            await assertVolumeViewportConfigured()
        }
#endif
        logger.debug("Starting viewport render viewport=\(viewportName(for: viewport)) generation=\(generation)")
        updateDebugSnapshot(for: viewport) { snapshot in
            snapshot.viewportType = viewportTypeName(for: viewport)
            snapshot.renderMode = renderModeName(for: viewport)
            snapshot.datasetHandle = datasetHandleLabel(for: viewport)
            snapshot.lastPassExecuted = "engine.render"
            snapshot.presentationStatus = "rendering"
            snapshot.lastError = nil
        }
        do {
            let frame = try await engine.render(viewport)
            var shouldReleaseLease = frame.outputTextureLease != nil
            defer {
                if shouldReleaseLease {
                    frame.outputTextureLease?.release()
                }
            }
            try renderGraph.validateFrame(frame)
            guard !Task.isCancelled, renderGenerations[viewport] == generation else {
                return
            }
            let renderCompletedAt = CFAbsoluteTimeGetCurrent()
            updateDebugSnapshot(for: viewport) { snapshot in
                snapshot.viewportType = viewportTypeName(for: viewport)
                snapshot.renderMode = renderModeName(for: viewport)
                snapshot.datasetHandle = datasetHandleLabel(for: viewport)
                snapshot.outputTextureLabel = frame.texture.label
                snapshot.lastPassExecuted = frame.route.primaryPass?.profilingName
                snapshot.presentationStatus = "presenting"
                snapshot.lastError = nil
                snapshot.lastRenderCompletionTime = renderCompletedAt
            }
            logger.info("Rendered viewport frame viewport=\(viewportName(for: viewport)) generation=\(generation) route=\(frame.route.profilingName) pass=\(frame.route.primaryPass?.profilingName ?? "unknown") texture=\(frame.texture.label ?? "nil") size=\(frame.texture.width)x\(frame.texture.height) pixelFormat=\(frame.texture.pixelFormat)")
            let presentationTime = try present(frame, generation: generation)
            shouldReleaseLease = false
            recordTiming(frame.metadata,
                         for: viewport,
                         presentationTime: presentationTime)
            clearError(for: viewport)
            let presentedAt = CFAbsoluteTimeGetCurrent()
            updateDebugSnapshot(for: viewport) { snapshot in
                snapshot.viewportType = viewportTypeName(for: viewport)
                snapshot.renderMode = renderModeName(for: viewport)
                snapshot.datasetHandle = datasetHandleLabel(for: viewport)
                snapshot.outputTextureLabel = frame.texture.label
                snapshot.lastPassExecuted = frame.route.presentationPass?.profilingName
                snapshot.presentationStatus = "presented"
                snapshot.lastError = nil
                snapshot.lastPresentationTime = presentedAt
            }
        } catch {
            guard !Task.isCancelled, renderGenerations[viewport] == generation else {
                return
            }
            recordError(error, for: viewport)
            updateDebugSnapshot(for: viewport) { snapshot in
                snapshot.lastPassExecuted = "renderFailed"
            }
            logger.error("Viewport render failed viewport=\(viewportName(for: viewport)) generation=\(generation)", error: error)
        }
    }

    /// Present a rendered frame to its corresponding viewport surface.
    /// - Parameters:
    ///   - frame: The rendered frame to present; its `route` determines the expected presentation pass and target viewport.
    ///   - generation: Optional presentation token used to associate or identify this presentation.
    /// - Returns: The absolute time at which the presentation occurred.
    /// - Throws:
    ///   - `RenderGraphError.missingPresentationSurface` if there is no available surface for `frame.viewportID`.
    ///   - `RenderGraphError.passProducedNoFrame(frame.viewportID, .mprReslice)` if the presentation pass requires an MPR frame but none is present.
    ///   - `RenderGraphError.unmappedViewportRoute` if the frame's route does not map to a presentation pass.
    ///   - `RenderGraphError.invalidViewportConfiguration` if the route's presentation pass kind is not suitable for presentation (for example `.volumeRaycast`, `.mprReslice`, or `.overlay`).
    @discardableResult
    func present(_ frame: RenderFrame, generation: UInt64? = nil) throws -> CFAbsoluteTime {
        let presentationPass = frame.route.presentationPass
        logger.debug("Presenting viewport frame viewport=\(viewportName(for: frame.viewportID)) route=\(frame.route.profilingName) pass=\(presentationPass?.profilingName ?? "unknown") texture=\(frame.texture.label ?? "nil") size=\(frame.texture.width)x\(frame.texture.height) pixelFormat=\(frame.texture.pixelFormat)")
        let surface = surface(for: frame.viewportID)
        try renderGraph.validatePresentationSurface(for: frame, surfaceExists: surface != nil)
        guard let surface else {
            throw RenderGraphError.missingPresentationSurface(frame.viewportID)
        }

        switch presentationPass?.kind {
        case .presentation:
            return try surface.present(frame,
                                       presentationToken: generation)

        case .mprPresentation:
            guard let mprFrame = frame.mprFrame else {
                throw RenderGraphError.passProducedNoFrame(frame.viewportID, .mprReslice)
            }
            let transform = presentationTransform(for: frame.viewportID, frame: mprFrame)
            logger.debug("Using MPR presentation transform viewport=\(viewportName(for: frame.viewportID)) orientation=\(transform?.orientation.rawValue ?? 0) flipHorizontal=\(transform?.flipHorizontal == true) flipVertical=\(transform?.flipVertical == true)")
            return try surface.present(mprFrame: mprFrame,
                                       window: windowLevel.range,
                                       transform: transform,
                                       presentationToken: generation)

        case .none:
            throw RenderGraphError.unmappedViewportRoute(frame.route.viewportType)

        case .volumeRaycast, .mprReslice, .overlay:
            throw RenderGraphError.invalidViewportConfiguration(
                frame.viewportID,
                reason: "Presentation pass cannot be \(presentationPass?.kind.profilingName ?? "unknown")."
            )
        }
    }

    /// Record timing metadata for a specific viewport and update the aggregated timing snapshot.
    /// 
    /// Updates the stored FrameMetadata for `viewport` with `presentationTime` set to `presentationTime`,
    /// then recomputes `latestTimingSnapshot` using the maximum render, presentation, and upload times
    /// across all viewports.
    /// - Parameters:
    ///   - metadata: The frame timing metadata to store for the viewport.
    ///   - viewport: The identifier of the viewport whose timing is being recorded.
    ///   - presentationTime: The presentation timestamp to attach to the metadata, or `nil` to clear it.
    func recordTiming(_ metadata: FrameMetadata,
                      for viewport: ViewportID,
                      presentationTime: CFAbsoluteTime?) {
        var updated = metadata
        updated.presentTime = presentationTime
        viewportTimings[viewport] = updated
        latestTimingSnapshot = ClinicalViewportTimingSnapshot(
            renderTime: viewportTimings.values.compactMap(\.renderTime).max(),
            presentationTime: viewportTimings.values.compactMap(\.presentTime).max(),
            uploadTime: viewportTimings.values.compactMap(\.uploadTime).max()
        )
    }

    /// Maps a viewport identifier to its corresponding MetalViewportSurface, or `nil` if no surface exists for that viewport.
    /// - Parameter viewport: The viewport identifier to resolve.
    /// - Returns: The corresponding `MetalViewportSurface` for `viewport`, or `nil` when the viewport is unmapped.
    func surface(for viewport: ViewportID) -> MetalViewportSurface? {
        switch viewport {
        case axialViewportID:
            return axialSurface
        case coronalViewportID:
            return coronalSurface
        case sagittalViewportID:
            return sagittalSurface
        case volumeViewportID:
            return volumeSurface
        default:
            return nil
        }
    }
}
