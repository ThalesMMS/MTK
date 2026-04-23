//
//  RenderPassNode.swift
//  MTK
//
//  Explicit render-pass nodes used by ViewportRenderGraph.
//

import Foundation

public enum RenderPassKind: Hashable, Sendable {
    case volumeRaycast
    case mprReslice
    case presentation
    case mprPresentation
    case overlay

    public var profilingName: String {
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

public enum RenderNodeDependency: Hashable, Sendable {
    case volumeTexture
    case transferTexture
    case outputTexture
    case presentationTarget
    case overlayInputs
}

public struct RenderPassNode: Equatable, Hashable, Sendable {
    public var kind: RenderPassKind
    public var compositing: VolumeRenderRequest.Compositing?
    public var axis: Axis?
    public var inputDependencies: [RenderNodeDependency]

    public init(kind: RenderPassKind,
                compositing: VolumeRenderRequest.Compositing? = nil,
                axis: Axis? = nil,
                inputDependencies: [RenderNodeDependency]) {
        self.kind = kind
        self.compositing = compositing
        self.axis = axis
        self.inputDependencies = inputDependencies
    }

    public var profilingName: String {
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
