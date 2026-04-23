//
//  MPRTextureFrame.swift
//  MTK
//
//  GPU-native MPR frame carrying raw 16-bit intensity texture output.
//

import Foundation
@preconcurrency import Metal

public struct MPRTextureFrame {
    public var texture: any MTLTexture
    public var intensityRange: ClosedRange<Int32>
    public var pixelFormat: VolumePixelFormat
    public var viewportID: ViewportID?
    public var planeGeometry: MPRPlaneGeometry

    public init(texture: any MTLTexture,
                intensityRange: ClosedRange<Int32>,
                pixelFormat: VolumePixelFormat,
                viewportID: ViewportID? = nil,
                planeGeometry: MPRPlaneGeometry) {
        self.texture = texture
        self.intensityRange = intensityRange
        self.pixelFormat = pixelFormat
        self.viewportID = viewportID
        self.planeGeometry = planeGeometry
    }

    public var textureFormatMatchesPixelFormat: Bool {
        texture.pixelFormat == pixelFormat.rawIntensityMetalPixelFormat
    }
}

// Metal texture handles are shared GPU resources. The frame is handed out only
// after command encoding has completed; callers must treat the texture as an
// immutable raw intensity result.
extension MPRTextureFrame: @unchecked Sendable {}

public extension VolumePixelFormat {
    var rawIntensityMetalPixelFormat: MTLPixelFormat {
        switch self {
        case .int16Signed:
            return .r16Sint
        case .int16Unsigned:
            return .r16Uint
        }
    }
}
