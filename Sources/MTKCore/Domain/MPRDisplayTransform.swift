//
//  MPRDisplayTransform.swift
//  MTKCore
//
//  Anatomical display transform shared by MPR presentation and overlays.
//

import Foundation
import simd

public struct MPRDisplayTransform: Sendable, Equatable {
    public var orientation: MPRDisplayOrientation
    public var flipHorizontal: Bool
    public var flipVertical: Bool
    public var leadingLabel: AnatomicalOrientationLabel
    public var trailingLabel: AnatomicalOrientationLabel
    public var topLabel: AnatomicalOrientationLabel
    public var bottomLabel: AnatomicalOrientationLabel

    public init(orientation: MPRDisplayOrientation,
                flipHorizontal: Bool,
                flipVertical: Bool,
                leadingLabel: AnatomicalOrientationLabel,
                trailingLabel: AnatomicalOrientationLabel,
                topLabel: AnatomicalOrientationLabel,
                bottomLabel: AnatomicalOrientationLabel) {
        self.orientation = orientation
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.leadingLabel = leadingLabel
        self.trailingLabel = trailingLabel
        self.topLabel = topLabel
        self.bottomLabel = bottomLabel
    }

    public var labels: (leading: String, trailing: String, top: String, bottom: String) {
        (
            leadingLabel.description,
            trailingLabel.description,
            topLabel.description,
            bottomLabel.description
        )
    }

    public var transposeUV: Bool {
        orientation.transformComponents.transposeUV
    }

    public var presentationFlipHorizontal: Bool {
        let orientationComponents = orientation.transformComponents
        return orientationComponents.flipH != flipHorizontal
    }

    public var presentationFlipVertical: Bool {
        let orientationComponents = orientation.transformComponents
        return orientationComponents.flipV != flipVertical
    }

    public func screenCoordinates(forTexture textureUV: SIMD2<Float>) -> SIMD2<Float> {
        var point = orientation.apply(to: textureUV)
        if flipHorizontal {
            point.x = 1 - point.x
        }
        if flipVertical {
            point.y = 1 - point.y
        }
        return point
    }

    public func textureCoordinates(forScreen screenXY: SIMD2<Float>) -> SIMD2<Float> {
        var point = screenXY
        if flipHorizontal {
            point.x = 1 - point.x
        }
        if flipVertical {
            point.y = 1 - point.y
        }
        return orientation.inverseApply(to: point)
    }

    public func applyingAdditionalFlips(horizontal: Bool,
                                        vertical: Bool) -> MPRDisplayTransform {
        var transformed = self
        if horizontal {
            transformed.flipHorizontal.toggle()
            (transformed.leadingLabel, transformed.trailingLabel) =
                (transformed.trailingLabel, transformed.leadingLabel)
        }
        if vertical {
            transformed.flipVertical.toggle()
            (transformed.topLabel, transformed.bottomLabel) =
                (transformed.bottomLabel, transformed.topLabel)
        }
        return transformed
    }

    /// Resolves the physical aspect ratio after the anatomical display orientation is applied.
    public func displayAspectRatio(forSourceAspectRatio aspectRatio: Float) -> Float {
        let safeAspectRatio = aspectRatio.isFinite ? max(aspectRatio, Float.ulpOfOne) : 1
        return transposeUV ? 1 / safeAspectRatio : safeAspectRatio
    }

    public static let identity = MPRDisplayTransform(
        orientation: .standard,
        flipHorizontal: false,
        flipVertical: false,
        leadingLabel: .right,
        trailingLabel: .left,
        topLabel: .anterior,
        bottomLabel: .posterior
    )
}

public struct MPRViewportTransform: Sendable, Equatable {
    /// Fit-to-viewport is 1; zooming out below fit renders the image smaller
    /// than the viewport (centered, background filled) down to 25%.
    public static let minimumZoom: Float = 0.25
    public static let maximumZoom: Float = 8
    public static let identity = MPRViewportTransform()

    /// Maximum |pan| per axis for a given zoom: panning is allowed at any
    /// zoom, but at least a quarter of the viewport must stay covered by the
    /// image so it can never be pushed fully off-screen.
    public static func panLimit(forZoom zoom: Float) -> Float {
        (max(zoom, minimumZoom) + 1) * 0.5 - 0.25
    }

    public var zoom: Float
    public var pan: SIMD2<Float>
    public var rotationRadians: Float

    public init(zoom: Float = 1,
                pan: SIMD2<Float> = .zero,
                rotationRadians: Float = 0) {
        let sanitizedZoom = zoom.isFinite ? zoom : Self.minimumZoom
        self.zoom = min(max(sanitizedZoom, Self.minimumZoom), Self.maximumZoom)
        let sanitizedPan = SIMD2<Float>(
            pan.x.isFinite ? pan.x : 0,
            pan.y.isFinite ? pan.y : 0
        )
        self.pan = Self.clampedPan(sanitizedPan, zoom: self.zoom)
        self.rotationRadians = rotationRadians.isFinite ? rotationRadians : 0
    }

    public var isIdentity: Bool {
        zoom == 1 && pan == .zero && rotationRadians == 0
    }

    /// Maps source-image coordinates into the rotated, zoomed viewport using physical aspect bounds.
    public func screenCoordinates(
        forImageScreen point: SIMD2<Float>,
        sourceAspectRatio: Float = 1
    ) -> SIMD2<Float> {
        let sourceSize = SIMD2<Float>(Self.safeSourceAspectRatio(sourceAspectRatio), 1)
        let centered = (point - SIMD2<Float>(repeating: 0.5)) * sourceSize * zoom
        return SIMD2<Float>(repeating: 0.5)
            + Self.rotated(centered, radians: rotationRadians) / rotatedBounds(sourceAspectRatio: sourceAspectRatio)
            + pan
    }

    /// Inverts the aspect-aware viewport transform used by presentation shaders.
    public func imageScreenCoordinates(
        forViewportScreen point: SIMD2<Float>,
        sourceAspectRatio: Float = 1
    ) -> SIMD2<Float> {
        let safeZoom = max(zoom, Self.minimumZoom)
        let sourceSize = SIMD2<Float>(Self.safeSourceAspectRatio(sourceAspectRatio), 1)
        let centered = (point - SIMD2<Float>(repeating: 0.5) - pan)
            * rotatedBounds(sourceAspectRatio: sourceAspectRatio)
        return SIMD2<Float>(repeating: 0.5)
            + Self.rotated(centered, radians: -rotationRadians) / safeZoom / sourceSize
    }

    /// Returns the physical bounding-box size of the rotated source rectangle.
    public func rotatedBounds(sourceAspectRatio: Float) -> SIMD2<Float> {
        let sourceAspect = Self.safeSourceAspectRatio(sourceAspectRatio)
        let absoluteCos = abs(cos(rotationRadians))
        let absoluteSin = abs(sin(rotationRadians))
        return SIMD2<Float>(
            absoluteCos * sourceAspect + absoluteSin,
            absoluteSin * sourceAspect + absoluteCos
        )
    }

    /// Returns the width-to-height ratio of the rotated physical bounding box.
    public func rotatedContentAspectRatio(sourceAspectRatio: Float) -> Float {
        let bounds = rotatedBounds(sourceAspectRatio: sourceAspectRatio)
        return max(bounds.x / max(bounds.y, Float.ulpOfOne), Float.ulpOfOne)
    }

    public func translated(by delta: SIMD2<Float>) -> MPRViewportTransform {
        MPRViewportTransform(zoom: zoom,
                             pan: pan + delta,
                             rotationRadians: rotationRadians)
    }

    /// Applies zoom while preserving the source coordinate under the supplied viewport anchor.
    public func zoomed(
        by factor: Float,
        around anchor: SIMD2<Float>,
        sourceAspectRatio: Float = 1
    ) -> MPRViewportTransform {
        guard factor.isFinite, factor > 0 else { return self }
        let safeAnchor = SIMD2<Float>(
            anchor.x.isFinite ? anchor.x : 0.5,
            anchor.y.isFinite ? anchor.y : 0.5
        )
        let previousImagePoint = imageScreenCoordinates(
            forViewportScreen: safeAnchor,
            sourceAspectRatio: sourceAspectRatio
        )
        let nextZoom = min(max(zoom * factor, Self.minimumZoom), Self.maximumZoom)
        let sourceSize = SIMD2<Float>(Self.safeSourceAspectRatio(sourceAspectRatio), 1)
        let rotatedImagePoint = Self.rotated(
            (previousImagePoint - SIMD2<Float>(repeating: 0.5)) * sourceSize * nextZoom,
            radians: rotationRadians
        ) / rotatedBounds(sourceAspectRatio: sourceAspectRatio)
        let nextPan = safeAnchor
            - SIMD2<Float>(repeating: 0.5)
            - rotatedImagePoint
        return MPRViewportTransform(zoom: nextZoom,
                                    pan: nextPan,
                                    rotationRadians: rotationRadians)
    }

    private static func clampedPan(_ pan: SIMD2<Float>, zoom: Float) -> SIMD2<Float> {
        let limit = Self.panLimit(forZoom: zoom)
        return SIMD2<Float>(
            min(max(pan.x, -limit), limit),
            min(max(pan.y, -limit), limit)
        )
    }

    private static func rotated(_ point: SIMD2<Float>, radians: Float) -> SIMD2<Float> {
        guard radians != 0 else { return point }
        let cosTheta = cos(radians)
        let sinTheta = sin(radians)
        return SIMD2<Float>(
            point.x * cosTheta - point.y * sinTheta,
            point.x * sinTheta + point.y * cosTheta
        )
    }

    private static func safeSourceAspectRatio(_ aspectRatio: Float) -> Float {
        aspectRatio.isFinite ? max(aspectRatio, Float.ulpOfOne) : 1
    }
}
