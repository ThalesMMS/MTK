//
//  ClinicalViewportGridController+Crosshair.swift
//  MTKUI
//
//  Crosshair and display transform helpers for ClinicalViewportGridController.
//

import CoreGraphics
import Foundation
import MTKCore
import simd

extension ClinicalViewportGridController {
    static func normalizedAngleDegrees(_ angle: Double) -> Double {
        var normalized = angle.truncatingRemainder(dividingBy: 360)
        if normalized < 0 {
            normalized += 360
        }
        return normalized
    }

    static func shortestAngleDeltaDegrees(from previous: Double, to next: Double) -> Double {
        var delta = normalizedAngleDegrees(next) - normalizedAngleDegrees(previous)
        if delta > 180 {
            delta -= 360
        } else if delta < -180 {
            delta += 360
        }
        return delta
    }

    static func rotationAngleDegrees(initialAngleDegrees: Double,
                                     center: CGPoint,
                                     startLocation: CGPoint,
                                     currentLocation: CGPoint) -> Double {
        guard initialAngleDegrees.isFinite,
              center.x.isFinite,
              center.y.isFinite,
              startLocation.x.isFinite,
              startLocation.y.isFinite,
              currentLocation.x.isFinite,
              currentLocation.y.isFinite else {
            return normalizedAngleDegrees(initialAngleDegrees)
        }
        let currentDragAngle = atan2(Double(currentLocation.y - center.y), Double(currentLocation.x - center.x))
        let startDragTouchAngle = atan2(Double(startLocation.y - center.y), Double(startLocation.x - center.x))
        let deltaAngleDegrees = (currentDragAngle - startDragTouchAngle) * 180.0 / .pi
        return normalizedAngleDegrees(initialAngleDegrees + deltaAngleDegrees)
    }

    func mprAxesAffectedByRotation(around axis: MTKCore.Axis) -> [MTKCore.Axis] {
        MTKCore.Axis.allCases.filter { $0 != axis }
    }

    func applyMPRRotation(deltaDegrees: Double,
                          around axis: MTKCore.Axis,
                          affecting affectedAxes: [MTKCore.Axis]) {
        guard deltaDegrees.isFinite, abs(deltaDegrees) > .ulpOfOne else { return }
        let deltaRotation = rotationQuaternion(deltaDegrees: deltaDegrees, around: axis)
        for affectedAxis in affectedAxes {
            let current = mprPlaneRotationsByAxis[affectedAxis] ?? identityMPRRotation()
            let next = simd_normalize(deltaRotation * current)
            if isIdentityMPRRotation(next) {
                mprPlaneRotationsByAxis.removeValue(forKey: affectedAxis)
            } else {
                mprPlaneRotationsByAxis[affectedAxis] = next
            }
        }
    }

    func rotationQuaternion(deltaDegrees: Double, around axis: MTKCore.Axis) -> simd_quatf {
        let radians = Float(deltaDegrees * .pi / 180)
        return simd_quatf(angle: radians, axis: rotationAxisVector(for: axis))
    }

    func rotationAxisVector(for axis: MTKCore.Axis) -> SIMD3<Float> {
        switch axis {
        case .sagittal:
            return SIMD3<Float>(1, 0, 0)
        case .coronal:
            return SIMD3<Float>(0, 1, 0)
        case .axial:
            return SIMD3<Float>(0, 0, 1)
        }
    }

    func identityMPRRotation() -> simd_quatf {
        simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1))
    }

    func isIdentityMPRRotation(_ rotation: simd_quatf) -> Bool {
        simd_length(rotation.imag) <= 1e-6 && abs(rotation.real - 1) <= 1e-6
    }

    func currentMPRPlane(for axis: MTKCore.Axis) -> MPRPlaneGeometry? {
        guard let dataset = currentDataset else { return nil }
        let normalized = normalizedPositions[axis] ?? 0.5
        let rotation = mprPlaneRotationsByAxis[axis] ?? identityMPRRotation()
        return MPRGeometryDisplayMapper.makePlane(for: dataset,
                                                  axis: planeAxis(for: axis),
                                                  slicePosition: normalized,
                                                  rotation: rotation)
    }

    /// Compute normalized position updates for the two axes perpendicular to the given axis based on a screen point.
    /// - Parameters:
    ///   - point: A screen-space point; its x and y components are clamped into the range 0...1 before conversion.
    ///   - axis: The axis whose perpendicular axes will receive updated normalized positions.
    /// - Returns: An array of two `(MTKCore.Axis, Float)` pairs giving normalized positions for the perpendicular axes. The mapping is:
    ///   - `.axial`  -> `(.sagittal, texture.x)`, `(.coronal, texture.y)`
    ///   - `.coronal` -> `(.sagittal, texture.x)`, `(.axial, texture.y)`
    ///   - `.sagittal` -> `(.coronal, texture.x)`, `(.axial, texture.y)`
    func normalizedPositionUpdates(from point: CGPoint,
                                   in axis: MTKCore.Axis) -> [(MTKCore.Axis, Float)] {
        if let context = mprGeometryDisplayContext(for: axis) {
            let surfaceSize = drawableSize(for: axis)
            let clampedX = CGFloat(clampNormalized(Float(point.x)))
            let clampedY = CGFloat(clampNormalized(Float(point.y)))
            let pickPoint = CGPoint(x: clampedX * surfaceSize.width,
                                    y: clampedY * surfaceSize.height)
            do {
                let updates = try context.normalizedPositionUpdates(fromScreenPoint: pickPoint,
                                                                    layers: volumeLayers)
                return clinicalPositionUpdates(from: updates)
            } catch VolumePickError.outsideImagedArea {
                return []
            } catch {
                // Preserve the legacy normalized-coordinate fallback for non-layout failures.
            }
        }

        let x = clampNormalized(Float(point.x))
        let y = clampNormalized(Float(point.y))
        let imageScreen = viewportTransform(for: axis)
            .imageScreenCoordinates(forViewportScreen: SIMD2<Float>(x, y))
        let texture = displayTransform(for: axis).textureCoordinates(forScreen: imageScreen)
        switch axis {
        case .axial:
            return [(.sagittal, clampNormalized(texture.x)), (.coronal, clampNormalized(texture.y))]
        case .coronal:
            return [(.sagittal, clampNormalized(1 - texture.x)), (.axial, clampNormalized(texture.y))]
        case .sagittal:
            return [(.coronal, clampNormalized(texture.x)), (.axial, clampNormalized(texture.y))]
        }
    }

    func normalizedPositionUpdates(fromVoxel voxel: SIMD3<Float>,
                                   dimensions: VolumeDimensions,
                                   in axis: MTKCore.Axis) -> [(MTKCore.Axis, Float)] {
        clinicalPositionUpdates(
            from: MPRGeometryDisplayMapper.normalizedPositionUpdates(
                fromVoxel: voxel,
                dimensions: dimensions,
                viewingAxis: planeAxis(for: axis)
            )
        )
    }

    func normalizedPosition(forContinuousVoxelComponent component: Float,
                            count: Int) -> Float {
        guard count > 1 else { return 0 }
        return clampNormalized(component / Float(count - 1))
    }

    func sliceCount(for axis: MTKCore.Axis) -> Int? {
        guard let dimensions = currentDataset?.dimensions else { return nil }
        switch axis {
        case .axial:
            return dimensions.depth
        case .coronal:
            return dimensions.height
        case .sagittal:
            return dimensions.width
        }
    }

    func centerCursorVoxel(for dataset: VolumeDataset) -> SIMD3<Float> {
        SIMD3<Float>(
            Float(max(dataset.dimensions.width - 1, 0)) * 0.5,
            Float(max(dataset.dimensions.height - 1, 0)) * 0.5,
            Float(max(dataset.dimensions.depth - 1, 0)) * 0.5
        )
    }

    func setMPRCursorVoxel(_ voxel: SIMD3<Float>, in dataset: VolumeDataset) {
        let clamped = clampVoxel(voxel, dimensions: dataset.dimensions)
        mprCursorVoxel = clamped
        mprCursorWorldPoint = VolumePicking.worldPoint(forVoxelIndex: clamped, in: dataset)
        syncNormalizedPositionsFromCursor(dimensions: dataset.dimensions)
    }

    func setMPRCursorWorldPoint(_ worldPoint: SIMD3<Float>, in dataset: VolumeDataset) {
        let voxel = dataset.imageData.worldToIndex.transformPoint(worldPoint)
        setMPRCursorVoxel(voxel, in: dataset)
    }

    func syncNormalizedPositionsFromCursor(dimensions: VolumeDimensions) {
        normalizedPositions = [
            .sagittal: normalizedPosition(forContinuousVoxelComponent: mprCursorVoxel.x,
                                          count: dimensions.width),
            .coronal: normalizedPosition(forContinuousVoxelComponent: mprCursorVoxel.y,
                                         count: dimensions.height),
            .axial: normalizedPosition(forContinuousVoxelComponent: mprCursorVoxel.z,
                                       count: dimensions.depth)
        ]
    }

    func clampVoxel(_ voxel: SIMD3<Float>, dimensions: VolumeDimensions) -> SIMD3<Float> {
        SIMD3<Float>(
            clampVoxelComponent(voxel.x, count: dimensions.width),
            clampVoxelComponent(voxel.y, count: dimensions.height),
            clampVoxelComponent(voxel.z, count: dimensions.depth)
        )
    }

    func clampVoxelComponent(_ value: Float, count: Int) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), Float(max(count - 1, 0)))
    }

    /// Update the stored normalized position for the given axis if the clamped value differs from the current value.
    /// - Parameters:
    ///   - position: The desired normalized position; it is clamped to the inclusive range 0...1 before use.
    ///   - axis: The axis whose stored normalized position will be updated.
    /// - Returns: `true` if the stored position was changed, `false` otherwise.
    func setNormalizedPosition(_ position: Float, for axis: MTKCore.Axis) -> Bool {
        let next = clampNormalized(position)
        guard normalizedPositions[axis] != next else {
            return false
        }
        normalizedPositions[axis] = next
        return true
    }

    /// Update the stored crosshair offset for the given axis if it differs from the current value.
    /// - Parameters:
    ///   - offset: The offset in drawable pixel coordinates relative to the surface center.
    ///   - axis: The axis whose crosshair offset should be updated.
    /// - Returns: `true` if the stored offset was changed, `false` if the provided offset matched the existing value.
    func setCrosshairOffset(_ offset: CGPoint, for axis: MTKCore.Axis) -> Bool {
        guard crosshairOffsets[axis] != offset else {
            return false
        }
        crosshairOffsets[axis] = offset
        return true
    }

    /// The two axes perpendicular to the given axis.
    /// - Parameter axis: The axis to find perpendicular axes for.
    /// - Returns: An array containing the two axes perpendicular to `axis`:
    ///   - `.axial` -> `[.coronal, .sagittal]`
    ///   - `.coronal` -> `[.axial, .sagittal]`
    ///   - `.sagittal` -> `[.axial, .coronal]`
    func perpendicularAxes(to axis: MTKCore.Axis) -> [MTKCore.Axis] {
        switch axis {
        case .axial:
            return [.coronal, .sagittal]
        case .coronal:
            return [.axial, .sagittal]
        case .sagittal:
            return [.axial, .coronal]
        }
    }

    /// Reset crosshair offsets to centered defaults and recompute the offset for every axis using the current normalized positions.
    /// 
    /// Updates the controller's internal `crosshairOffsets` with centered values, then calculates and applies a new offset for each `MTKCore.Axis` based on `normalizedPositions`.
    func rebuildAllCrosshairOffsets() {
        crosshairOffsets = Self.centeredCrosshairOffsets
        for axis in MTKCore.Axis.allCases {
            let offset = crosshairOffset(for: axis)
            _ = setCrosshairOffset(offset, for: axis)
        }
    }

    /// Compute the drawable pixel size for the surface associated with the given axis.
    ///
    /// Crosshair positioning is computed in the pane's **layout point space** (SwiftUI coordinate
    /// space), not in the Metal drawable pixel space. Using drawable pixel dimensions here would
    /// scale the offset by the display scale factor (e.g. 2x/3x on iOS), causing visible
    /// misalignment between the crosshair overlay (points) and the rendered texture (pixels).
    ///
    /// - Parameter axis: The axis whose surface size to query.
    /// - Returns: A `CGSize` derived from the surface's `drawableSize` (points) where both width
    ///   and height are at least `1`.
    func drawableSize(for axis: MTKCore.Axis) -> CGSize {
        let size = surface(for: axis).metalView.bounds.size
        return CGSize(width: max(size.width, 1), height: max(size.height, 1))
    }

    /// Clamp a floating-point value to the inclusive range 0 to 1.
    /// - Parameter value: The value to constrain.
    /// - Returns: The input value clamped to the inclusive range 0 to 1.
    func clampNormalized(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    /// Looks up the axis for a viewport, computes its display transform from the frame's plane geometry, and caches that transform.
    ///
    /// - Parameters:
    ///   - viewport: The identifier of the viewport whose associated axis is used to compute the transform.
    ///   - frame: The texture frame whose `planeGeometry` is used to build the display transform.
    /// - Returns: The computed `MPRDisplayTransform` for the viewport's axis, or `nil` if the viewport has no associated axis.
    func presentationTransform(for viewport: ViewportID,
                               frame: MPRTextureFrame) -> MPRDisplayTransform? {
        guard let axis = viewportAxesByID[viewport] else { return nil }
        var transform = displayTransform(for: frame.planeGeometry, axis: axis)
        if let presentationState = mprPresentationStates[axis] {
            transform.flipHorizontal = transform.flipHorizontal != presentationState.flipHorizontal
            transform.flipVertical = transform.flipVertical != presentationState.flipVertical
        }
        displayTransformsByAxis[axis] = transform
        return transform
    }

    /// Maps an `MTKCore.Axis` to the corresponding `MPRPlaneAxis`.
    /// - Parameter axis: The axis to map.
    /// - Returns: The corresponding `MPRPlaneAxis`.
    func planeAxis(for axis: MTKCore.Axis) -> MPRPlaneAxis {
        clinicalPlaneAxis(for: axis)
    }

    func clinicalAxis(for axis: MPRPlaneAxis) -> MTKCore.Axis {
        switch axis {
        case .x:
            return .sagittal
        case .y:
            return .coronal
        case .z:
            return .axial
        }
    }

    func clinicalPositionUpdates(from updates: [MPRGeometryPositionUpdate]) -> [(MTKCore.Axis, Float)] {
        updates.map { (clinicalAxis(for: $0.axis), $0.position) }
    }

    /// Provides a fallback plane geometry for the given axis.
    /// - Returns: A default `MPRPlaneGeometry` to use when no specific geometry is available for the axis.
    func fallbackPlaneGeometry(for axis: MTKCore.Axis) -> MPRPlaneGeometry {
        clinicalFallbackPlaneGeometry(for: axis)
    }

    /// Map per-axis normalized positions into 2D texture coordinates for the specified plane axis.
    /// - Parameters:
    ///   - axis: The plane axis for which texture coordinates are produced.
    ///   - positions: A dictionary mapping each `MTKCore.Axis` to a normalized position in [0, 1]. Missing entries default to `0.5`.
    /// - Returns: A `SIMD2<Float>` whose components are the texture-space (x, y) coordinates:
    ///   - `.axial` → (sagittal, coronal)
    ///   - `.coronal` → (sagittal, axial)
    ///   - `.sagittal` → (coronal, axial)
    func textureCoordinates(for axis: MTKCore.Axis,
                            positions: [MTKCore.Axis: Float]) -> SIMD2<Float> {
        switch axis {
        case .axial:
            return SIMD2<Float>(positions[.sagittal] ?? 0.5,
                                positions[.coronal] ?? 0.5)
        case .coronal:
            return SIMD2<Float>(1 - (positions[.sagittal] ?? 0.5),
                                positions[.axial] ?? 0.5)
        case .sagittal:
            return SIMD2<Float>(positions[.coronal] ?? 0.5,
                                positions[.axial] ?? 0.5)
        }
    }

    /// Computes the crosshair offset in drawable pixels for the given axis based on per-axis normalized positions.
    /// - Parameters:
    ///   - axis: The axis whose drawable surface and display transform are used to compute the offset.
    ///   - positions: A dictionary of normalized positions (values between 0 and 1) keyed by axis. Missing axis entries default to 0.5.
    /// - Returns: A `CGPoint` representing the crosshair offset in pixels relative to the drawable's center (x and y distances).
    func crosshairOffset(for axis: MTKCore.Axis,
                         positions: [MTKCore.Axis: Float]) -> CGPoint {
        if positions == normalizedPositions {
            return crosshairOffset(for: axis)
        }
        if let dataset = currentDataset,
           let context = mprGeometryDisplayContext(for: axis),
           let offset = try? context.crosshairOffset(
            forVoxel: voxel(fromNormalizedPositions: positions,
                            dimensions: dataset.dimensions)
           ) {
            return offset
        }
        return crosshairOffsetForNormalizedPositions(axis: axis,
                                                     positions: positions)
    }

    func crosshairOffset(for axis: MTKCore.Axis) -> CGPoint {
        guard let worldPoint = mprCursorWorldPoint,
              let context = mprGeometryDisplayContext(for: axis),
              let offset = try? context.crosshairOffset(forWorldPoint: worldPoint)
        else {
            return crosshairOffsetForNormalizedPositions(axis: axis)
        }
        return offset
    }

    private func crosshairOffsetForNormalizedPositions(axis: MTKCore.Axis) -> CGPoint {
        crosshairOffsetForNormalizedPositions(axis: axis,
                                              positions: normalizedPositions)
    }

    private func crosshairOffsetForNormalizedPositions(axis: MTKCore.Axis,
                                                       positions: [MTKCore.Axis: Float]) -> CGPoint {
        let size = drawableSize(for: axis)
        let texture = textureCoordinates(for: axis, positions: positions)
        let imageScreen = displayTransform(for: axis).screenCoordinates(forTexture: texture)
        let imagePoint = viewportTransform(for: axis).screenCoordinates(forImageScreen: imageScreen)
        let layout = outputAspect(for: axis).layout(destinationSize: size)
        let screen = layout.viewportPoint(fromImagePoint: imagePoint)
        return CGPoint(x: CGFloat(screen.x - 0.5) * size.width,
                       y: CGFloat(screen.y - 0.5) * size.height)
    }

    /// Returns the `MPROutputAspect` to use for the given axis, mirroring the
    /// aspect-fit layout that `MPRPresentationPass` applies when drawing the
    /// rendered slab. Falls back to `.fill` when no dataset/plane is available.
    func outputAspect(for axis: MTKCore.Axis) -> MPROutputAspect {
        if let context = mprGeometryDisplayContext(for: axis) {
            return context.outputAspect
        }
        guard let plane = currentMPRPlane(for: axis) else { return .fill }
        return .aspectFit(physicalAspectRatio: plane.physicalAspectRatio)
    }

    func mprGeometryDisplayContext(for axis: MTKCore.Axis,
                                   viewportSize: CGSize? = nil) -> MPRGeometryDisplayContext? {
        guard let dataset = currentDataset else { return nil }
        return try? MPRGeometryDisplayMapper.makeContext(
            dataset: dataset,
            axis: planeAxis(for: axis),
            slicePosition: normalizedPositions[axis] ?? 0.5,
            planeRotation: mprPlaneRotationsByAxis[axis] ?? identityMPRRotation(),
            viewportTransform: viewportTransform(for: axis),
            viewportSize: viewportSize ?? drawableSize(for: axis)
        )
    }

    func voxel(fromNormalizedPositions positions: [MTKCore.Axis: Float],
               dimensions: VolumeDimensions) -> SIMD3<Float> {
        SIMD3<Float>(
            clampNormalized(positions[.sagittal] ?? 0.5) * Float(max(dimensions.width - 1, 0)),
            clampNormalized(positions[.coronal] ?? 0.5) * Float(max(dimensions.height - 1, 0)),
            clampNormalized(positions[.axial] ?? 0.5) * Float(max(dimensions.depth - 1, 0))
        )
    }
}
