//
//  RenderRoute.swift
//  MTK
//
//  Explicit routing contract for clinical viewports.
//

import Foundation

package struct RenderRoute: Equatable, Hashable, Sendable {
    package var viewportType: ViewportType
    package var compositing: VolumeRenderRequest.Compositing?
    package var passPipeline: [RenderPassNode]

    package init(viewportType: ViewportType,
                compositing: VolumeRenderRequest.Compositing? = nil,
                passPipeline: [RenderPassNode]) {
        self.viewportType = viewportType
        self.compositing = compositing
        self.passPipeline = passPipeline
    }

    package var primaryPass: RenderPassNode? {
        passPipeline.first
    }

    package var presentationPass: RenderPassNode? {
        passPipeline.last
    }

    package var passPipelineName: String {
        passPipeline.map(\.profilingName).joined(separator: " -> ")
    }
}
