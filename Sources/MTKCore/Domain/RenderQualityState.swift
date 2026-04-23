//
//  RenderQualityState.swift
//  MTKCore
//
//  Shared render quality state for preview and final Metal-native rendering.
//

import Foundation

public enum RenderQualityState: Sendable, Equatable {
    case interacting
    case settling
    case settled

    public var isPreview: Bool {
        switch self {
        case .interacting, .settling:
            return true
        case .settled:
            return false
        }
    }
}

public struct RenderQualityParameters: Sendable, Equatable {
    public var volumeSamplingStep: Float
    public var mprSlabStepsFactor: Float
    public var qualityTier: VolumeRenderRequest.Quality

    public init(volumeSamplingStep: Float,
                mprSlabStepsFactor: Float,
                qualityTier: VolumeRenderRequest.Quality) {
        self.volumeSamplingStep = volumeSamplingStep
        self.mprSlabStepsFactor = mprSlabStepsFactor
        self.qualityTier = qualityTier
    }
}
