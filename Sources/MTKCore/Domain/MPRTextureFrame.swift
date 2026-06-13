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
    package var outputTextureLease: OutputTextureLease?
    package var outputTextureLeaseRetainedByCache: Bool

    public init(texture: any MTLTexture,
                intensityRange: ClosedRange<Int32>,
                pixelFormat: VolumePixelFormat,
                viewportID: ViewportID? = nil,
                planeGeometry: MPRPlaneGeometry) {
        self.init(texture: texture,
                  intensityRange: intensityRange,
                  pixelFormat: pixelFormat,
                  viewportID: viewportID,
                  planeGeometry: planeGeometry,
                  outputTextureLease: nil)
    }

    package init(texture: any MTLTexture,
                 intensityRange: ClosedRange<Int32>,
                 pixelFormat: VolumePixelFormat,
                 viewportID: ViewportID? = nil,
                 planeGeometry: MPRPlaneGeometry,
                 outputTextureLease: OutputTextureLease?) {
        self.texture = texture
        self.intensityRange = intensityRange
        self.pixelFormat = pixelFormat
        self.viewportID = viewportID
        self.planeGeometry = planeGeometry
        self.outputTextureLease = outputTextureLease
        self.outputTextureLeaseRetainedByCache = false
    }

    public var textureFormatMatchesPixelFormat: Bool {
        texture.pixelFormat == pixelFormat.rawIntensityMetalPixelFormat
    }

    package func releaseOutputTextureLease() {
        outputTextureLease?.release()
    }

    package func releaseOutputTextureLeaseAfterPresentationCompletes() {
        outputTextureLease?.releaseAfterPresentationCompletes()
    }

    package var presentationManagedOutputTextureLease: OutputTextureLease? {
        outputTextureLeaseRetainedByCache ? nil : outputTextureLease
    }
}

@_spi(Testing) public extension MPRTextureFrame {
    var debugHasOutputTextureLease: Bool {
        guard let outputTextureLease else { return false }
        return !outputTextureLease.isReleased
    }

    func debugReleaseOutputTextureLease() {
        releaseOutputTextureLease()
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
