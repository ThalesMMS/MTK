//
//  VolumeDensityTextureBindingError.swift
//  MTKCore
//
//  Reports failures when binding signed or unsigned volume textures through filterable
//  normalized views.
//
//  Thales Matheus Mendonça Santos — July 2026
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
