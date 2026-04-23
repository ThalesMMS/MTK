//
//  VolumeRenderFrame.swift
//  MTK
//
//  GPU-native volume render output for interactive clinical rendering.
//

import CoreGraphics
import Foundation

@preconcurrency import Metal

/// GPU-native output from an interactive volume render.
///
/// `VolumeRenderFrame` is the public frame contract for clinical rendering.
/// The frame owns a completed Metal texture and lightweight metadata needed for
/// presentation, profiling, and debugging without forcing CPU readback.
/// Present ``texture`` through `MTKView`, `CAMetalLayer`, or another
/// Metal-native surface. Use ``SnapshotExporting`` only for explicit snapshot,
/// export, or visual-test readback workflows.
public struct VolumeRenderFrame {
    /// Metadata describing a rendered texture without reading pixel contents.
    public struct Metadata: Sendable {
        /// Pixel dimensions requested for presentation.
        public let viewportSize: CGSize

        /// Optional viewport identity supplied by higher-level render graph APIs.
        public let viewportID: ViewportID?

        /// Sampling distance used by the volume ray marcher.
        public let samplingDistance: Float

        /// Compositing mode used for the frame.
        public let compositing: VolumeRenderRequest.Compositing

        /// Requested render quality.
        public let quality: VolumeRenderRequest.Quality

        /// Pixel format of ``VolumeRenderFrame/texture``.
        public let pixelFormat: MTLPixelFormat

        /// CPU-observed render duration when available.
        public let renderTime: CFAbsoluteTime?

        /// GPU start timestamp when the dispatch layer exposes it.
        public let gpuStartTime: CFAbsoluteTime?

        /// GPU end timestamp when the dispatch layer exposes it.
        public let gpuEndTime: CFAbsoluteTime?

        public init(viewportSize: CGSize,
                    viewportID: ViewportID? = nil,
                    samplingDistance: Float,
                    compositing: VolumeRenderRequest.Compositing,
                    quality: VolumeRenderRequest.Quality,
                    pixelFormat: MTLPixelFormat,
                    renderTime: CFAbsoluteTime? = nil,
                    gpuStartTime: CFAbsoluteTime? = nil,
                    gpuEndTime: CFAbsoluteTime? = nil) {
            self.viewportSize = viewportSize
            self.viewportID = viewportID
            self.samplingDistance = samplingDistance
            self.compositing = compositing
            self.quality = quality
            self.pixelFormat = pixelFormat
            self.renderTime = renderTime
            self.gpuStartTime = gpuStartTime
            self.gpuEndTime = gpuEndTime
        }

        public init(request: VolumeRenderRequest,
                    texture: any MTLTexture,
                    viewportID: ViewportID? = nil,
                    renderTime: CFAbsoluteTime? = nil,
                    gpuStartTime: CFAbsoluteTime? = nil,
                    gpuEndTime: CFAbsoluteTime? = nil) {
            self.init(viewportSize: CGSize(width: CGFloat(texture.width),
                                           height: CGFloat(texture.height)),
                      viewportID: viewportID,
                      samplingDistance: request.samplingDistance,
                      compositing: request.compositing,
                      quality: request.quality,
                      pixelFormat: texture.pixelFormat,
                      renderTime: renderTime,
                      gpuStartTime: gpuStartTime,
                      gpuEndTime: gpuEndTime)
        }
    }

    /// Completed GPU output for interactive presentation.
    public let texture: any MTLTexture

    /// Frame metadata for presentation, profiling, and debugging.
    public let metadata: Metadata

    public init(texture: any MTLTexture, metadata: Metadata) {
        self.texture = texture
        self.metadata = metadata
    }
}

// `VolumeRenderFrame` is sendable by construction: Metal command encoding has
// completed before callers receive the texture, and adapter state remains actor-isolated.
extension VolumeRenderFrame: @unchecked Sendable {}
