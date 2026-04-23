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
