//
//  RenderGraphError.swift
//  MTK
//
//  Explicit render graph validation failures.
//

import Foundation

public enum RenderGraphError: Error, Equatable, LocalizedError, Sendable {
    case unmappedViewportRoute(ViewportType)
    case missingResourceHandle(ViewportID)
    case missingDataset(ViewportID)
    case missingVolumeTexture(ViewportID)
    case missingPresentationSurface(ViewportID)
    case passProducedNoFrame(ViewportID, RenderPassKind)
    case invalidViewportConfiguration(ViewportID, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unmappedViewportRoute(let viewportType):
            return "Viewport route is not mapped for \(String(describing: viewportType))."
        case .missingResourceHandle(let viewportID):
            return "Viewport \(viewportID) has no dataset/resource handle."
        case .missingDataset(let viewportID):
            return "Viewport \(viewportID) could not resolve its dataset from the resource handle."
        case .missingVolumeTexture(let viewportID):
            return "Viewport \(viewportID) could not resolve its shared volume texture."
        case .missingPresentationSurface(let viewportID):
            return "Viewport \(viewportID) has no presentation surface."
        case .passProducedNoFrame(let viewportID, let passKind):
            return "Viewport \(viewportID) finished \(passKind.profilingName) without producing a presentable frame."
        case .invalidViewportConfiguration(let viewportID, let reason):
            return "Viewport \(viewportID) has an invalid render-graph configuration: \(reason)"
        }
    }

    public var failureReason: String? {
        switch self {
        case .unmappedViewportRoute:
            return "Add an explicit route to ViewportRenderGraph before rendering this viewport."
        case .missingResourceHandle:
            return "Attach a dataset/resource handle to the viewport before scheduling rendering."
        case .missingDataset:
            return "Ensure the resource manager still retains the dataset for this viewport."
        case .missingVolumeTexture:
            return "Ensure volume upload/texture preparation completed before rendering."
        case .missingPresentationSurface:
            return "Attach a Metal presentation surface to every active clinical viewport."
        case .passProducedNoFrame:
            return "The route resolved, but the pass output did not match the presentation contract."
        case .invalidViewportConfiguration(_, let reason):
            return reason
        }
    }
}
