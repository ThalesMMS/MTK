//
//  VolumeDensityTextureBindingError.swift
//  MTK
//

import Foundation
import Metal

enum VolumeDensityTextureBindingError: LocalizedError {
    case unsupportedPixelFormat(MTLPixelFormat)
    case viewCreationFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedPixelFormat(let pixelFormat):
            return "Volume raycasting requires r16Sint, r16Uint, r16Snorm, or r16Unorm input, got \(pixelFormat)."
        case .viewCreationFailed:
            return "Unable to create the filterable normalized volume texture view."
        }
    }
}
