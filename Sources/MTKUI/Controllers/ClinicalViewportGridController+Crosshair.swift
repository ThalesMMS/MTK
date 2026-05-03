//
//  ClinicalViewportGridController+Crosshair.swift
//  MTKUI
//
//  Crosshair and display transform helpers for ClinicalViewportGridController.
//

import CoreGraphics
import Foundation
import MTKCore

extension ClinicalViewportGridController {
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
        let x = clampNormalized(Float(point.x))
        let y = clampNormalized(Float(point.y))
        let texture = displayTransform(for: axis).textureCoordinates(forScreen: SIMD2<Float>(x, y))
        switch axis {
        case .axial:
            return [(.sagittal, clampNormalized(texture.x)), (.coronal, clampNormalized(texture.y))]
        case .coronal:
            return [(.sagittal, clampNormalized(texture.x)), (.axial, clampNormalized(texture.y))]
        case .sagittal:
            return [(.coronal, clampNormalized(texture.x)), (.axial, clampNormalized(texture.y))]
        }
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
            let offset = crosshairOffset(for: axis, positions: normalizedPositions)
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
        let transform = displayTransform(for: frame.planeGeometry, axis: axis)
        displayTransformsByAxis[axis] = transform
        return transform
    }

    /// Maps an `MTKCore.Axis` to the corresponding `MPRPlaneAxis`.
    /// - Parameter axis: The axis to map.
    /// - Returns: The corresponding `MPRPlaneAxis`.
    func planeAxis(for axis: MTKCore.Axis) -> MPRPlaneAxis {
        clinicalPlaneAxis(for: axis)
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
            return SIMD2<Float>(positions[.sagittal] ?? 0.5,
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
        let size = drawableSize(for: axis)
        let texture = textureCoordinates(for: axis, positions: positions)
        let screen = displayTransform(for: axis).screenCoordinates(forTexture: texture)
        return CGPoint(x: CGFloat(screen.x - 0.5) * size.width,
                       y: CGFloat(screen.y - 0.5) * size.height)
    }
}
