//
//  CPRPath.swift
//  MTK
//
//  Curved planar reformation centerline sampling and perpendicular geometry.
//

import Foundation
import simd

public enum CPRPathError: Error, Equatable, LocalizedError {
    case insufficientDistinctControlPoints
    case invalidSampleSpacing

    public var errorDescription: String? {
        switch self {
        case .insufficientDistinctControlPoints:
            return "A CPR centerline requires at least two distinct points."
        case .invalidSampleSpacing:
            return "CPR sample spacing must be a positive finite distance."
        }
    }
}

public struct CPRPathSample: Sendable, Equatable {
    public var positionWorld: SIMD3<Float>
    public var tangentWorld: SIMD3<Float>
    public var distanceMillimeters: Float

    public init(positionWorld: SIMD3<Float>,
                tangentWorld: SIMD3<Float>,
                distanceMillimeters: Float) {
        self.positionWorld = positionWorld
        self.tangentWorld = tangentWorld
        self.distanceMillimeters = distanceMillimeters
    }
}

public struct CPRSampledPath: Sendable, Equatable {
    public var controlPointsWorld: [SIMD3<Float>]
    public var samples: [CPRPathSample]
    public var lengthMillimeters: Float

    public init(controlPointsWorld: [SIMD3<Float>],
                samples: [CPRPathSample],
                lengthMillimeters: Float) {
        self.controlPointsWorld = controlPointsWorld
        self.samples = samples
        self.lengthMillimeters = lengthMillimeters
    }

    public func sample(at progress: Float) -> CPRPathSample {
        guard let first = samples.first else {
            return CPRPathSample(positionWorld: .zero,
                                 tangentWorld: SIMD3<Float>(0, 0, 1),
                                 distanceMillimeters: 0)
        }
        guard samples.count > 1, lengthMillimeters > 0 else { return first }
        let target = min(max(progress.isFinite ? progress : 0, 0), 1) * lengthMillimeters
        guard let upperIndex = samples.firstIndex(where: { $0.distanceMillimeters >= target }) else {
            return samples[samples.count - 1]
        }
        guard upperIndex > 0 else { return samples[0] }
        let lower = samples[upperIndex - 1]
        let upper = samples[upperIndex]
        let span = upper.distanceMillimeters - lower.distanceMillimeters
        let fraction = span > Float.ulpOfOne
            ? (target - lower.distanceMillimeters) / span
            : 0
        return CPRPathSample(
            positionWorld: simd_mix(lower.positionWorld, upper.positionWorld, SIMD3<Float>(repeating: fraction)),
            tangentWorld: CPRPathSampler.normalized(
                simd_mix(lower.tangentWorld, upper.tangentWorld, SIMD3<Float>(repeating: fraction)),
                fallback: lower.tangentWorld
            ),
            distanceMillimeters: target
        )
    }
}

public enum CPRPathSampler {
    private static let duplicateTolerance: Float = 1e-4
    private static let denseSampleSpacingMillimeters: Float = 0.25

    public static func sample(controlPointsWorld: [SIMD3<Float>],
                              spacingMillimeters: Float = 1) throws -> CPRSampledPath {
        guard spacingMillimeters.isFinite, spacingMillimeters > 0 else {
            throw CPRPathError.invalidSampleSpacing
        }
        let controlPoints = distinctFinitePoints(controlPointsWorld)
        guard controlPoints.count >= 2 else {
            throw CPRPathError.insufficientDistinctControlPoints
        }

        let densePoints = makeDenseCatmullRomPath(controlPoints)
        let cumulativeDistances = cumulativeDistances(for: densePoints)
        guard let totalLength = cumulativeDistances.last,
              totalLength > duplicateTolerance else {
            throw CPRPathError.insufficientDistinctControlPoints
        }

        var targetDistances = Array(stride(from: Float.zero,
                                           to: totalLength,
                                           by: spacingMillimeters))
        if targetDistances.last.map({ totalLength - $0 > duplicateTolerance }) ?? true {
            targetDistances.append(totalLength)
        } else {
            targetDistances[targetDistances.count - 1] = totalLength
        }
        let positions = targetDistances.map {
            interpolatedPoint(at: $0,
                              points: densePoints,
                              cumulativeDistances: cumulativeDistances)
        }
        let samples = positions.indices.map { index in
            let previous = positions[max(index - 1, 0)]
            let next = positions[min(index + 1, positions.count - 1)]
            let fallback = index > 0
                ? positions[index] - positions[index - 1]
                : positions[min(1, positions.count - 1)] - positions[0]
            return CPRPathSample(
                positionWorld: positions[index],
                tangentWorld: normalized(next - previous, fallback: fallback),
                distanceMillimeters: targetDistances[index]
            )
        }
        return CPRSampledPath(controlPointsWorld: controlPoints,
                              samples: samples,
                              lengthMillimeters: totalLength)
    }

    static func normalized(_ vector: SIMD3<Float>,
                           fallback: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(vector)
        if length.isFinite, length > duplicateTolerance {
            return vector / length
        }
        let fallbackLength = simd_length(fallback)
        if fallbackLength.isFinite, fallbackLength > duplicateTolerance {
            return fallback / fallbackLength
        }
        return SIMD3<Float>(0, 0, 1)
    }

    private static func distinctFinitePoints(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        points.reduce(into: []) { result, point in
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { return }
            guard result.last.map({ simd_distance($0, point) > duplicateTolerance }) ?? true else { return }
            result.append(point)
        }
    }

    private static func makeDenseCatmullRomPath(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        var result = [points[0]]
        for index in 0..<(points.count - 1) {
            let p0 = points[max(index - 1, 0)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(index + 2, points.count - 1)]
            let segmentLength = simd_distance(p1, p2)
            let subdivisions = max(8, Int(ceil(segmentLength / denseSampleSpacingMillimeters)))
            for step in 1...subdivisions {
                let t = Float(step) / Float(subdivisions)
                result.append(catmullRom(p0: p0, p1: p1, p2: p2, p3: p3, t: t))
            }
        }
        result[0] = points[0]
        result[result.count - 1] = points[points.count - 1]
        return result
    }

    private static func catmullRom(p0: SIMD3<Float>,
                                   p1: SIMD3<Float>,
                                   p2: SIMD3<Float>,
                                   p3: SIMD3<Float>,
                                   t: Float) -> SIMD3<Float> {
        let t2 = t * t
        let t3 = t2 * t
        let constant = p1 * 2
        let linear = (p2 - p0) * t
        var quadraticCoefficient = p0 * 2
        quadraticCoefficient -= p1 * 5
        quadraticCoefficient += p2 * 4
        quadraticCoefficient -= p3
        let quadratic = quadraticCoefficient * t2
        var cubicCoefficient = -p0
        cubicCoefficient += p1 * 3
        cubicCoefficient -= p2 * 3
        cubicCoefficient += p3
        let cubic = cubicCoefficient * t3
        return (constant + linear + quadratic + cubic) * 0.5
    }

    private static func cumulativeDistances(for points: [SIMD3<Float>]) -> [Float] {
        guard !points.isEmpty else { return [] }
        var result = [Float](repeating: 0, count: points.count)
        for index in 1..<points.count {
            result[index] = result[index - 1] + simd_distance(points[index - 1], points[index])
        }
        return result
    }

    private static func interpolatedPoint(at distance: Float,
                                          points: [SIMD3<Float>],
                                          cumulativeDistances: [Float]) -> SIMD3<Float> {
        guard distance > 0 else { return points[0] }
        guard let upperIndex = cumulativeDistances.firstIndex(where: { $0 >= distance }) else {
            return points[points.count - 1]
        }
        guard upperIndex > 0 else { return points[0] }
        let lowerIndex = upperIndex - 1
        let span = cumulativeDistances[upperIndex] - cumulativeDistances[lowerIndex]
        let fraction = span > duplicateTolerance
            ? (distance - cumulativeDistances[lowerIndex]) / span
            : 0
        return simd_mix(points[lowerIndex],
                        points[upperIndex],
                        SIMD3<Float>(repeating: fraction))
    }
}

public enum CPRPlaneFactory {
    public static func makePerpendicularPlane(path: CPRSampledPath,
                                              progress: Float,
                                              dataset: VolumeDataset,
                                              outputSize: Int = 384) -> MPRPlaneGeometry {
        let sample = path.sample(at: progress)
        let tangent = CPRPathSampler.normalized(sample.tangentWorld,
                                                fallback: dataset.imageData.sliceDirection)
        let reference = leastParallelDirection(to: tangent, dataset: dataset)
        let axisUUnit = CPRPathSampler.normalized(simd_cross(tangent, reference),
                                                  fallback: dataset.imageData.rowDirection)
        let axisVUnit = CPRPathSampler.normalized(simd_cross(tangent, axisUUnit),
                                                  fallback: dataset.imageData.columnDirection)
        let span = physicalSpan(for: dataset)
        let axisUWorld = axisUUnit * span
        let axisVWorld = axisVUnit * span
        let originWorld = sample.positionWorld - 0.5 * axisUWorld - 0.5 * axisVWorld
        return makePlane(originWorld: originWorld,
                         axisUWorld: axisUWorld,
                         axisVWorld: axisVWorld,
                         normalWorld: tangent,
                         dataset: dataset,
                         outputWidth: outputSize,
                         outputHeight: outputSize)
    }

    public static func physicalSpan(for dataset: VolumeDataset) -> Float {
        let dimensions = dataset.dimensions
        let spacing = dataset.spacing
        return simd_length(
            SIMD3<Float>(
                Float(max(dimensions.width - 1, 1)) * Float(spacing.x),
                Float(max(dimensions.height - 1, 1)) * Float(spacing.y),
                Float(max(dimensions.depth - 1, 1)) * Float(spacing.z)
            )
        )
    }

    static func makePlane(originWorld: SIMD3<Float>,
                          axisUWorld: SIMD3<Float>,
                          axisVWorld: SIMD3<Float>,
                          normalWorld: SIMD3<Float>,
                          dataset: VolumeDataset,
                          outputWidth: Int,
                          outputHeight: Int) -> MPRPlaneGeometry {
        let worldToIndex = dataset.imageData.worldToIndex
        let worldToTexture = dataset.imageData.worldToTexture
        let originVoxel = transformPoint(originWorld, by: worldToIndex)
        let endUVoxel = transformPoint(originWorld + axisUWorld, by: worldToIndex)
        let endVVoxel = transformPoint(originWorld + axisVWorld, by: worldToIndex)
        let originTexture = transformPoint(originWorld, by: worldToTexture)
        let endUTexture = transformPoint(originWorld + axisUWorld, by: worldToTexture)
        let endVTexture = transformPoint(originWorld + axisVWorld, by: worldToTexture)
        return MPRPlaneGeometry(
            originVoxel: originVoxel,
            axisUVoxel: endUVoxel - originVoxel,
            axisVVoxel: endVVoxel - originVoxel,
            outputWidth: max(1, outputWidth),
            outputHeight: max(1, outputHeight),
            originWorld: originWorld,
            axisUWorld: axisUWorld,
            axisVWorld: axisVWorld,
            originTexture: originTexture,
            axisUTexture: endUTexture - originTexture,
            axisVTexture: endVTexture - originTexture,
            normalWorld: normalWorld
        )
    }

    static func leastParallelDirection(to tangent: SIMD3<Float>,
                                       dataset: VolumeDataset) -> SIMD3<Float> {
        let candidates = [
            dataset.imageData.rowDirection,
            dataset.imageData.columnDirection,
            dataset.imageData.sliceDirection
        ]
        return candidates.min(by: { abs(simd_dot($0, tangent)) < abs(simd_dot($1, tangent)) })
            ?? SIMD3<Float>(0, 0, 1)
    }

    static func transformPoint(_ point: SIMD3<Float>,
                               by matrix: simd_float4x4) -> SIMD3<Float> {
        let result = matrix * SIMD4<Float>(point, 1)
        return SIMD3<Float>(result.x, result.y, result.z)
    }
}
