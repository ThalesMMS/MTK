//
//  ViewportRenderNode.swift
//  MTK
//
//  Resolved viewport node used by ViewportRenderGraph.
//

import Foundation

package struct ViewportRenderNode: Equatable, Hashable, Sendable {
    package var viewportID: ViewportID
    package var viewportType: ViewportType
    package var resolvedRoute: RenderRoute
    package var resourceHandle: VolumeResourceHandle?

    package init(viewportID: ViewportID,
                resolvedRoute: RenderRoute,
                resourceHandle: VolumeResourceHandle?) {
        self.viewportID = viewportID
        self.viewportType = resolvedRoute.viewportType
        self.resolvedRoute = resolvedRoute
        self.resourceHandle = resourceHandle
    }
}
