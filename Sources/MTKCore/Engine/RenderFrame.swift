//
//  RenderFrame.swift
//  MTK
//
//  GPU-native frame output for MTKRenderingEngine.
//

import CoreGraphics
import Foundation
@preconcurrency import Metal

package struct FrameMetadata: Sendable {
    package var viewportSize: CGSize
    package var renderTime: CFAbsoluteTime?
    package var raycastTime: CFAbsoluteTime?
    package var uploadTime: CFAbsoluteTime?
    package var presentTime: CFAbsoluteTime?
    package var renderGraphRoute: String?

    package init(viewportSize: CGSize,
                renderTime: CFAbsoluteTime? = nil,
                raycastTime: CFAbsoluteTime? = nil,
                uploadTime: CFAbsoluteTime? = nil,
                presentTime: CFAbsoluteTime? = nil,
                renderGraphRoute: String? = nil) {
        self.viewportSize = viewportSize
        self.renderTime = renderTime
        self.raycastTime = raycastTime
        self.uploadTime = uploadTime
        self.presentTime = presentTime
        self.renderGraphRoute = renderGraphRoute
    }
}

package struct RenderFrame {
    package var texture: any MTLTexture
    package var viewportID: ViewportID
    package var route: RenderRoute
    package var metadata: FrameMetadata
    package var mprFrame: MPRTextureFrame?
    package var labelmapOverlays: [MPRLabelmapOverlay]
    package var scalarOverlays: [MPRScalarVolumeOverlay]
    package var outputTextureLease: OutputTextureLease?

    package var hasPooledTexture: Bool {
        outputTextureLease != nil
    }

    package init(texture: any MTLTexture,
                viewportID: ViewportID,
                route: RenderRoute,
                metadata: FrameMetadata,
                mprFrame: MPRTextureFrame? = nil,
                labelmapOverlays: [MPRLabelmapOverlay] = [],
                scalarOverlays: [MPRScalarVolumeOverlay] = [],
                outputTextureLease: OutputTextureLease? = nil) {
        self.texture = texture
        self.viewportID = viewportID
        self.route = route
        self.metadata = metadata
        self.mprFrame = mprFrame
        self.labelmapOverlays = labelmapOverlays
        self.scalarOverlays = scalarOverlays
        self.outputTextureLease = outputTextureLease
    }
}

// `RenderFrame` is sendable by construction: the Metal `texture` and optional
// `outputTextureLease` are handed out only after the engine has finished
// encoding and committing its writes, and the lease is `@unchecked Sendable`.
// Viewport state and texture cache mutation remain serialized inside
// `MTKRenderingEngine`; callers receive a completed GPU output texture and must
// not mutate the frame through engine-owned state.
extension RenderFrame: @unchecked Sendable {}
