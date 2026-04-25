//
//  ClinicalViewportGridController+Diagnostics.swift
//  MTKUI
//
//  Diagnostics, error handling, and debug helpers for ClinicalViewportGridController.
//

import Foundation
import MTKCore
import simd

extension ClinicalViewportGridController {
    /// Creates or updates the debug snapshot for a given viewport and applies an in-place mutation to it.
    /// - Parameters:
    ///   - viewport: The identifier of the viewport whose debug snapshot will be created or updated.
    ///   - mutate: A closure that receives the snapshot as an `inout ClinicalViewportDebugSnapshot` and modifies it. If no snapshot exists for `viewport`, a new one is created before the closure is invoked.
    func updateDebugSnapshot(for viewport: ViewportID,
                             mutate: (inout ClinicalViewportDebugSnapshot) -> Void) {
        var snapshot = debugSnapshots[viewport]
            ?? Self.makeDebugSnapshot(viewportID: viewport,
                                      viewportName: viewportName(for: viewport),
                                      viewportType: viewportTypeName(for: viewport),
                                      renderMode: renderModeName(for: viewport))
        mutate(&snapshot)
        debugSnapshots[viewport] = snapshot
    }

    /// Create a `ClinicalViewportDebugSnapshot` identified by the provided viewport metadata.
    /// - Parameters:
    ///   - viewportID: The identifier of the viewport.
    ///   - viewportName: Human-readable name for the viewport (e.g., "Axial").
    ///   - viewportType: Debug name for the viewport type or mode (e.g., `"mpr(x)"` or a volume type).
    ///   - renderMode: The rendering mode label (e.g., `"single"` or a volume mode raw value).
    /// - Returns: A `ClinicalViewportDebugSnapshot` initialized with the given identifiers.
    static func makeDebugSnapshot(viewportID: ViewportID,
                                  viewportName: String,
                                  viewportType: String,
                                  renderMode: String) -> ClinicalViewportDebugSnapshot {
        ClinicalViewportDebugSnapshot(viewportID: viewportID,
                                      viewportName: viewportName,
                                      viewportType: viewportType,
                                      renderMode: renderMode)
    }

    /// Map a `ViewportID` to its human-readable viewport name.
    /// - Parameter viewport: The viewport identifier to translate.
    /// - Returns: A human-readable name for the viewport: `"Axial"`, `"Coronal"`, `"Sagittal"`, `"Volume"`, or `"Viewport"` for unknown identifiers.
    func viewportName(for viewport: ViewportID) -> String {
        switch viewport {
        case axialViewportID:
            return "Axial"
        case coronalViewportID:
            return "Coronal"
        case sagittalViewportID:
            return "Sagittal"
        case volumeViewportID:
            return "Volume"
        default:
            return "Viewport"
        }
    }

    /// Determine the human-readable viewport type name for a viewport identifier.
    /// - Parameter viewport: The viewport identifier to describe.
    /// - Returns: A string describing the viewport type: the volume viewport's debug name for the volume viewport, `"mpr(<axisDebugName>)"` for MPR viewports backed by an axis, or `"unknown"` if no type can be determined.
    func viewportTypeName(for viewport: ViewportID) -> String {
        if viewport == volumeViewportID {
            return volumeViewportMode.viewportType.debugName
        }
        if let axis = viewportAxesByID[viewport] {
            return "mpr(\(axis.debugName))"
        }
        return "unknown"
    }

    /// Determines the render mode name for a given viewport.
    /// - Parameter viewport: The viewport identifier to query.
    /// - Returns: The render mode name: `volumeViewportMode.rawValue` when `viewport` equals `volumeViewportID`, otherwise `"single"`.
    func renderModeName(for viewport: ViewportID) -> String {
        if viewport == volumeViewportID {
            return volumeViewportMode.rawValue
        }
        return "single"
    }

    /// Produces a textual label for the shared resource handle associated with a viewport.
    /// - Parameter viewport: The viewport identifier whose dataset handle is being queried.
    /// - Returns: A `String` describing the shared resource handle, or `nil` if no handle is available.
    func datasetHandleLabel(for viewport: ViewportID) -> String? {
        return sharedResourceHandle.map(String.init(describing:))
    }

    /// Produces a human-readable description for an optional error.
    /// - Parameter error: The error to describe; may be `nil`.
    /// - Returns: The error's `LocalizedError.errorDescription` when available, otherwise `String(describing: error)`. Returns `nil` if `error` is `nil`.
    func errorDescription(_ error: (any Error)?) -> String? {
        guard let error else { return nil }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// Updates the controller's aggregate render error to the highest-priority viewport error.
    /// 
    /// Checks stored per-viewport errors in the order: volume, axial, coronal, sagittal. Sets `lastRenderError` to the first encountered error; if no per-viewport errors exist, sets `lastRenderError` to `nil`.
    func refreshAggregateRenderError() {
        let priorityOrder = [volumeViewportID, axialViewportID, coronalViewportID, sagittalViewportID]
        for viewport in priorityOrder {
            if let error = lastRenderErrors[viewport] {
                lastRenderError = error
                return
            }
        }
        lastRenderError = nil
    }

    /// Record a rendering error for a given viewport and update associated diagnostics.
    /// 
    /// Updates the controller's stored error for `viewport`, updates the per-viewport debug snapshot to reflect the error state (updates `viewportType` and `renderMode`, sets `lastPassExecuted` to `"error"`, `presentationStatus` to `"failed"`, and `lastError` to a human-readable description), preserves existing dataset/texture labels and timing fields on the snapshot, and refreshes the aggregated render error state.
    /// - Parameters:
    ///   - error: The error encountered during rendering or presentation.
    ///   - viewport: The identifier of the viewport that experienced the error.
    func recordError(_ error: any Error, for viewport: ViewportID) {
        lastRenderErrors[viewport] = error
        updateDebugSnapshot(for: viewport) { snapshot in
            snapshot.viewportType = viewportTypeName(for: viewport)
            snapshot.renderMode = renderModeName(for: viewport)
            snapshot.lastPassExecuted = "error"
            snapshot.presentationStatus = "failed"
            snapshot.lastError = errorDescription(error)
        }
        refreshAggregateRenderError()
    }

    /// Removes the recorded render error for the specified viewport and updates the aggregated render error state.
    /// - Parameter viewport: The identifier of the viewport whose stored error should be cleared.
    func clearError(for viewport: ViewportID) {
        lastRenderErrors.removeValue(forKey: viewport)
        refreshAggregateRenderError()
    }

    /// Record a presentation failure for a specific viewport, update its debug snapshot to reflect the failure, and log the error.
    /// - Parameters:
    ///   - error: The encountered presentation error to record and store in the snapshot.
    ///   - viewport: The identifier of the viewport that experienced the presentation failure.
    func handlePresentationFailure(_ error: any Error, for viewport: ViewportID) {
        lastRenderErrors[viewport] = error
        updateDebugSnapshot(for: viewport) { snapshot in
            snapshot.viewportType = viewportTypeName(for: viewport)
            snapshot.renderMode = renderModeName(for: viewport)
            snapshot.lastPassExecuted = "presentationFailed"
            snapshot.presentationStatus = "failed"
            snapshot.lastError = errorDescription(error)
            snapshot.lastPresentationTime = CFAbsoluteTimeGetCurrent()
        }
        refreshAggregateRenderError()
        logger.error("Viewport presentation failed viewport=\(viewportName(for: viewport))", error: error)
    }

#if DEBUG
    /// Verifies that the engine's volume viewport type equals the expected volume viewport configuration; causes a runtime failure if the descriptor is missing or mismatched.
    /// - Note: On fetch failure this calls `preconditionFailure(...)` with the viewport ID and thrown error. If the fetched viewport type does not equal the expected `volumeViewportMode.viewportType`, this triggers `precondition(...)` describing the expected and actual debug names.
    func assertVolumeViewportConfigured() async {
        let viewportType: ViewportType
        do {
            viewportType = try await engine.viewportType(for: volumeViewportID)
        } catch {
            preconditionFailure("Volume viewport descriptor missing for \(volumeViewportID): \(error)")
        }
        precondition(viewportType == volumeViewportMode.viewportType,
                     "Volume viewport misconfigured. Expected \(volumeViewportMode.viewportType.debugName), got \(viewportType.debugName)")
    }
#endif

    /// Builds a VolumeTransferFunction from a TransferFunction.
    /// - Parameter transferFunction: The source transfer function whose sanitized colour and alpha points (and `shift`) are used to produce control points.
    /// - Returns: A VolumeTransferFunction whose colour control points use each sanitized colour point's RGBA components and whose opacity control points use each sanitized alpha point's alpha value; intensities are computed as `point.dataValue + transferFunction.shift`.
    static func volumeTransferFunction(from transferFunction: TransferFunction) -> VolumeTransferFunction {
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
        let opacityPoints = transferFunction
            .sanitizedAlphaPoints()
            .map { point in
                VolumeTransferFunction.OpacityControlPoint(
                    intensity: point.dataValue + transferFunction.shift,
                    opacity: point.alphaValue
                )
            }
        return VolumeTransferFunction(opacityPoints: opacityPoints,
                                      colourPoints: colourPoints)
    }

#if DEBUG
    /// Prints per-viewport resource-sharing diagnostics and asserts consistency of shared resources.
    /// 
    /// Fetches resource-sharing diagnostics and engine resource metrics, prints a summary line for each viewport (including viewport ID, handle, texture identifier, dimensions, and estimated bytes), and prints aggregated volume texture byte counts. Performs runtime assertions that diagnostics exist for all clinical viewports, that all viewports share a single resource handle and resolve to a single texture identifier, and that the GPU memory footprint matches the expected volume size when known. Assertion failures indicate a discrepancy in resource sharing or memory accounting.
    func logResourceSharingDiagnostics() async {
        let diagnostics = await engine.resourceSharingDiagnostics(for: allViewportIDs)
        let textureIdentifiers = Set(diagnostics.map(\.textureObjectIdentifier))
        let handles = Set(diagnostics.map(\.handle))
        let metrics = await engine.resourceMetrics()
        let expectedVolumeBytes = sharedResourceHandle?.metadata.estimatedBytes ?? 0

        print("ClinicalViewportGrid resource diagnostics:")
        for diagnostic in diagnostics {
            let metadata = diagnostic.metadata
            print("  viewport=\(diagnostic.viewportID) handle=\(diagnostic.handle) texture=\(diagnostic.textureObjectIdentifier) dimensions=\(metadata.dimensions.width)x\(metadata.dimensions.height)x\(metadata.dimensions.depth) estimatedBytes=\(metadata.estimatedBytes)")
        }
        print("  volumeTextureBytes=\(metrics.breakdown.volumeTextures) expectedSingleVolumeBytes=\(expectedVolumeBytes)")

        assert(diagnostics.count == allViewportIDs.count,
               "Expected diagnostics for all clinical viewports.")
        assert(handles.count == 1,
               "ClinicalViewportGrid expected one shared VolumeResourceHandle.")
        assert(textureIdentifiers.count == 1,
               "ClinicalViewportGrid expected all viewports to resolve to one MTLTexture.")
        assert(expectedVolumeBytes == 0 || metrics.breakdown.volumeTextures == expectedVolumeBytes,
               "ClinicalViewportGrid expected one-volume GPU memory footprint.")
    }
#endif

    /// Normalizes a 3D vector, returning a fallback when the vector's length is not finite or is too small.
    /// - Parameters:
    ///   - value: The vector to normalize.
    ///   - fallback: The vector to return if `value` cannot be safely normalized (non-finite length or length ≤ `Float.ulpOfOne`).
    /// - Returns: The normalized `value` when its length is finite and greater than `Float.ulpOfOne`; otherwise `fallback`.
    func safeNormalize(_ value: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(value)
        guard length.isFinite, length > Float.ulpOfOne else {
            return fallback
        }
        return value / length
    }
}
