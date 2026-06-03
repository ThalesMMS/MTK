//
//  SurfaceMeshProcessingOptions.swift
//  MTKCore
//

import Foundation

public struct SurfaceMeshProcessingOptions: Sendable, Equatable {
    public var repairsTopology: Bool
    public var smoothingIterations: Int
    public var smoothingRelaxation: Float
    public var decimationRatio: Float

    public init(repairsTopology: Bool = true,
                smoothingIterations: Int = 0,
                smoothingRelaxation: Float = 0.35,
                decimationRatio: Float = 1) {
        self.repairsTopology = repairsTopology
        self.smoothingIterations = smoothingIterations
        self.smoothingRelaxation = smoothingRelaxation
        self.decimationRatio = decimationRatio
    }

    public static let disabled = SurfaceMeshProcessingOptions(repairsTopology: false,
                                                              smoothingIterations: 0,
                                                              decimationRatio: 1)
    public static let clinicalDefault = SurfaceMeshProcessingOptions()

    var clampedSmoothingIterations: Int {
        min(max(smoothingIterations, 0), 12)
    }

    var clampedSmoothingRelaxation: Float {
        guard smoothingRelaxation.isFinite else { return 0.35 }
        return min(max(smoothingRelaxation, 0), 1)
    }

    var clampedDecimationRatio: Float {
        guard decimationRatio.isFinite else { return 1 }
        return min(max(decimationRatio, 0.05), 1)
    }
}
