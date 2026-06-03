//
//  RegisteredVolumeLayerResamplingError.swift
//  MTKCore
//
//  Errors produced while resampling registered scalar volume layers.
//

import Foundation

public enum RegisteredVolumeLayerResamplingError: Error, Equatable, LocalizedError {
    case unsupportedTransform(layerID: String, classification: LayerTransform.Classification)

    public var errorDescription: String? {
        switch self {
        case .unsupportedTransform(let layerID, let classification):
            return "Scalar volume layer \(layerID) uses unsupported \(classification.rawValue) transform."
        }
    }
}
