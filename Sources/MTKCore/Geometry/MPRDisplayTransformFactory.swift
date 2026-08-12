//
//  MPRDisplayTransformFactory.swift
//  MTKCore
//
//  Derives anatomical MPR display transforms from plane geometry in DICOM LPS.
//

import Foundation
import simd

public enum MPRDisplayTransformFactory {
    /// Creates the anatomical presentation transform for a plane.
    ///
    /// A reference plane keeps the discrete image orientation and flips stable while an MPR plane
    /// rotates continuously. Edge labels are always derived from the current plane geometry.
    public static func makeTransform(for plane: MPRPlaneGeometry,
                                     axis: MPRPlaneAxis,
                                     referencePlane: MPRPlaneGeometry? = nil) -> MPRDisplayTransform {
        let referenceLabels = rawAxisEdgeLabels(for: referencePlane ?? plane)
        let rawLabels = rawOrientationEdgeLabels(for: plane)
        let expectedLabels = targetLabels(for: axis)

        for candidateTransform in preferredTransformParameters {
            let candidateLabels = screenLabels(
                orientation: candidateTransform.orientation,
                flipHorizontal: candidateTransform.flipHorizontal,
                flipVertical: candidateTransform.flipVertical,
                rawLabels: referenceLabels
            )
            if candidateLabels.leadingLabel == expectedLabels.leadingLabel &&
                candidateLabels.trailingLabel == expectedLabels.trailingLabel &&
                candidateLabels.topLabel == expectedLabels.topLabel &&
                candidateLabels.bottomLabel == expectedLabels.bottomLabel {
                return transform(orientation: candidateTransform.orientation,
                                 flipHorizontal: candidateTransform.flipHorizontal,
                                 flipVertical: candidateTransform.flipVertical,
                                 rawLabels: rawLabels)
            }
        }

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

    /// Resolves a DICOM LPS world-space direction into an anatomical label.
    public static func orientationLabel(for worldVector: SIMD3<Float>) -> AnatomicalOrientationLabel {
        let length = simd_length(worldVector)
        let direction = length.isFinite && length > Float.ulpOfOne
            ? worldVector / length
            : .zero
        let components = [
            (axis: 0, magnitude: abs(direction.x), positive: direction.x >= 0),
            (axis: 1, magnitude: abs(direction.y), positive: direction.y >= 0),
            (axis: 2, magnitude: abs(direction.z), positive: direction.z >= 0)
        ]
        .filter { $0.magnitude > 1e-4 }
        .sorted { lhs, rhs in
            if abs(lhs.magnitude - rhs.magnitude) <= 1e-6 {
                return lhs.axis < rhs.axis
            }
            return lhs.magnitude > rhs.magnitude
        }
        .map { labelForDirection(axis: $0.axis, positive: $0.positive) }

        return AnatomicalOrientationLabel(components: components)
    }
}

private extension MPRDisplayTransformFactory {
    typealias AxisEdgeLabels = (
        leadingLabel: AnatomicalAxisLabel,
        trailingLabel: AnatomicalAxisLabel,
        topLabel: AnatomicalAxisLabel,
        bottomLabel: AnatomicalAxisLabel
    )

    typealias OrientationEdgeLabels = (
        leadingLabel: AnatomicalOrientationLabel,
        trailingLabel: AnatomicalOrientationLabel,
        topLabel: AnatomicalOrientationLabel,
        bottomLabel: AnatomicalOrientationLabel
    )

    static func rawAxisEdgeLabels(for plane: MPRPlaneGeometry) -> AxisEdgeLabels {
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

    static func rawOrientationEdgeLabels(for plane: MPRPlaneGeometry) -> OrientationEdgeLabels {
        let positiveU = orientationLabel(for: plane.axisUWorld)
        let positiveV = orientationLabel(for: plane.axisVWorld)

        return (
            leadingLabel: positiveU.opposite,
            trailingLabel: positiveU,
            topLabel: positiveV.opposite,
            bottomLabel: positiveV
        )
    }

    static func targetLabels(for axis: MPRPlaneAxis) -> AxisEdgeLabels {
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
                          rawLabels: OrientationEdgeLabels) -> MPRDisplayTransform {
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

    static func screenLabels<Label>(orientation: MPRDisplayOrientation,
                                    flipHorizontal: Bool,
                                    flipVertical: Bool,
                                    rawLabels: (
                                        leadingLabel: Label,
                                        trailingLabel: Label,
                                        topLabel: Label,
                                        bottomLabel: Label
                                    )) -> (
                                        leadingLabel: Label,
                                        trailingLabel: Label,
                                        topLabel: Label,
                                        bottomLabel: Label
                                    ) {
        let epsilon: Float = 1e-3
        var leading: Label?
        var trailing: Label?
        var top: Label?
        var bottom: Label?

        let samples: [(SIMD2<Float>, Label)] = [
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
