//
//  VolumeViewportController+Camera.swift
//  MTKUI
//
//  Camera and geometry helpers for VolumeViewportController.
//

import Foundation
import MTKCore
import simd

extension VolumeViewportController {
    /// Updates internal volume metrics and camera distance limits using the provided dataset.
    /// 
    /// Sets the volume world center, derives the render bounding radius from the shared physical render geometry, and updates the camera distance limits.
    /// - Parameter dataset: Source volume metadata (dimensions, spacing/orientation) used to derive scale and bounds.
    func updateVolumeBounds(for dataset: VolumeDataset) {
        volumeWorldCenter = SIMD3<Float>(repeating: 0.5)
        let renderGeometry = VolumeRenderGeometry.make(for: dataset)
        volumeBoundingRadius = renderGeometry.boundingRadius
        if let geometry {
            patientLongitudinalAxis = safeNormalize(geometry.iopNorm, fallback: patientLongitudinalAxis)
        }
        cameraDistanceLimits = makeCameraDistanceLimits(radius: volumeBoundingRadius)
    }

    /// Create a DICOMGeometry populated from the provided volume dataset.
    /// - Parameter dataset: The volume dataset whose dimensions, voxel spacing, and orientation will be used.
    /// - Returns: A `DICOMGeometry` initialized with the dataset's cols, rows, slices, spacing (X/Y/Z) and orientation vectors (`iopRow`, `iopCol`, `ipp0`).
    func makeGeometry(from dataset: VolumeDataset) -> DICOMGeometry {
        DICOMGeometry(imageData: dataset.imageData)
    }

    /// Builds a frontal camera basis in texture-coordinate space.
    ///
    /// DICOM patient space uses LPS: +Y is posterior and +Z is superior. A
    /// frontal view places the camera anterior to the volume, looking along the
    /// patient anterior/posterior axis, with superior as screen up. The render
    /// request camera is expressed in texture coordinates, so the patient-space
    /// basis is converted through the same physical render geometry used by the
    /// raycaster.
    func makeFrontalCameraAxes(for dataset: VolumeDataset) -> (normal: SIMD3<Float>, up: SIMD3<Float>) {
        let renderGeometry = VolumeRenderGeometry.make(for: dataset)
        let anteriorWorld = SIMD3<Float>(0, -1, 0)
        let superiorWorld = SIMD3<Float>(0, 0, 1)
        let normal = renderGeometry.textureDirection(forWorldDirection: anteriorWorld)
        let up = renderGeometry.textureDirection(forWorldDirection: superiorWorld)
        return orthonormalCameraAxes(normal: normal, up: up)
    }

    /// Resets the camera to a default state centered on the volume using the provided orientation.
    /// - Parameters:
    ///   - radius: The volume bounding radius in world units; used to compute the initial camera distance and distance limits.
    ///   - normal: The desired camera offset direction; will be normalized and, if near-zero, replaced with the frontal direction.
    ///   - up: The desired camera up direction; will be normalized, projected perpendicular to `normal`, and fall back to patient superior.
    func resetCameraState(radius: Float,
                          normal: SIMD3<Float>,
                          up: SIMD3<Float>) {
        let axes = orthonormalCameraAxes(normal: normal, up: up)
        let distance = max(radius * defaultCameraDistanceFactor, radius * 1.25, 1.5)
        cameraTarget = volumeWorldCenter
        cameraOffset = axes.normal * distance
        cameraUpVector = axes.up
        cameraYawRadians = 0
        cameraPitchRadians = 0
        fallbackWorldUp = axes.up
        fallbackCameraTarget = volumeWorldCenter
        initialCameraTarget = cameraTarget
        initialCameraOffset = cameraOffset
        initialCameraUp = cameraUpVector
        cameraInteractionGeneration = 0
        cameraDistanceLimits = makeCameraDistanceLimits(radius: radius)
        _ = volumeOrbitState.reset(target: cameraTarget,
                                   offset: cameraOffset,
                                   up: cameraUpVector,
                                   distanceLimits: cameraDistanceLimits)
        publishCameraState()
    }

    @discardableResult
    func rotateCameraInteractively(screenDelta: SIMD2<Float>) -> Bool {
        let beforeOffset = Logger.interactionLoggingEnabled ? cameraOffset : .zero
        let beforeUp = Logger.interactionLoggingEnabled ? cameraUpVector : .zero
        guard let camera = volumeOrbitState.rotate(deltaX: screenDelta.x, deltaY: screenDelta.y) else {
            logInteractionDebug("[MTK3DInteraction] camera.rotate.drop zero delta=\(screenDelta)")
            return false
        }
        applyOrbitCamera(camera)
        logInteractionDebug("[MTK3DInteraction] camera.rotate delta=\(screenDelta) yaw=\(cameraYawRadians) pitch=\(cameraPitchRadians) beforeOffset=\(beforeOffset) afterOffset=\(cameraOffset) beforeUp=\(beforeUp) afterUp=\(cameraUpVector)")
        return true
    }

    @discardableResult
    func zoomCameraInteractively(scale: Float) -> Bool {
        let beforeOffset = Logger.interactionLoggingEnabled ? cameraOffset : .zero
        guard let camera = volumeOrbitState.zoom(scale: scale) else {
            logInteractionDebug("[MTK3DInteraction] camera.zoom.drop scale=\(scale)")
            return false
        }
        applyOrbitCamera(camera)
        logInteractionDebug("[MTK3DInteraction] camera.zoom scale=\(scale) beforeOffset=\(beforeOffset) afterOffset=\(cameraOffset)")
        return true
    }

    @discardableResult
    func tiltCameraInteractively(roll: Float, pitch: Float) -> Bool {
        let beforeOffset = Logger.interactionLoggingEnabled ? cameraOffset : .zero
        let beforeUp = Logger.interactionLoggingEnabled ? cameraUpVector : .zero
        guard let camera = volumeOrbitState.tilt(roll: roll, pitch: pitch) else {
            logInteractionDebug("[MTK3DInteraction] camera.tilt.drop roll=\(roll) pitch=\(pitch)")
            return false
        }
        applyOrbitCamera(camera)
        logInteractionDebug("[MTK3DInteraction] camera.tilt roll=\(roll) pitch=\(pitch) yaw=\(cameraYawRadians) accumulatedPitch=\(cameraPitchRadians) beforeOffset=\(beforeOffset) afterOffset=\(cameraOffset) beforeUp=\(beforeUp) afterUp=\(cameraUpVector)")
        return true
    }

    func scheduleInteractiveCameraRender() {
        let progressBefore = viewportSurface.presentationProgressSnapshot()
        logInteractionDebug("[MTK3DInteraction] camera.scheduleInteractive before generation=\(renderGeneration) pending=\(renderPending) inFlight=\(renderInFlight) inFlightToken=\(describe(presentationInFlightToken)) submitted=\(progressBefore.submitted) completed=\(progressBefore.completed) failed=\(progressBefore.failed) terminal=\(progressBefore.terminal) presentInFlight=\(progressBefore.inFlight)")
        scheduleRender()
        let progressAfter = viewportSurface.presentationProgressSnapshot()
        logInteractionDebug("[MTK3DInteraction] camera.scheduleInteractive after generation=\(renderGeneration) pending=\(renderPending) inFlight=\(renderInFlight) inFlightToken=\(describe(presentationInFlightToken)) submitted=\(progressAfter.submitted) completed=\(progressAfter.completed) failed=\(progressAfter.failed) terminal=\(progressAfter.terminal) presentInFlight=\(progressAfter.inFlight)")
        scheduleInteractiveRenderWatchdog(afterPresentationCount: progressBefore.completed)
    }

    private func scheduleInteractiveRenderWatchdog(afterPresentationCount presentationCountBefore: UInt64) {
        interactiveRenderWatchdogTask?.cancel()
        interactiveRenderWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 80_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            let progress = self.viewportSurface.presentationProgressSnapshot()
            guard progress.completed <= presentationCountBefore else {
                self.logInteractionDebug("[MTK3DInteraction] presentation.watchdog.ok completed=\(progress.completed) expectedAfter=\(presentationCountBefore) submitted=\(progress.submitted) failed=\(progress.failed) terminal=\(progress.terminal) presentInFlight=\(progress.inFlight) pending=\(self.renderPending) inFlight=\(self.renderInFlight) inFlightToken=\(self.describe(self.presentationInFlightToken)) generation=\(self.renderGeneration)")
                return
            }
            guard self.renderPending,
                  !self.renderInFlight,
                  self.presentationInFlightToken == nil,
                  progress.inFlight == 0 else {
                self.logInteractionDebug("[MTK3DInteraction] presentation.watchdog.skip completed=\(progress.completed) expectedAfter=\(presentationCountBefore) submitted=\(progress.submitted) failed=\(progress.failed) terminal=\(progress.terminal) presentInFlight=\(progress.inFlight) pending=\(self.renderPending) inFlight=\(self.renderInFlight) inFlightToken=\(self.describe(self.presentationInFlightToken)) generation=\(self.renderGeneration)")
                return
            }
            self.logInteractionDebug("[MTK3DInteraction] presentation.watchdog.reschedule completed=\(progress.completed) expectedAfter=\(presentationCountBefore) submitted=\(progress.submitted) failed=\(progress.failed) terminal=\(progress.terminal) presentInFlight=\(progress.inFlight) pending=\(self.renderPending) inFlight=\(self.renderInFlight) inFlightToken=\(self.describe(self.presentationInFlightToken)) generation=\(self.renderGeneration)")
            self.scheduleRender()
        }
    }

    private func applyOrbitCamera(_ camera: Volume3DOrbitCamera) {
        cameraTarget = camera.target
        cameraOffset = clampCameraOffset(camera.offset)
        cameraUpVector = safeNormalize(camera.up, fallback: fallbackWorldUp)
        cameraYawRadians = volumeOrbitState.yaw
        cameraPitchRadians = volumeOrbitState.pitch
        cameraInteractionGeneration &+= 1
        publishCameraState()
    }

    /// Records the controller's current camera state with the state publisher.
    /// 
    /// The recorded state includes the camera position (computed as `cameraTarget + cameraOffset`), the camera target (`cameraTarget`), and the up vector (`cameraUpVector`).
    func publishCameraState() {
        statePublisher.recordCameraState(position: cameraTarget + cameraOffset,
                                         target: cameraTarget,
                                         up: cameraUpVector)
    }

    /// Compute allowable camera distance limits from a volume radius.
    /// - Parameters:
    ///   - radius: The volume bounding radius used to derive distance limits.
    /// - Returns: A closed range where the lower bound is max(radius * 0.25, 0.1) and the upper bound is max(radius * 12, lowerBound + 0.5).
    func makeCameraDistanceLimits(radius: Float) -> ClosedRange<Float> {
        let minimum = max(radius * 0.25, 0.1)
        let maximum = max(radius * 12, minimum + 0.5)
        return minimum...maximum
    }

    private func orthonormalCameraAxes(normal: SIMD3<Float>,
                                       up: SIMD3<Float>) -> (normal: SIMD3<Float>, up: SIMD3<Float>) {
        let safeNormal = safeNormalize(normal, fallback: SIMD3<Float>(0, -1, 0))
        let safeUp = safeNormalize(up, fallback: SIMD3<Float>(0, 0, 1))
        let projectedUp = safeUp - simd_dot(safeUp, safeNormal) * safeNormal
        let resolvedUp = safeNormalize(projectedUp, fallback: cameraPerpendicular(to: safeNormal))
        return (safeNormal, resolvedUp)
    }

    private func cameraPerpendicular(to normal: SIMD3<Float>) -> SIMD3<Float> {
        let candidate = abs(simd_dot(normal, SIMD3<Float>(0, 0, 1))) < 0.9
            ? SIMD3<Float>(0, 0, 1)
            : SIMD3<Float>(0, 1, 0)
        let projected = candidate - simd_dot(candidate, normal) * normal
        return safeNormalize(projected, fallback: SIMD3<Float>(1, 0, 0))
    }

    /// Constrains a camera offset vector to the current distance limits while preserving its direction.
    /// - Parameters:
    ///   - offset: The vector from the camera target to the camera position.
    /// - Returns: The offset vector scaled to have a magnitude within `cameraDistanceLimits`. If `offset` has negligible length, returns a frontal default offset with magnitude `max(cameraDistanceLimits.lowerBound, 0.1)`.
    func clampCameraOffset(_ offset: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(offset)
        guard length > Float.ulpOfOne else {
            return SIMD3<Float>(0, -max(cameraDistanceLimits.lowerBound, 0.1), 0)
        }
        let clamped = max(cameraDistanceLimits.lowerBound, min(length, cameraDistanceLimits.upperBound))
        return offset / length * clamped
    }

    /// Constrains a desired camera target to lie within the allowed pan distance from the volume center.
    /// - Parameters:
    ///   - target: Desired camera target position in world coordinates.
    /// - Returns: A camera target position clamped to the sphere centered at `volumeWorldCenter` with radius `max(volumeBoundingRadius * maximumPanDistanceMultiplier, 1)`. If `target` is within that limit, it is returned unchanged; if `target` is effectively at the volume center, `volumeWorldCenter` is returned.
    func clampCameraTarget(_ target: SIMD3<Float>) -> SIMD3<Float> {
        let offset = target - volumeWorldCenter
        let limit = max(volumeBoundingRadius * maximumPanDistanceMultiplier, 1)
        let distance = simd_length(offset)
        guard distance > limit else { return target }
        guard distance > Float.ulpOfOne else { return volumeWorldCenter }
        return volumeWorldCenter + offset / distance * limit
    }

    /// Computes the world-space size of a single screen pixel at a given camera distance.
    /// - Parameter distance: Distance from the camera to the target point in world units.
    /// - Returns: A tuple containing `horizontal` and `vertical` world-unit sizes per screen pixel; falls back to (0.002, 0.002) if the computed scales are non-finite or not positive.
    func screenSpaceScale(distance: Float) -> (horizontal: Float, vertical: Float) {
        let bounds = viewportSurface.view.bounds
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

    /// Safely normalizes a 3D vector, returning the provided fallback when the vector's length is too small.
    /// - Parameters:
    ///   - vector: The vector to normalize.
    ///   - fallback: The vector to return if `vector` has near-zero length.
    /// - Returns: The normalized `vector`, or `fallback` if the input's length is approximately zero.
    func safeNormalize(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let lengthSquared = simd_length_squared(vector)
        guard lengthSquared > Float.ulpOfOne else { return fallback }
        return vector / sqrt(lengthSquared)
    }

    /// Computes a normalized vector perpendicular to the given vector.
    /// - Parameters:
    ///   - vector: A 3D vector to which the result will be orthogonal.
    /// - Returns: A unit-length vector perpendicular to `vector`. If `vector` is near-zero or the computed perpendicular is numerically unstable, returns the fallback vector `(0, 0, 1)`.
    func safePerpendicular(to vector: SIMD3<Float>) -> SIMD3<Float> {
        let axis = abs(vector.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        return safeNormalize(simd_cross(vector, axis), fallback: SIMD3<Float>(0, 0, 1))
    }
}
