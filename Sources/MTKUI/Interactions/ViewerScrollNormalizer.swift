//
//  ViewerScrollNormalizer.swift
//  MTKUI
//
//  Scroll-wheel/trackpad normalization for viewer interactions
//  (issue #1213): converts heterogeneous scroll deltas — line-based mouse
//  wheels vs pixel-precise trackpads, natural vs inverted direction — into
//  discrete slice steps or smooth zoom factors, consistently across
//  iPadOS pointers and macOS.
//

import Foundation

/// One normalized scroll event, pre-classified by the platform layer.
public struct ViewerScrollEvent: Sendable, Equatable {
    /// Vertical delta. Positive scrolls content up (finger down on natural
    /// trackpads).
    public var delta: CGFloat
    /// `true` for pixel-precise input (trackpads, Magic Mouse), `false`
    /// for line-based wheel ticks.
    public var isPrecise: Bool
    /// Whether a zoom modifier (e.g. ⌘) was held.
    public var hasZoomModifier: Bool

    public init(delta: CGFloat, isPrecise: Bool, hasZoomModifier: Bool = false) {
        self.delta = delta
        self.isPrecise = isPrecise
        self.hasZoomModifier = hasZoomModifier
    }
}

/// Stateful accumulator turning scroll deltas into whole slice steps.
/// Precise deltas accumulate until they pass the per-step threshold; wheel
/// ticks map one line to one step.
public struct ViewerScrollSliceAccumulator: Sendable, Equatable {
    /// Pixels of precise scroll required per slice step.
    public var pointsPerStep: CGFloat
    /// Inverts direction (user preference / natural scrolling).
    public var invertsDirection: Bool
    private var residual: CGFloat = 0

    public init(pointsPerStep: CGFloat = 24, invertsDirection: Bool = false) {
        self.pointsPerStep = max(1, pointsPerStep)
        self.invertsDirection = invertsDirection
    }

    /// Consumes an event and returns the whole slice steps it produced
    /// (positive = forward). Residual movement carries to the next event.
    public mutating func consume(_ event: ViewerScrollEvent) -> Int {
        let direction: CGFloat = invertsDirection ? -1 : 1
        if event.isPrecise {
            residual += event.delta * direction
            let steps = Int((residual / pointsPerStep).rounded(.towardZero))
            residual -= CGFloat(steps) * pointsPerStep
            return steps
        }
        // Line-based wheels: every tick is a step; residual does not apply.
        let steps = Int((event.delta * direction).rounded(.awayFromZero))
        return steps
    }

    /// Drops any accumulated sub-step movement (e.g. when the pointer
    /// leaves the viewport).
    public mutating func reset() {
        residual = 0
    }
}

/// Pure zoom normalization shared by pointer scroll-zoom paths.
public enum ViewerScrollZoomNormalizer {
    /// Converts a scroll delta into a multiplicative zoom factor.
    /// Sensitivity is per-100-points; precise input uses the delta as-is,
    /// wheel ticks are amplified to feel comparable.
    public static func zoomFactor(
        for event: ViewerScrollEvent,
        sensitivity: CGFloat = 0.5
    ) -> CGFloat {
        let effectiveDelta = event.isPrecise ? event.delta : event.delta * 12
        let exponent = (effectiveDelta / 100) * sensitivity
        return pow(2, exponent)
    }
}
