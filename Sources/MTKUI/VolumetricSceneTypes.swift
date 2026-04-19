import Foundation
import MTKCore

public enum VolumetricRenderMethod: String, CaseIterable, Identifiable, Sendable {
    case dvr
    case mip
    case minip
    case avg

    public var id: String { rawValue }

    var compositing: VolumeRenderRequest.Compositing {
        switch self {
        case .dvr:
            return .frontToBack
        case .mip:
            return .maximumIntensity
        case .minip:
            return .minimumIntensity
        case .avg:
            return .averageIntensity
        }
    }

    var methodID: Int32 {
        switch self {
        case .dvr:
            return 1
        case .mip:
            return 2
        case .minip:
            return 3
        case .avg:
            return 4
        }
    }
}

public enum VolumetricMPRBlendMode: Int, CaseIterable, Identifiable, Sendable {
    case single = 0
    case mip = 1
    case minip = 2
    case mean = 3

    public var id: Int { rawValue }

    var coreBlend: MPRBlendMode {
        switch self {
        case .single:
            return .single
        case .mip:
            return .maximum
        case .minip:
            return .minimum
        case .mean:
            return .average
        }
    }
}

public struct VolumetricHUWindowMapping: Equatable, Sendable {
    public var minHU: Int32
    public var maxHU: Int32
    public var tfMin: Float
    public var tfMax: Float

    public init(minHU: Int32, maxHU: Int32, tfMin: Float, tfMax: Float) {
        self.minHU = minHU
        self.maxHU = maxHU
        self.tfMin = tfMin
        self.tfMax = tfMax
    }

    public static func makeHuWindowMapping(minHU: Int32,
                                           maxHU: Int32,
                                           datasetRange: ClosedRange<Int32>,
                                           transferDomain: ClosedRange<Float>?) -> VolumetricHUWindowMapping {
        let resolvedWindow = normalizedWindow(minHU: minHU,
                                              maxHU: maxHU,
                                              datasetRange: datasetRange)
        let domain = transferDomain ?? Float(datasetRange.lowerBound)...Float(datasetRange.upperBound)
        let lowerBound = domain.lowerBound
        let upperBound = domain.upperBound
        let span = upperBound - lowerBound

        let normalized: (Float) -> Float = { value in
            guard span.magnitude > .ulpOfOne else { return 0 }
            let clamped = max(lowerBound, min(value, upperBound))
            return (clamped - lowerBound) / span
        }

        let lower = normalized(Float(resolvedWindow.lowerBound))
        let upper = normalized(Float(resolvedWindow.upperBound))

        return VolumetricHUWindowMapping(
            minHU: resolvedWindow.lowerBound,
            maxHU: resolvedWindow.upperBound,
            tfMin: min(lower, upper),
            tfMax: max(lower, upper)
        )
    }

    static func normalizedWindow(minHU: Int32,
                                 maxHU: Int32,
                                 datasetRange: ClosedRange<Int32>) -> ClosedRange<Int32> {
        let clampedMin = max(datasetRange.lowerBound, min(minHU, datasetRange.upperBound))
        let candidateMax = max(datasetRange.lowerBound, min(maxHU, datasetRange.upperBound))
        let clampedMax = max(clampedMin, candidateMax)

        if clampedMax > clampedMin {
            return clampedMin...clampedMax
        }

        if datasetRange.lowerBound < datasetRange.upperBound {
            return datasetRange.lowerBound...datasetRange.upperBound
        }

        let anchor = datasetRange.lowerBound
        let expandedMin = anchor == Int32.min ? anchor : anchor - 1
        let expandedMax = anchor == Int32.max ? anchor : anchor + 1
        return expandedMin...expandedMax
    }
}
