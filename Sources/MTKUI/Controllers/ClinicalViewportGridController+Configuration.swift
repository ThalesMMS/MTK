//
//  ClinicalViewportGridController+Configuration.swift
//  MTKUI
//
//  Engine and viewport configuration helpers for ClinicalViewportGridController.
//

import CoreGraphics
import Foundation
import MTKCore
import simd

extension ClinicalViewportGridController {
    /// Attach drawable-size-change and presentation-failure callbacks to displayed viewport surfaces.
    ///
    /// For axial, coronal, and sagittal surfaces:
    /// - Sets a drawable-size-change callback that resizes the engine for the corresponding viewport, rebuilds crosshair offsets, and schedules a render; on failure, records the error for that viewport.
    /// - Sets a presentation-failure callback that ignores stale failures when the supplied presentation token does not match the current render generation for the viewport; otherwise forwards the error to the controller's presentation-failure handler and returns success/failure accordingly.
    func configureSurfaceCallbacks() {
        let pairs: [(ViewportID, MetalViewportSurface)] = [
            (axialViewportID, axialSurface),
            (coronalViewportID, coronalSurface),
            (sagittalViewportID, sagittalSurface),
            (volumeViewportID, volumeSurface)
        ]

        for (viewportID, surface) in pairs {
            surface.onDrawableSizeChange = { [weak self] size in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await self.engine.resize(viewportID, to: size)
                        if viewportID != self.volumeViewportID {
                            self.rebuildAllCrosshairOffsets()
                            self.scheduleRender(for: viewportID)
                        } else {
                            await self.prepareDisplayedVolumeViewport()
                        }
                    } catch {
                        self.recordError(error, for: viewportID)
                    }
                }
            }
            surface.onPresentationSurfaceReady = { [weak self] size in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await self.engine.resize(viewportID, to: size)
                        if viewportID != self.volumeViewportID {
                            self.rebuildAllCrosshairOffsets()
                        } else {
                            await self.prepareDisplayedVolumeViewport()
                        }
                        self.logClinicalInteractionInfo("[MTKMPRInteraction] surface.ready viewport=\(self.viewportName(for: viewportID)) drawable=\(Int(size.width))x\(Int(size.height)) datasetApplied=\(self.datasetApplied)")
                        if viewportID != self.volumeViewportID {
                            self.scheduleRender(for: viewportID)
                        }
                    } catch {
                        self.recordError(error, for: viewportID)
                    }
                }
            }
            surface.onPresentationFailure = { [weak self] error, presentationToken in
                guard let self else { return false }
                return self.handleSurfacePresentationFailure(error,
                                                             presentationToken: presentationToken,
                                                             for: viewportID)
            }
            surface.onPresentationCompleted = { [weak self] presentationToken in
                guard let self else { return }
                self.handleSurfacePresentationCompleted(presentationToken,
                                                        for: viewportID)
            }
        }
    }

    /// Configure slice positions and the display window for every MPR axis.
    /// - Parameters:
    ///   - window: An optional intensity window range to apply to each MPR viewport; pass `nil` to leave the current window unchanged.
    /// - Throws: The underlying error thrown while configuring any individual axis.
    func configureAllMPRSlices(window: ClosedRange<Int32>?) async throws {
        for axis in MTKCore.Axis.allCases {
            try await configureSlice(axis: axis, window: window)
        }
    }

    /// Configures the engine slice position and display window for the MPR viewport corresponding to the given axis.
    /// - Parameters:
    ///   - axis: The anatomical axis whose MPR viewport will be configured (e.g., axial, coronal, sagittal).
    ///   - window: Optional intensity window to apply to the viewport; pass `nil` to keep the current window.
    /// - Throws: An error if the engine fails to apply the configuration for the corresponding viewport.
    func configureSlice(axis: MTKCore.Axis, window: ClosedRange<Int32>?) async throws {
        let viewport = viewportID(for: axis)
        #if DEBUG
        if debugWindowConfigurationFailureViewports.contains(viewport) {
            throw MTKRenderingEngine.EngineError.viewportNotFound(viewport)
        }
        #endif
        try await engine.configure(
            viewport,
            slicePosition: normalizedPositions[axis] ?? 0.5,
            window: window
        )
        if let plane = currentMPRPlane(for: axis) {
            try await engine.configure(viewport, mprPlaneGeometry: plane)
        }
    }

    /// Requests rendering for every MPR viewport in the grid.
    func scheduleMPRRenderAll() {
        for viewport in mprViewportIDs {
            scheduleRender(for: viewport)
        }
    }

    func refreshPresentationLayout(for axis: MTKCore.Axis) async {
        let viewportID = viewportID(for: axis)
        let surface = surface(for: axis)
        surface.refreshPresentationSurface()
        guard surface.isPresentationSurfaceReady else {
            logClinicalInteractionInfo("[MTKMPRInteraction] fullscreen.refresh.pending viewport=\(viewportName(for: viewportID))")
            return
        }
        let size = surface.drawablePixelSize
        do {
            try await engine.resize(viewportID, to: size)
            rebuildAllCrosshairOffsets()
            releaseStalePresentationGateIfIdle(for: viewportID,
                                               reason: "layoutRefresh")
            logClinicalInteractionInfo("[MTKMPRInteraction] fullscreen.refresh viewport=\(viewportName(for: viewportID)) drawable=\(Int(size.width))x\(Int(size.height))")
            scheduleRender(for: viewportID)
        } catch {
            recordError(error, for: viewportID)
        }
    }

    func releaseStalePresentationGateIfIdle(for viewport: ViewportID,
                                            reason: String) {
        guard let token = presentationInFlightTokens[viewport],
              let progress = surface(for: viewport)?.presentationProgressSnapshot(),
              progress.inFlight == 0
        else { return }

        logClinicalInteractionInfo("[MTKMPRInteraction] presentation.gate.releaseIdle viewport=\(viewportName(for: viewport)) reason=\(reason) token=\(token) submitted=\(progress.submitted) completed=\(progress.completed) failed=\(progress.failed) terminal=\(progress.terminal)")
        _ = openPresentationGate(for: viewport,
                                 presentationToken: nil,
                                 reason: reason)
    }

    /// Apply a slab configuration to all MPR viewports.
    /// - Parameters:
    ///   - configuration: Optional base slab configuration to apply; when `nil`, the controller's current `slabThickness` is used to derive the base configuration.
    /// - Throws: An error if configuring any MPR viewport on the engine fails.
    func configureMPRSlab(_ configuration: ClinicalSlabConfiguration? = nil) async throws {
        try await configureMPRSlabResolved(configuration: configuration)
    }

    func configureMPRSlabResolved(configuration: ClinicalSlabConfiguration? = nil) async throws {
        let base = configuration ?? ClinicalSlabConfiguration(thickness: Int(slabThickness))
        qualityScheduler.setBaseSlabSteps(base.steps)
        let effectiveSteps: Int
        if adaptiveSamplingEnabled {
            effectiveSteps = Int(round(Float(base.steps) * qualityScheduler.currentParameters.mprSlabStepsFactor))
        } else {
            effectiveSteps = base.steps
        }
        let resolved = ClinicalSlabConfiguration(thickness: base.thickness,
                                                 steps: max(effectiveSteps, 1))
        for viewport in mprViewportIDs {
            try await engine.configure(viewport,
                                       slabThickness: resolved.thickness,
                                       slabSteps: resolved.steps,
                                       blend: mprSlabBlendMode.volumetricBlendMode.coreBlend)
        }
    }

    /// Set the intensity window used by the volume viewport.
    /// - Parameter window: A closed range of voxel intensity values (e.g., Hounsfield units) to apply to the volume; pass `nil` to clear or use the engine's default.
    /// - Throws: Propagates any error thrown by the rendering engine if configuration fails.
    func configureVolumeWindow(_ window: ClosedRange<Int32>?) async throws {
        #if DEBUG
        if debugWindowConfigurationFailureViewports.contains(volumeViewportID) {
            throw MTKRenderingEngine.EngineError.viewportNotFound(volumeViewportID)
        }
        #endif
        try await engine.configure(volumeViewportID, window: window)
    }

    /// Reset the volume camera to the controller's default target, offset, and up vector.
    /// - Details: Sets `volumeCameraTarget` to (0.5, 0.5, 0.5), `volumeCameraOffset` to (0, 0, 2), and `volumeCameraUp` to (0, 1, 0).
    func resetVolumeCamera() {
        volumeCameraTarget = SIMD3<Float>(repeating: 0.5)
        volumeCameraOffset = SIMD3<Float>(0, 0, 2)
        volumeCameraUp = SIMD3<Float>(0, 1, 0)
        volumeCameraYaw = 0
        volumeCameraPitch = 0
        volumeCameraInteractionGeneration = 0
        _ = volumeOrbitState.reset(target: volumeCameraTarget,
                                   offset: volumeCameraOffset,
                                   up: volumeCameraUp,
                                   distanceLimits: 0.1...16)
    }

    /// Configures the engine camera for the volume viewport using the controller's current camera state.
    /// 
    /// The configured camera uses:
    /// - position: `volumeCameraTarget + volumeCameraOffset`
    /// - target: `volumeCameraTarget`
    /// - up vector: `volumeCameraUp`
    /// - field of view: 45 degrees
    /// - projection type: perspective
    /// - Throws: If the engine fails to apply the camera configuration.
    func configureVolumeCamera() async throws {
        try await engine.configure(
            volumeViewportID,
            camera: Camera(
                position: volumeCameraTarget + volumeCameraOffset,
                target: volumeCameraTarget,
                up: volumeCameraUp,
                fieldOfView: 45,
                projectionType: .perspective
            )
        )
    }

    /// Configures the volume viewport's sampling distance and quality tier from the current quality scheduler parameters.
    /// Uses the scheduler's `volumeSamplingStep` (minimum 1) to compute `samplingDistance` as `1 / samplingStep`.
    /// - Throws: Any error produced while configuring the engine for the volume viewport.
    func configureVolumeRenderQuality() async throws {
        let samplingStep: Float
        let qualityTier: VolumeRenderRequest.Quality
        if adaptiveSamplingEnabled {
            let parameters = qualityScheduler.currentParameters
            samplingStep = max(parameters.volumeSamplingStep, 1)
            qualityTier = parameters.qualityTier
        } else {
            samplingStep = baseSamplingStep
            qualityTier = .production
        }
        try await engine.configure(volumeViewportID,
                                   samplingDistance: 1 / samplingStep,
                                   quality: qualityTier,
                                   renderQualitySettings: volumeRenderQualitySettings)
    }

    /// Applies the public crop/clip state to the 3D volume viewport only.
    func configureVolumeClipping() async throws {
        try await engine.configure(volumeViewportID, clipping: volumeClipping)
    }

    /// Applies current MPR slab quality parameters and schedules rendering for viewports that were successfully configured.
    ///
    /// If the dataset has not been applied, the method returns immediately. It derives an MPR slab configuration from `slabThickness` and `qualityScheduler`, applies that configuration to every MPR viewport, records errors for any viewports that fail, and schedules MPR rendering only if all MPR viewport configurations succeed.
    func applyRenderQualityAndSchedule() async {
        guard datasetApplied else {
            logger.warning("Skipping render quality application because datasetApplied=false")
            return
        }
        var scheduleMPR = false

        do {
            try await configureMPRSlabResolved()
            scheduleMPR = true
        } catch {
            for viewport in mprViewportIDs {
                recordError(error, for: viewport)
            }
            logger.error("Failed to apply MPR slab state", error: error)
        }

        if scheduleMPR {
            scheduleMPRRenderAll()
        }
    }

}
