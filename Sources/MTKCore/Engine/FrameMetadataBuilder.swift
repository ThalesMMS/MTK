//
//  FrameMetadataBuilder.swift
//  MTK
//
//  Builds RenderFrame metadata and outputs from render results.
//

import CoreGraphics
import Foundation
@preconcurrency import Metal

/// Focused helper to construct `FrameMetadata` and `RenderFrame` instances from
/// the results of executing a validated render route.
///
/// This service is intentionally small and has no side effects; it exists to
/// isolate the frame-output construction currently embedded in
/// `MTKRenderingEngine`.
struct FrameMetadataBuilder {
    struct Inputs {
        let viewportID: ViewportID
        let viewportSize: CGSize
        let route: RenderRoute
        let texture: any MTLTexture
        let mprFrame: MPRTextureFrame?
        let outputTextureLease: OutputTextureLease?
        let renderDuration: CFAbsoluteTime?
        let raycastDuration: CFAbsoluteTime?
        let uploadDuration: CFAbsoluteTime?
        let presentDuration: CFAbsoluteTime?
    }

    func makeMetadata(from inputs: Inputs) -> FrameMetadata {
        FrameMetadata(
            viewportSize: inputs.viewportSize,
            renderTime: inputs.renderDuration,
            raycastTime: inputs.raycastDuration,
            uploadTime: inputs.uploadDuration,
            presentTime: inputs.presentDuration,
            renderGraphRoute: inputs.route.profilingName
        )
    }

    func makeFrame(from inputs: Inputs) -> RenderFrame {
        let metadata = makeMetadata(from: inputs)
        return RenderFrame(
            texture: inputs.texture,
            viewportID: inputs.viewportID,
            route: inputs.route,
            metadata: metadata,
            mprFrame: inputs.mprFrame,
            outputTextureLease: inputs.outputTextureLease
        )
    }
}
