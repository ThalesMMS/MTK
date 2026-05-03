//
//  RenderRouteResolver.swift
//  MTK
//
//  Resolves and validates render routes for clinical viewports.
//

import Foundation

/// Focused service responsible for render-route resolution and preflight validation.
///
/// This type is intentionally thin and delegates to `ViewportRenderGraph` for the
/// canonical routing table and validation semantics.
public struct RenderRouteResolver: Sendable {
    public init() {}

    public func resolveNode(viewportID: ViewportID,
                            viewportType: ViewportType,
                            resourceHandle: VolumeResourceHandle?,
                            using renderGraph: ViewportRenderGraph) throws -> ViewportRenderNode {
        try renderGraph.buildRenderNode(viewportID: viewportID,
                                        viewportType: viewportType,
                                        resourceHandle: resourceHandle)
    }

    public func validateRequirements(for node: ViewportRenderNode,
                                     datasetAvailable: Bool,
                                     volumeTextureAvailable: Bool,
                                     surfaceAvailable: Bool,
                                     transferTextureAvailable: Bool,
                                     using renderGraph: ViewportRenderGraph) throws {
        try renderGraph.validateRenderRequirements(node: node,
                                                   datasetAvailable: datasetAvailable,
                                                   volumeTextureAvailable: volumeTextureAvailable,
                                                   surfaceAvailable: surfaceAvailable,
                                                   transferTextureAvailable: transferTextureAvailable)
    }
}
