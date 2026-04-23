//
//  ViewportRenderNode.swift
//  MTK
//
//  Resolved viewport node used by ViewportRenderGraph.
//

import Foundation

public struct ViewportRenderNode: Equatable, Hashable, Sendable {
    public var viewportID: ViewportID
    public var viewportType: ViewportType
    public var resolvedRoute: RenderRoute
    public var resourceHandle: VolumeResourceHandle?

    public init(viewportID: ViewportID,
                resolvedRoute: RenderRoute,
                resourceHandle: VolumeResourceHandle?) {
        self.viewportID = viewportID
        self.viewportType = resolvedRoute.viewportType
        self.resolvedRoute = resolvedRoute
        self.resourceHandle = resourceHandle
    }
}
