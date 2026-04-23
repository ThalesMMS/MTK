//
//  ViewportRenderGraph.swift
//  MTK
//
//  Explicit viewport x render-mode routing for the clinical render pipeline.
//

import Foundation
import os.log

public struct ViewportRenderGraph: Sendable {
    private let logger = os.Logger(subsystem: "com.mtk.rendergraph",
                                   category: "ViewportRenderGraph")

    public init() {}

    public func overlayPassPipeline() -> [RenderPassNode] {
        [
            RenderPassNode(kind: .overlay,
                           inputDependencies: [.overlayInputs, .outputTexture]),
            RenderPassNode(kind: .presentation,
                           inputDependencies: [.outputTexture, .presentationTarget])
        ]
    }

    public func resolveRoute(for viewportType: ViewportType) -> RenderRoute {
        switch viewportType {
        case .volume3D:
            return RenderRoute(
                viewportType: viewportType,
                compositing: .frontToBack,
                passPipeline: [
                    RenderPassNode(kind: .volumeRaycast,
                                   compositing: .frontToBack,
                                   inputDependencies: [.volumeTexture, .transferTexture, .outputTexture]),
                    RenderPassNode(kind: .presentation,
                                   inputDependencies: [.outputTexture, .presentationTarget])
                ]
            )

        case .projection(.mip):
            return RenderRoute(
                viewportType: viewportType,
                compositing: .maximumIntensity,
                passPipeline: [
                    RenderPassNode(kind: .volumeRaycast,
                                   compositing: .maximumIntensity,
                                   inputDependencies: [.volumeTexture, .transferTexture, .outputTexture]),
                    RenderPassNode(kind: .presentation,
                                   inputDependencies: [.outputTexture, .presentationTarget])
                ]
            )

        case .projection(.minip):
            return RenderRoute(
                viewportType: viewportType,
                compositing: .minimumIntensity,
                passPipeline: [
                    RenderPassNode(kind: .volumeRaycast,
                                   compositing: .minimumIntensity,
                                   inputDependencies: [.volumeTexture, .transferTexture, .outputTexture]),
                    RenderPassNode(kind: .presentation,
                                   inputDependencies: [.outputTexture, .presentationTarget])
                ]
            )

        case .projection(.aip):
            return RenderRoute(
                viewportType: viewportType,
                compositing: .averageIntensity,
                passPipeline: [
                    RenderPassNode(kind: .volumeRaycast,
                                   compositing: .averageIntensity,
                                   inputDependencies: [.volumeTexture, .transferTexture, .outputTexture]),
                    RenderPassNode(kind: .presentation,
                                   inputDependencies: [.outputTexture, .presentationTarget])
                ]
            )

        case .mpr(let axis):
            return RenderRoute(
                viewportType: viewportType,
                passPipeline: [
                    RenderPassNode(kind: .mprReslice,
                                   axis: axis,
                                   inputDependencies: [.volumeTexture, .outputTexture]),
                    RenderPassNode(kind: .mprPresentation,
                                   axis: axis,
                                   inputDependencies: [.outputTexture, .presentationTarget])
                ]
            )
        }
    }

    public func buildRenderNode(viewportID: ViewportID,
                                viewportType: ViewportType,
                                resourceHandle: VolumeResourceHandle?) throws -> ViewportRenderNode {
        let route = resolveRoute(for: viewportType)
        logRouteResolution(viewportID: viewportID, route: route)
        let node = ViewportRenderNode(viewportID: viewportID,
                                      resolvedRoute: route,
                                      resourceHandle: resourceHandle)

        guard node.resourceHandle != nil else {
            let error = RenderGraphError.missingResourceHandle(viewportID)
            logValidationFailure(error: error)
            throw error
        }
        return node
    }

    public func validateRenderRequirements(node: ViewportRenderNode,
                                           datasetAvailable: Bool,
                                           volumeTextureAvailable: Bool,
                                           surfaceAvailable: Bool,
                                           transferTextureAvailable: Bool = true) throws {
        guard node.resourceHandle != nil else {
            let error = RenderGraphError.missingResourceHandle(node.viewportID)
            logValidationFailure(error: error)
            throw error
        }
        guard datasetAvailable else {
            let error = RenderGraphError.missingDataset(node.viewportID)
            logValidationFailure(error: error)
            throw error
        }

        for dependency in requiredValidationDependencies(for: node.resolvedRoute) {
            switch dependency {
            case .volumeTexture:
                guard volumeTextureAvailable else {
                    let error = RenderGraphError.missingVolumeTexture(node.viewportID)
                    logValidationFailure(error: error)
                    throw error
                }
            case .transferTexture:
                guard transferTextureAvailable else {
                    let error = RenderGraphError.invalidViewportConfiguration(
                        node.viewportID,
                        reason: "Route \(node.resolvedRoute.profilingName) requires a ready transfer texture."
                    )
                    logValidationFailure(error: error)
                    throw error
                }
            case .presentationTarget:
                guard surfaceAvailable else {
                    let error = RenderGraphError.missingPresentationSurface(node.viewportID)
                    logValidationFailure(error: error)
                    throw error
                }
            case .outputTexture, .overlayInputs:
                continue
            }
        }
    }

    public func logRouteResolution(viewportID: ViewportID, route: RenderRoute) {
        logger.debug("Resolved route viewportID=\(String(describing: viewportID)) viewportType=\(route.viewportType.profilingName) route=\(route.profilingName) pipeline=\(route.passPipelineName)")
    }

    public func logValidationFailure(error: RenderGraphError) {
        logger.warning("Render graph validation failed error=\(error.localizedDescription, privacy: .public)")
    }

    public func validateFrame(_ frame: RenderFrame) throws {
        guard let primaryPass = frame.route.primaryPass else {
            throw RenderGraphError.unmappedViewportRoute(frame.route.viewportType)
        }

        if primaryPass.kind == .mprReslice || primaryPass.inputDependencies.contains(.outputTexture) {
            guard frame.texture.width > 0, frame.texture.height > 0 else {
                throw RenderGraphError.passProducedNoFrame(frame.viewportID, primaryPass.kind)
            }
        }

        switch primaryPass.kind {
        case .volumeRaycast:
            guard frame.mprFrame == nil else {
                throw RenderGraphError.invalidViewportConfiguration(
                    frame.viewportID,
                    reason: "Volume raycast route produced an MPR frame."
                )
            }
            guard frame.outputTextureLease != nil else {
                throw RenderGraphError.passProducedNoFrame(frame.viewportID, primaryPass.kind)
            }

        case .mprReslice:
            guard let mprFrame = frame.mprFrame else {
                throw RenderGraphError.passProducedNoFrame(frame.viewportID, primaryPass.kind)
            }
            guard ObjectIdentifier(frame.texture as AnyObject) == ObjectIdentifier(mprFrame.texture as AnyObject) else {
                throw RenderGraphError.invalidViewportConfiguration(
                    frame.viewportID,
                    reason: "MPR reslice produced a frame whose texture does not match the render output texture."
                )
            }

        case .presentation, .mprPresentation, .overlay:
            throw RenderGraphError.invalidViewportConfiguration(
                frame.viewportID,
                reason: "Primary render pass cannot be \(primaryPass.kind.profilingName)."
            )
        }
    }

    public func validatePresentationSurface(for frame: RenderFrame,
                                            surfaceExists: Bool) throws {
        guard frame.route.presentationPass != nil else {
            throw RenderGraphError.unmappedViewportRoute(frame.route.viewportType)
        }
        guard surfaceExists else {
            let error = RenderGraphError.missingPresentationSurface(frame.viewportID)
            logValidationFailure(error: error)
            throw error
        }
    }
}

private extension ViewportRenderNode {
    var primaryPass: RenderPassNode? {
        resolvedRoute.primaryPass
    }
}

private extension ViewportRenderGraph {
    func requiredValidationDependencies(for route: RenderRoute) -> [RenderNodeDependency] {
        var dependencies: [RenderNodeDependency] = []

        for pass in route.passPipeline {
            var passDependencies = pass.inputDependencies
            if pass.kind == .volumeRaycast,
               !passDependencies.contains(.transferTexture) {
                passDependencies.append(.transferTexture)
            }

            for dependency in passDependencies
            where !dependencies.contains(dependency) {
                dependencies.append(dependency)
            }
        }

        return dependencies
    }
}
