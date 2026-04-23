//
//  MPRDisplayTransformFactory.swift
//  MTKCore
//
//  Derives anatomical MPR display transforms from plane geometry in DICOM LPS.
//

import Foundation
import simd

public enum MPRDisplayTransformFactory {
    public static func makeTransform(for plane: MPRPlaneGeometry,
                                     axis: MPRPlaneAxis) -> MPRDisplayTransform {
        let rawLabels = rawEdgeLabels(for: plane)
        let expectedLabels = targetLabels(for: axis)

        for candidateTransform in preferredTransformParameters {
            let candidate = transform(orientation: candidateTransform.orientation,
                                      flipHorizontal: candidateTransform.flipHorizontal,
                                      flipVertical: candidateTransform.flipVertical,
                                      rawLabels: rawLabels)
            if candidate.leadingLabel == expectedLabels.leadingLabel &&
                candidate.trailingLabel == expectedLabels.trailingLabel &&
                candidate.topLabel == expectedLabels.topLabel &&
                candidate.bottomLabel == expectedLabels.bottomLabel {
                return candidate
            }
        }

#if DEBUG
        assertionFailure(
            "MPRDisplayTransformFactory could not match a clinical display candidate " +
            "for axis=\(axis) rawLabels=\(rawLabels) expectedLabels=\(expectedLabels). Preserving geometry-derived labels."
        )
#endif
        return transform(orientation: .standard,
                         flipHorizontal: false,
                         flipVertical: false,
                         rawLabels: rawLabels)
    }

    static func dominantAxis(of worldVector: SIMD3<Float>) -> (axis: Int, positive: Bool) {
        let absolute = SIMD3<Float>(abs(worldVector.x), abs(worldVector.y), abs(worldVector.z))
        if absolute.x >= absolute.y && absolute.x >= absolute.z {
            return (0, worldVector.x >= 0)
        }
        if absolute.y >= absolute.x && absolute.y >= absolute.z {
            return (1, worldVector.y >= 0)
        }
        return (2, worldVector.z >= 0)
    }

    static func labelForDirection(axis: Int,
                                  positive: Bool) -> AnatomicalAxisLabel {
        switch (axis, positive) {
        case (0, true):
            return .left
        case (0, false):
            return .right
        case (1, true):
            return .posterior
        case (1, false):
            return .anterior
        case (2, true):
            return .superior
        case (2, false):
            return .inferior
        default:
            return .superior
        }
    }
}

private extension MPRDisplayTransformFactory {
    typealias EdgeLabels = (
        leadingLabel: AnatomicalAxisLabel,
        trailingLabel: AnatomicalAxisLabel,
        topLabel: AnatomicalAxisLabel,
        bottomLabel: AnatomicalAxisLabel
    )

    static func rawEdgeLabels(for plane: MPRPlaneGeometry) -> EdgeLabels {
        let uDirection = dominantAxis(of: plane.axisUWorld)
        let vDirection = dominantAxis(of: plane.axisVWorld)
        let positiveU = labelForDirection(axis: uDirection.axis, positive: uDirection.positive)
        let positiveV = labelForDirection(axis: vDirection.axis, positive: vDirection.positive)

        return (
            leadingLabel: positiveU.opposite,
            trailingLabel: positiveU,
            topLabel: positiveV.opposite,
            bottomLabel: positiveV
        )
    }

    static func targetLabels(for axis: MPRPlaneAxis) -> EdgeLabels {
        switch axis {
        case .z:
            return (.right, .left, .anterior, .posterior)
        case .y:
            return (.right, .left, .superior, .inferior)
        case .x:
            return (.anterior, .posterior, .superior, .inferior)
        }
    }

    static func transform(orientation: MPRDisplayOrientation,
                          flipHorizontal: Bool,
                          flipVertical: Bool,
                          rawLabels: EdgeLabels) -> MPRDisplayTransform {
        let transformed = screenLabels(orientation: orientation,
                                       flipHorizontal: flipHorizontal,
                                       flipVertical: flipVertical,
                                       rawLabels: rawLabels)
        return MPRDisplayTransform(
            orientation: orientation,
            flipHorizontal: flipHorizontal,
            flipVertical: flipVertical,
            leadingLabel: transformed.leadingLabel,
            trailingLabel: transformed.trailingLabel,
            topLabel: transformed.topLabel,
            bottomLabel: transformed.bottomLabel
        )
    }

    static func screenLabels(orientation: MPRDisplayOrientation,
                             flipHorizontal: Bool,
                             flipVertical: Bool,
                             rawLabels: EdgeLabels) -> EdgeLabels {
        let epsilon: Float = 1e-3
        var leading: AnatomicalAxisLabel?
        var trailing: AnatomicalAxisLabel?
        var top: AnatomicalAxisLabel?
        var bottom: AnatomicalAxisLabel?

        let samples: [(SIMD2<Float>, AnatomicalAxisLabel)] = [
            (SIMD2<Float>(0, 0.5), rawLabels.leadingLabel),
            (SIMD2<Float>(1, 0.5), rawLabels.trailingLabel),
            (SIMD2<Float>(0.5, 0), rawLabels.topLabel),
            (SIMD2<Float>(0.5, 1), rawLabels.bottomLabel)
        ]

        for (texturePoint, label) in samples {
            var screenPoint = orientation.apply(to: texturePoint)
            if flipHorizontal {
                screenPoint.x = 1 - screenPoint.x
            }
            if flipVertical {
                screenPoint.y = 1 - screenPoint.y
            }

            if screenPoint.x <= epsilon {
                leading = label
            } else if screenPoint.x >= 1 - epsilon {
                trailing = label
            } else if screenPoint.y <= epsilon {
                top = label
            } else if screenPoint.y >= 1 - epsilon {
                bottom = label
            }
        }

        return (
            leadingLabel: leading ?? rawLabels.leadingLabel,
            trailingLabel: trailing ?? rawLabels.trailingLabel,
            topLabel: top ?? rawLabels.topLabel,
            bottomLabel: bottom ?? rawLabels.bottomLabel
        )
    }

    static var preferredTransformParameters: [(orientation: MPRDisplayOrientation, flipHorizontal: Bool, flipVertical: Bool)] {
        MPRDisplayOrientation.allCases
            .flatMap { orientation in
                [false, true].flatMap { flipHorizontal in
                    [false, true].map { flipVertical in
                        (orientation, flipHorizontal, flipVertical)
                    }
                }
            }
            .sorted { lhs, rhs in
                transformCost(lhs) < transformCost(rhs)
            }
    }

    static func transformCost(_ parameters: (orientation: MPRDisplayOrientation, flipHorizontal: Bool, flipVertical: Bool)) -> Int {
        let rotationCost = parameters.orientation == .standard ? 0 : 1
        return rotationCost
            + (parameters.flipHorizontal ? 1 : 0)
            + (parameters.flipVertical ? 1 : 0)
    }
}
