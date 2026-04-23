//
//  RenderFrame.swift
//  MTK
//
//  GPU-native frame output for MTKRenderingEngine.
//

import CoreGraphics
import Foundation
@preconcurrency import Metal

public struct FrameMetadata: Sendable {
    public var viewportSize: CGSize
    public var renderTime: CFAbsoluteTime?
    public var raycastTime: CFAbsoluteTime?
    public var uploadTime: CFAbsoluteTime?
    public var presentTime: CFAbsoluteTime?
    public var renderGraphRoute: String?

    public init(viewportSize: CGSize,
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

public struct RenderFrame {
    public var texture: any MTLTexture
    public var viewportID: ViewportID
    public var route: RenderRoute
    public var metadata: FrameMetadata
    public var mprFrame: MPRTextureFrame?
    public var outputTextureLease: OutputTextureLease?

    public var hasPooledTexture: Bool {
        outputTextureLease != nil
    }

    public init(texture: any MTLTexture,
                viewportID: ViewportID,
                route: RenderRoute,
                metadata: FrameMetadata,
                mprFrame: MPRTextureFrame? = nil,
                outputTextureLease: OutputTextureLease? = nil) {
        self.texture = texture
        self.viewportID = viewportID
        self.route = route
        self.metadata = metadata
        self.mprFrame = mprFrame
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
