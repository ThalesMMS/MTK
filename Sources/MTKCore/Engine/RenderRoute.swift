//
//  RenderRoute.swift
//  MTK
//
//  Explicit routing contract for clinical viewports.
//

import Foundation

public struct RenderRoute: Equatable, Hashable, Sendable {
    public var viewportType: ViewportType
    public var compositing: VolumeRenderRequest.Compositing?
    public var passPipeline: [RenderPassNode]

    public init(viewportType: ViewportType,
                compositing: VolumeRenderRequest.Compositing? = nil,
                passPipeline: [RenderPassNode]) {
        self.viewportType = viewportType
        self.compositing = compositing
        self.passPipeline = passPipeline
    }

    public var primaryPass: RenderPassNode? {
        passPipeline.first
    }

    public var presentationPass: RenderPassNode? {
        passPipeline.last
    }

    public var passPipelineName: String {
        passPipeline.map(\.profilingName).joined(separator: " -> ")
    }
}
