//
//  AdvancedToneCurveModel.swift
//  MTKCore
//
//  Provides cubic-spline tone curve editing and auto-window presets for advanced volume rendering.
//  Originally from MTK-Demo — Migrated to MTKCore for reusability.
//  Thales Matheus Mendonça Santos — November 2025
//

import Foundation

/// A point in a tone curve mapping
public struct AdvancedToneCurvePoint: Codable, Equatable {
    /// X coordinate (0...255)
    public var x: Float
    /// Y coordinate (0...1)
    public var y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }
}

/// Predefined auto-windowing presets for different anatomical regions
public struct ToneCurveAutoWindowPreset: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let lowerPercentile: Double?
    public let upperPercentile: Double?
    public let smoothingRadius: Int

    public init(id: String, title: String, lowerPercentile: Double?, upperPercentile: Double?, smoothingRadius: Int) {
        self.id = id
        self.title = title
        self.lowerPercentile = lowerPercentile
        self.upperPercentile = upperPercentile
        self.smoothingRadius = smoothingRadius
    }

    /// Abdomen CT auto-window preset
    public static let abdomen = ToneCurveAutoWindowPreset(
        id: "auto.abdomen",
        title: "Abdomen CT",
        lowerPercentile: 0.10,
        upperPercentile: 0.90,
        smoothingRadius: 3
    )

    /// Lung tissue auto-window preset
    public static let lung = ToneCurveAutoWindowPreset(
        id: "auto.lung",
        title: "Lung",
        lowerPercentile: 0.005,
        upperPercentile: 0.60,
        smoothingRadius: 4
    )

    /// Bone tissue auto-window preset
    public static let bone = ToneCurveAutoWindowPreset(
        id: "auto.bone",
        title: "Bone",
        lowerPercentile: 0.40,
        upperPercentile: 0.995,
        smoothingRadius: 2
    )

    /// Otsu threshold auto-window preset
    public static let otsu = ToneCurveAutoWindowPreset(
        id: "auto.otsu",
        title: "Otsu",
        lowerPercentile: nil,
        upperPercentile: nil,
        smoothingRadius: 3
    )

    /// All available auto-window presets
    public static let allPresets: [ToneCurveAutoWindowPreset] = [.abdomen, .lung, .bone, .otsu]
}

/// Advanced tone curve model supporting cubic spline interpolation and auto-windowing
public final class AdvancedToneCurveModel {
    /// Sampling scale for curve generation
    public static let sampleScale: Int = 10

    /// Minimum delta between control points on X axis
    public static let minimumDeltaX: Float = 0.5

    /// Valid range for X coordinates
    public static let xRange: ClosedRange<Float> = 0...255

    /// Valid range for Y coordinates
    public static let yRange: ClosedRange<Float> = 0...1

    /// Number of samples in the generated curve
    public static var sampleCount: Int { Int(255 * sampleScale) + 1 }

    private(set) var controlPoints: [AdvancedToneCurvePoint] {
        didSet { rebuildSpline() }
    }

    private var spline: CubicSplineInterpolator?
    private(set) var histogram: [UInt32] = [] {
        didSet { cachedSmoothedHistogram = nil }
    }

    private var cachedSmoothedHistogram: [Double]?

    /// Current interpolation mode (linear or cubic spline)
    public var interpolationMode: CubicSplineInterpolator.InterpolationMode = .cubicSpline {
        didSet { rebuildSpline() }
    }

    /// Initialize a tone curve model with optional control points
    /// - Parameter points: Initial control points (defaults to a standard S-curve)
    public init(points: [AdvancedToneCurvePoint] = AdvancedToneCurveModel.defaultControlPoints()) {
        self.controlPoints = AdvancedToneCurveModel.sanitized(points)
        rebuildSpline()
    }

    /// Set the histogram data for auto-windowing algorithms
    /// - Parameter values: Histogram values (typically 256 or 512 bins)
    public func setHistogram(_ values: [UInt32]) {
        // Validate histogram size (typically 256 or 512 bins)
        guard values.count == 256 || values.count == 512 else {
            assertionFailure("Histogram must have 256 or 512 bins. Received \(values.count).")
            return
        }
        histogram = values
    }

    /// Get the current control points
    /// - Returns: Array of control points
    public func currentControlPoints() -> [AdvancedToneCurvePoint] {
        controlPoints
    }

    /// Reset the curve to default control points
    public func reset() {
        controlPoints = AdvancedToneCurveModel.defaultControlPoints()
    }

    /// Set new control points (will be sanitized automatically)
    /// - Parameter points: New control points
    public func setControlPoints(_ points: [AdvancedToneCurvePoint]) {
        controlPoints = AdvancedToneCurveModel.sanitized(points)
    }

    /// Update a specific control point
    /// - Parameters:
    ///   - index: Index of the point to update
    ///   - newPoint: New point value
    public func updatePoint(at index: Int, to newPoint: AdvancedToneCurvePoint) {
        guard controlPoints.indices.contains(index) else { return }
        var updated = controlPoints
        updated[index] = newPoint
        controlPoints = AdvancedToneCurveModel.sanitized(updated, preservingIndex: index)
    }

    /// Insert a new control point
    /// - Parameter point: Point to insert
    public func insertPoint(_ point: AdvancedToneCurvePoint) {
        var updated = controlPoints
        updated.append(point)
        controlPoints = AdvancedToneCurveModel.sanitized(updated)
    }

    /// Remove a control point at the given index
    /// - Parameter index: Index of point to remove (cannot remove endpoints)
    /// Remove a control point at the given index
    /// - Parameter index: Index of point to remove (cannot remove endpoints)
    /// - Returns: true if the point was removed, false otherwise
    @discardableResult
    public func removePoint(at index: Int) -> Bool {
        guard controlPoints.indices.contains(index) else { return false }
        guard index != 0 && index != controlPoints.count - 1 else { return false }
        controlPoints.remove(at: index)
        rebuildSpline()
        return true
    }

    /// Generate sampled values for the tone curve
    /// - Parameter scale: Sampling scale (default is sampleScale)
    /// - Returns: Array of sampled Y values
    public func sampledValues(scale: Int = AdvancedToneCurveModel.sampleScale) -> [Float] {
        guard let spline else {
            return []
        }

        let clampedScale = max(1, scale)
        let sampleCount = Int(255 * clampedScale) + 1
        let step = 1.0 / Float(clampedScale)

        var values = [Float]()
        values.reserveCapacity(sampleCount)

        var x: Float = 0
        for _ in 0..<sampleCount {
            let value = max(Self.yRange.lowerBound,
                            min(Self.yRange.upperBound,
                                spline.interpolate(x)))
            values.append(value)
            x += step
        }
        return values
    }

    /// Apply an auto-window preset based on histogram data
    /// - Parameter preset: The auto-window preset to apply
    public func applyAutoWindow(_ preset: ToneCurveAutoWindowPreset) {
        guard !histogram.isEmpty else { return }

        if let lower = preset.lowerPercentile,
           let upper = preset.upperPercentile {
            applyPercentileAutoWindow(lowerPercentile: lower,
                                      upperPercentile: upper,
                                      smoothingRadius: preset.smoothingRadius)
        } else {
            applyOtsuAutoWindow(smoothingRadius: preset.smoothingRadius)
        }
    }
}

public extension AdvancedToneCurveModel {
    /// Canonical S-curve used when callers do not supply custom control points.
    static func defaultControlPoints() -> [AdvancedToneCurvePoint] {
        [
            .init(x: 0, y: 0),
            .init(x: 32, y: 0.05),
            .init(x: 96, y: 0.3),
            .init(x: 160, y: 0.7),
            .init(x: 224, y: 0.95),
            .init(x: 255, y: 1)
        ]
    }
}

// MARK: - Private helpers
private extension AdvancedToneCurveModel {
    static func sanitized(_ points: [AdvancedToneCurvePoint],
                          preservingIndex index: Int? = nil) -> [AdvancedToneCurvePoint] {
        guard !points.isEmpty else {
            return defaultControlPoints()
        }

        var sorted = points.sorted { $0.x < $1.x }

        if sorted.first?.x != xRange.lowerBound {
            sorted[0].x = xRange.lowerBound
            sorted[0].y = yRange.lowerBound
        }
        if sorted.last?.x != xRange.upperBound {
            sorted[sorted.count - 1].x = xRange.upperBound
            sorted[sorted.count - 1].y = yRange.upperBound
        }

        for current in 1..<sorted.count {
            let previous = current - 1
            if sorted[current].x <= sorted[previous].x {
                sorted[current].x = sorted[previous].x + minimumDeltaX
            }
        }

        for idx in 0..<sorted.count {
            sorted[idx].x = max(xRange.lowerBound, min(xRange.upperBound, sorted[idx].x))
            sorted[idx].y = max(yRange.lowerBound, min(yRange.upperBound, sorted[idx].y))
        }

        if let index,
           sorted.indices.contains(index) {
            // Preserve fixed x for endpoints
            if index == 0 {
                sorted[index].x = xRange.lowerBound
            } else if index == sorted.count - 1 {
                sorted[index].x = xRange.upperBound
            }
        }

        for idx in 1..<sorted.count {
            let prev = sorted[idx - 1].x
            if sorted[idx].x - prev < minimumDeltaX {
                sorted[idx].x = min(prev + minimumDeltaX, xRange.upperBound)
            }
        }

        // When points cluster near the upper bound the forward pass above may
        // saturate multiple samples at 255. Propagate adjustments backwards to
        // guarantee strictly increasing X coordinates while staying within range.
        if sorted.count >= 2 {
            for idx in stride(from: sorted.count - 2, through: 0, by: -1) {
                let next = sorted[idx + 1].x
                let maxAllowed = next - minimumDeltaX
                if sorted[idx].x > maxAllowed {
                    sorted[idx].x = max(xRange.lowerBound + Float(idx) * minimumDeltaX,
                                        maxAllowed)
                }
            }
            sorted[0].x = xRange.lowerBound
            sorted[sorted.count - 1].x = xRange.upperBound
        }

        return sorted
    }

    func rebuildSpline() {
        let xs = controlPoints.map { $0.x }
        let ys = controlPoints.map { $0.y }

        if spline == nil {
            spline = CubicSplineInterpolator(xPoints: xs, yPoints: ys)
        } else {
            spline?.updateSpline(xPoints: xs, yPoints: ys)
        }

        spline?.mode = interpolationMode
    }

    func smoothedHistogram(radius: Int) -> [Double] {
        if radius <= 0 {
            return histogram.map { Double($0) }
        }

        if let cached = cachedSmoothedHistogram, cached.count == histogram.count {
            return cached
        }

        let input = histogram.map { Double($0) }
        var output = [Double](repeating: 0, count: histogram.count)
        for index in 0..<input.count {
            let lower = max(0, index - radius)
            let upper = min(input.count - 1, index + radius)
            var sum: Double = 0
            for sample in lower...upper {
                sum += input[sample]
            }
            output[index] = sum / Double(upper - lower + 1)
        }
        cachedSmoothedHistogram = output
        return output
    }

    func percentileIndex(in distribution: [Double], percentile: Double) -> Int? {
        guard !distribution.isEmpty else { return nil }
        let clamped = max(0.0, min(percentile, 1.0))
        let total = distribution.reduce(0, +)
        guard total > 0 else { return nil }

        let target = clamped * total
        var cumulative = 0.0
        for (idx, value) in distribution.enumerated() {
            cumulative += value
            if cumulative >= target {
                return idx
            }
        }
        return distribution.count - 1
    }

    func applyPercentileAutoWindow(lowerPercentile: Double,
                                   upperPercentile: Double,
                                   smoothingRadius: Int) {
        guard lowerPercentile < upperPercentile else { return }
        let smoothed = smoothedHistogram(radius: smoothingRadius)
        guard let lowerIndex = percentileIndex(in: smoothed, percentile: lowerPercentile),
              let upperIndex = percentileIndex(in: smoothed, percentile: upperPercentile),
              lowerIndex < upperIndex else {
            return
        }
        commitAutoWindow(lowerBin: lowerIndex,
                         upperBin: upperIndex,
                         totalBins: smoothed.count)
    }

    /// Fraction of histogram bins to use for Otsu window width.
    /// Empirically, 8% provides a good balance between sensitivity and robustness for medical images.
    private static let otsuWindowWidthFraction: Double = 0.08

    func applyOtsuAutoWindow(smoothingRadius: Int) {
        let smoothed = smoothedHistogram(radius: smoothingRadius)
        guard let threshold = otsuThreshold(for: smoothed) else { return }

        let windowWidth = max(1, Int(Double(smoothed.count) * Self.otsuWindowWidthFraction))
        let lower = max(0, threshold - windowWidth)
        let upper = min(smoothed.count - 1, threshold + windowWidth)

        commitAutoWindow(lowerBin: lower, upperBin: upper, totalBins: smoothed.count)
    }

    func otsuThreshold(for histogram: [Double]) -> Int? {
        let total = histogram.reduce(0, +)
        guard total > 0 else { return nil }

        var sum: Double = 0
        for (idx, value) in histogram.enumerated() {
            sum += Double(idx) * value
        }

        var sumBackground: Double = 0
        var weightBackground: Double = 0
        var maxVariance: Double = -1
        var threshold: Int = 0

        for (idx, value) in histogram.enumerated() {
            weightBackground += value
            if weightBackground == 0 {
                continue
            }

            let weightForeground = total - weightBackground
            if weightForeground == 0 {
                break
            }

            sumBackground += Double(idx) * value
            let meanBackground = sumBackground / weightBackground
            let meanForeground = (sum - sumBackground) / weightForeground
            let betweenClassVariance = weightBackground * weightForeground * pow(meanBackground - meanForeground, 2)

            if betweenClassVariance > maxVariance {
                maxVariance = betweenClassVariance
                threshold = idx
            }
        }
        return threshold
    }

    func commitAutoWindow(lowerBin: Int, upperBin: Int, totalBins: Int) {
        guard totalBins > 1 else { return }

        let lowerPosition = Float(lowerBin) * 255.0 / Float(totalBins - 1)
        var upperPosition = Float(upperBin) * 255.0 / Float(totalBins - 1)

        if upperPosition - lowerPosition < 1 {
            upperPosition = min(255, lowerPosition + 1)
        }

        let span = max(upperPosition - lowerPosition, 1)
        let shoulder = min(20.0, span * 0.15)
        let startShoulder = max(0, lowerPosition - shoulder)
        let endShoulder = min(255, upperPosition + shoulder)
        let midLow = lowerPosition + span * 0.35
        let midHigh = lowerPosition + span * 0.75

        // The following constants define the y-values for the auto-generated tone curve control points.
        // These values were chosen to create a smooth S-shaped curve suitable for volume rendering:
        // - AUTO_CURVE_LOW_Y: Slightly above zero to allow some early ramp-up.
        // - AUTO_CURVE_MID_LOW_Y: Mid-low inflection for gentle contrast.
        // - AUTO_CURVE_MID_HIGH_Y: Mid-high inflection for strong highlight transition.
        // - AUTO_CURVE_HIGH_Y: Maximum value for full intensity.
        // Adjust these values to fine-tune the curve's contrast and shoulder behavior.
        let AUTO_CURVE_LOW_Y: Float = 0.05
        let AUTO_CURVE_MID_LOW_Y: Float = 0.35
        let AUTO_CURVE_MID_HIGH_Y: Float = 0.85
        let AUTO_CURVE_HIGH_Y: Float = 1.0

        let points: [AdvancedToneCurvePoint] = [
            .init(x: 0, y: 0),
            .init(x: startShoulder, y: 0),
            .init(x: lowerPosition, y: AUTO_CURVE_LOW_Y),
            .init(x: midLow, y: AUTO_CURVE_MID_LOW_Y),
            .init(x: midHigh, y: AUTO_CURVE_MID_HIGH_Y),
            .init(x: upperPosition, y: AUTO_CURVE_HIGH_Y),
            .init(x: endShoulder, y: AUTO_CURVE_HIGH_Y),
            .init(x: 255, y: AUTO_CURVE_HIGH_Y)
        ]

        controlPoints = AdvancedToneCurveModel.sanitized(points)
    }
}
