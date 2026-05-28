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
    public var leadingLabel: AnatomicalAxisLabel
    public var trailingLabel: AnatomicalAxisLabel
    public var topLabel: AnatomicalAxisLabel
    public var bottomLabel: AnatomicalAxisLabel

    public init(orientation: MPRDisplayOrientation,
                flipHorizontal: Bool,
                flipVertical: Bool,
                leadingLabel: AnatomicalAxisLabel,
                trailingLabel: AnatomicalAxisLabel,
                topLabel: AnatomicalAxisLabel,
                bottomLabel: AnatomicalAxisLabel) {
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
    public static let minimumZoom: Float = 1
    public static let maximumZoom: Float = 8
    public static let identity = MPRViewportTransform()

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
        zoom == Self.minimumZoom && pan == .zero && rotationRadians == 0
    }

    public func screenCoordinates(forImageScreen point: SIMD2<Float>) -> SIMD2<Float> {
        let centered = point - SIMD2<Float>(repeating: 0.5)
        return SIMD2<Float>(repeating: 0.5) + Self.rotated(centered * zoom,
                                                           radians: rotationRadians) + pan
    }

    public func imageScreenCoordinates(forViewportScreen point: SIMD2<Float>) -> SIMD2<Float> {
        let safeZoom = max(zoom, Self.minimumZoom)
        let centered = point - SIMD2<Float>(repeating: 0.5) - pan
        return SIMD2<Float>(repeating: 0.5) + Self.rotated(centered,
                                                           radians: -rotationRadians) / safeZoom
    }

    public func translated(by delta: SIMD2<Float>) -> MPRViewportTransform {
        MPRViewportTransform(zoom: zoom,
                             pan: pan + delta,
                             rotationRadians: rotationRadians)
    }

    public func zoomed(by factor: Float, around anchor: SIMD2<Float>) -> MPRViewportTransform {
        guard factor.isFinite, factor > 0 else { return self }
        let safeAnchor = SIMD2<Float>(
            anchor.x.isFinite ? anchor.x : 0.5,
            anchor.y.isFinite ? anchor.y : 0.5
        )
        let previousImagePoint = imageScreenCoordinates(forViewportScreen: safeAnchor)
        let nextZoom = min(max(zoom * factor, Self.minimumZoom), Self.maximumZoom)
        let rotatedImagePoint = Self.rotated((previousImagePoint - SIMD2<Float>(repeating: 0.5)) * nextZoom,
                                             radians: rotationRadians)
        let nextPan = safeAnchor
            - SIMD2<Float>(repeating: 0.5)
            - rotatedImagePoint
        return MPRViewportTransform(zoom: nextZoom,
                                    pan: nextPan,
                                    rotationRadians: rotationRadians)
    }

    private static func clampedPan(_ pan: SIMD2<Float>, zoom: Float) -> SIMD2<Float> {
        guard zoom > Self.minimumZoom else { return .zero }
        let limit = (zoom - Self.minimumZoom) * 0.5
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
}
