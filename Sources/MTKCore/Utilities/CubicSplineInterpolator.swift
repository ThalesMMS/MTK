//
//  CubicSplineInterpolator.swift
//  MTKCore
//
//  Provides cubic spline interpolation utilities for advanced tone curve editing.
//  Originally from MTK-Demo — Migrated to MTKCore for reusability.
//  Thales Matheus Mendonça Santos — November 2025
//

import Foundation

/// A cubic spline interpolator supporting both linear and cubic spline interpolation modes
public final class CubicSplineInterpolator {
    /// Interpolation mode for the spline
    public enum InterpolationMode: Int {
        case linear = 0
        case cubicSpline = 1
    }

    private(set) var xPoints: [Float]
    private(set) var yPoints: [Float]
    private var coefficients: [[Float]]?

    /// Current interpolation mode (linear or cubic spline)
    public var mode: InterpolationMode = .cubicSpline {
        didSet { coefficients = nil }
    }

    /// Initialize a cubic spline interpolator with control points
    /// - Parameters:
    ///   - xPoints: X coordinates of control points (must be sorted)
    ///   - yPoints: Y coordinates of control points
    public init(xPoints: [Float], yPoints: [Float]) {
        precondition(xPoints.count == yPoints.count, "x/y point count mismatch")
        precondition(xPoints.count >= 2, "At least two control points required")

        self.xPoints = xPoints
        self.yPoints = yPoints

        updateSpline(xPoints: xPoints, yPoints: yPoints)
    }

    /// Update the spline with new control points
    /// - Parameters:
    ///   - xPoints: New X coordinates of control points (must be sorted)
    ///   - yPoints: New Y coordinates of control points
    public func updateSpline(xPoints: [Float], yPoints: [Float]) {
        precondition(xPoints.count == yPoints.count, "x/y point count mismatch")
        precondition(xPoints.count >= 2, "At least two control points required")

        self.xPoints = xPoints
        self.yPoints = yPoints

        guard mode == .cubicSpline else {
            coefficients = nil
            return
        }

        calculateCoefficients()
    }

    /// Interpolate a value at the given x coordinate
    /// - Parameter x: The x coordinate to interpolate at
    /// - Returns: The interpolated y value
    public func interpolate(_ x: Float) -> Float {
        guard xPoints.count >= 2 else {
            return x
        }

        if mode == .linear || coefficients == nil {
            return linearInterpolation(at: x)
        }

        guard let coefficients else { return x }
        let segmentIndex = segmentIndex(for: x)
        let dx = x - xPoints[segmentIndex]
        let c = coefficients[segmentIndex]
        return c[0] + c[1] * dx + c[2] * (dx * dx) + c[3] * (dx * dx * dx)
    }
}

private extension CubicSplineInterpolator {
    func linearInterpolation(at x: Float) -> Float {
        if let first = xPoints.first, x <= first {
            return yPoints.first ?? x
        }
        if let last = xPoints.last, x >= last {
            return yPoints.last ?? x
        }

        let index = segmentIndex(for: x)
        let x0 = xPoints[index]
        let x1 = xPoints[index + 1]
        let y0 = yPoints[index]
        let y1 = yPoints[index + 1]

        let slope = (y1 - y0) / (x1 - x0)
        return y0 + slope * (x - x0)
    }

    func segmentIndex(for x: Float) -> Int {
        let upperBound = xPoints.count - 1
        if x <= xPoints[0] { return 0 }
        if x >= xPoints[upperBound] { return upperBound - 1 }

        var index = 0
        while index < upperBound - 1 {
            if x >= xPoints[index] && x <= xPoints[index + 1] {
                break
            }
            index += 1
        }
        return min(index, upperBound - 1)
    }

    func calculateCoefficients() {
        let count = xPoints.count
        let a = yPoints

        var b = [Float](repeating: 0, count: count)
        var d = [Float](repeating: 0, count: count)
        var h = [Float](repeating: 0, count: count)
        var alpha = [Float](repeating: 0, count: count)
        var c = [Float](repeating: 0, count: count)
        var l = [Float](repeating: 0, count: count)
        var mu = [Float](repeating: 0, count: count)
        var z = [Float](repeating: 0, count: count)

        for index in 0..<count - 1 {
            h[index] = xPoints[index + 1] - xPoints[index]
        }

        for index in 1..<count - 1 {
            alpha[index] = (3 / h[index]) * (a[index + 1] - a[index]) -
                           (3 / h[index - 1]) * (a[index] - a[index - 1])
        }

        l[0] = 1
        mu[0] = 0
        z[0] = 0

        if count >= 3 {
            for index in 1..<count - 1 {
                l[index] = 2 * (xPoints[index + 1] - xPoints[index - 1]) - h[index - 1] * mu[index - 1]
                mu[index] = h[index] / l[index]
                z[index] = (alpha[index] - h[index - 1] * z[index - 1]) / l[index]
            }
        }

        l[count - 1] = 1
        z[count - 1] = 0
        c[count - 1] = 0

        if coefficients == nil {
            coefficients = []
        } else {
            coefficients?.removeAll(keepingCapacity: true)
        }

        for index in stride(from: count - 2, through: 0, by: -1) {
            c[index] = z[index] - mu[index] * c[index + 1]
            b[index] = (a[index + 1] - a[index]) / h[index] - (h[index] * (c[index + 1] + 2 * c[index])) / 3
            d[index] = (c[index + 1] - c[index]) / (3 * h[index])
        }

        var segments: [[Float]] = []
        segments.reserveCapacity(max(count - 1, 0))
        for index in 0..<(count - 1) {
            segments.append([a[index], b[index], c[index], d[index]])
        }
        coefficients = segments
    }
}
