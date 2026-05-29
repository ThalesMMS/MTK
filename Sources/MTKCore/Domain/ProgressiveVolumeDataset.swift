import Foundation

public enum ProgressiveVolumeQuality: String, Sendable, Equatable {
    case preview
    case refinement
    case final
}

public struct ProgressiveVolumeLayer: Sendable, Equatable {
    public let index: Int
    public let totalLayerCount: Int?
    public let quality: ProgressiveVolumeQuality
    public let byteRange: Range<Int>?
    public let fractionComplete: Double
    public let isFinal: Bool

    public init(index: Int,
                totalLayerCount: Int? = nil,
                quality: ProgressiveVolumeQuality,
                byteRange: Range<Int>? = nil,
                fractionComplete: Double,
                isFinal: Bool) {
        self.index = index
        self.totalLayerCount = totalLayerCount
        self.quality = quality
        self.byteRange = byteRange
        self.fractionComplete = fractionComplete
        self.isFinal = isFinal
    }
}

public struct ProgressiveVolumeDatasetUpdate: Sendable, Equatable {
    public let layer: ProgressiveVolumeLayer
    public let dataset: VolumeDataset

    public init(layer: ProgressiveVolumeLayer, dataset: VolumeDataset) {
        self.layer = layer
        self.dataset = dataset
    }
}

public enum ProgressiveVolumeStreamPhase: String, Sendable, Equatable {
    case idle
    case streaming
    case complete
    case cancelled
}

public struct ProgressiveVolumeStreamState: Sendable, Equatable {
    public let phase: ProgressiveVolumeStreamPhase
    public let currentLayer: ProgressiveVolumeLayer?

    public init(phase: ProgressiveVolumeStreamPhase,
                currentLayer: ProgressiveVolumeLayer? = nil) {
        self.phase = phase
        self.currentLayer = currentLayer
    }

    public static let idle = ProgressiveVolumeStreamState(phase: .idle)

    public static func streaming(layer: ProgressiveVolumeLayer) -> ProgressiveVolumeStreamState {
        ProgressiveVolumeStreamState(phase: .streaming, currentLayer: layer)
    }

    public static func complete(layer: ProgressiveVolumeLayer) -> ProgressiveVolumeStreamState {
        ProgressiveVolumeStreamState(phase: .complete, currentLayer: layer)
    }

    public static func cancelled(layer: ProgressiveVolumeLayer?) -> ProgressiveVolumeStreamState {
        ProgressiveVolumeStreamState(phase: .cancelled, currentLayer: layer)
    }
}
