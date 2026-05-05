//
//  RenderPassNode.swift
//  MTK
//
//  Explicit render-pass nodes used by ViewportRenderGraph.
//

import Foundation

package enum RenderPassKind: Hashable, Sendable {
    case volumeRaycast
    case mprReslice
    case presentation
    case mprPresentation
    case overlay

    package var profilingName: String {
        switch self {
        case .volumeRaycast:
            return "volumeRaycast"
        case .mprReslice:
            return "mprReslice"
        case .presentation:
            return "presentation"
        case .mprPresentation:
            return "mprPresentation"
        case .overlay:
            return "overlay"
        }
    }
}

package enum RenderNodeDependency: Hashable, Sendable {
    case volumeTexture
    case transferTexture
    case outputTexture
    case presentationTarget
    case overlayInputs
}

package struct RenderPassNode: Equatable, Hashable, Sendable {
    package var kind: RenderPassKind
    package var compositing: VolumeRenderRequest.Compositing?
    package var axis: Axis?
    package var inputDependencies: [RenderNodeDependency]

    package init(kind: RenderPassKind,
                compositing: VolumeRenderRequest.Compositing? = nil,
                axis: Axis? = nil,
                inputDependencies: [RenderNodeDependency]) {
        self.kind = kind
        self.compositing = compositing
        self.axis = axis
        self.inputDependencies = inputDependencies
    }

    package var profilingName: String {
        switch kind {
        case .volumeRaycast:
            return "volumeRaycast.\(compositing?.profilingName ?? "unknown")"
        case .mprReslice:
            return "mprReslice.\(axis?.profilingName ?? "unknown")"
        default:
            return kind.profilingName
        }
    }
}
