import CoreGraphics
import Metal
import XCTest

@testable import MTKCore

final class ViewportRenderGraphTests: XCTestCase {
    private let graph = ViewportRenderGraph()

    func testVolume3DRouteUsesFrontToBackRaycastAndPresentation() throws {
        let route = graph.resolveRoute(for: .volume3D)

        XCTAssertEqual(route.compositing, .frontToBack)
        XCTAssertEqual(route.passPipeline.map(\.kind), [.volumeRaycast, .presentation])
        XCTAssertEqual(route.passPipeline.first?.compositing, .frontToBack)
        XCTAssertEqual(route.passPipeline.first?.inputDependencies,
                       [.volumeTexture, .transferTexture, .outputTexture])
        XCTAssertEqual(route.passPipeline.last?.inputDependencies,
                       [.outputTexture, .presentationTarget])
    }

    func testProjectionRoutesMapEachModeToExplicitRaycastPipeline() throws {
        let expected: [(ViewportType, VolumeRenderRequest.Compositing)] = [
            (.projection(mode: .mip), .maximumIntensity),
            (.projection(mode: .minip), .minimumIntensity),
            (.projection(mode: .aip), .averageIntensity)
        ]

        for (viewportType, compositing) in expected {
            let route = graph.resolveRoute(for: viewportType)
            XCTAssertEqual(route.compositing, compositing)
            XCTAssertEqual(route.passPipeline.map(\.kind), [.volumeRaycast, .presentation])
            XCTAssertEqual(route.passPipeline.first?.compositing, compositing)
        }
    }

    func testResolveRouteIsDeterministicForEachViewportType() {
        let viewportTypes: [ViewportType] = [
            .volume3D,
            .projection(mode: .mip),
            .projection(mode: .minip),
            .projection(mode: .aip),
            .mpr(axis: .axial),
            .mpr(axis: .coronal),
            .mpr(axis: .sagittal)
        ]

        for viewportType in viewportTypes {
            XCTAssertEqual(graph.resolveRoute(for: viewportType),
                           graph.resolveRoute(for: viewportType))
        }
    }

    func testMPRRoutesMapEachAxisToResliceAndMPRPresentation() throws {
        let expected: [(ViewportType, Axis)] = [
            (.mpr(axis: .axial), .axial),
            (.mpr(axis: .coronal), .coronal),
            (.mpr(axis: .sagittal), .sagittal)
        ]

        for (viewportType, axis) in expected {
            let route = graph.resolveRoute(for: viewportType)
            XCTAssertNil(route.compositing)
            XCTAssertEqual(route.passPipeline.map(\.kind), [.mprReslice, .mprPresentation])
            XCTAssertEqual(route.passPipeline.first?.axis, axis)
            XCTAssertEqual(route.passPipeline.first?.inputDependencies,
                           [.volumeTexture, .outputTexture])
            XCTAssertEqual(route.passPipeline.last?.inputDependencies,
                           [.outputTexture, .presentationTarget])
        }
    }

    func testOverlayPipelineIsExplicitlyDefined() {
        let pipeline = graph.overlayPassPipeline()

        XCTAssertEqual(pipeline.map(\.kind), [.overlay, .presentation])
        XCTAssertEqual(pipeline.first?.inputDependencies, [.overlayInputs, .outputTexture])
        XCTAssertEqual(pipeline.last?.inputDependencies, [.outputTexture, .presentationTarget])
    }

    func testBuildRenderNodeFailsWhenResourceHandleIsMissing() {
        let viewportID = ViewportID()
        XCTAssertThrowsError(try graph.buildRenderNode(viewportID: viewportID,
                                                       viewportType: .volume3D,
                                                       resourceHandle: nil)) { error in
            XCTAssertEqual(error as? RenderGraphError, .missingResourceHandle(viewportID))
            XCTAssertTrue((error as NSError).localizedDescription.contains(String(describing: viewportID)))
        }
    }

    func testValidateRenderRequirementsFailsWhenDatasetIsMissing() throws {
        let viewportID = ViewportID()
        let node = try makeNode(viewportID: viewportID, viewportType: .projection(mode: .mip))

        XCTAssertThrowsError(
            try graph.validateRenderRequirements(node: node,
                                                 datasetAvailable: false,
                                                 volumeTextureAvailable: false,
                                                 surfaceAvailable: false)
        ) { error in
            XCTAssertEqual(error as? RenderGraphError, .missingDataset(viewportID))
            XCTAssertTrue((error as NSError).localizedDescription.contains(String(describing: viewportID)))
        }
    }

    func testValidateRenderRequirementsFailsWhenVolumeTextureIsMissing() throws {
        let viewportID = ViewportID()
        let node = try makeNode(viewportID: viewportID, viewportType: .projection(mode: .mip))

        XCTAssertThrowsError(
            try graph.validateRenderRequirements(node: node,
                                                 datasetAvailable: true,
                                                 volumeTextureAvailable: false,
                                                 surfaceAvailable: false)
        ) { error in
            XCTAssertEqual(error as? RenderGraphError, .missingVolumeTexture(viewportID))
            XCTAssertTrue((error as NSError).localizedDescription.contains(String(describing: viewportID)))
        }
    }

    func testValidateRenderRequirementsFailsWhenPresentationSurfaceIsMissing() throws {
        let viewportID = ViewportID()
        let node = try makeNode(viewportID: viewportID, viewportType: .projection(mode: .mip))

        XCTAssertThrowsError(
            try graph.validateRenderRequirements(node: node,
                                                 datasetAvailable: true,
                                                 volumeTextureAvailable: true,
                                                 surfaceAvailable: false)
        ) { error in
            XCTAssertEqual(error as? RenderGraphError, .missingPresentationSurface(viewportID))
            XCTAssertTrue((error as NSError).localizedDescription.contains(String(describing: viewportID)))
        }
    }

    func testValidateRenderRequirementsFailsWhenTransferTextureDependencyIsMissing() throws {
        let viewportID = ViewportID()
        let node = try makeNode(viewportID: viewportID, viewportType: .projection(mode: .mip))

        XCTAssertThrowsError(
            try graph.validateRenderRequirements(node: node,
                                                 datasetAvailable: true,
                                                 volumeTextureAvailable: true,
                                                 surfaceAvailable: true,
                                                 transferTextureAvailable: false)
        ) { error in
            guard case RenderGraphError.invalidViewportConfiguration(let failedViewportID, let reason) = error else {
                return XCTFail("Expected invalidViewportConfiguration, got \(error)")
            }
            XCTAssertEqual(failedViewportID, viewportID)
            XCTAssertTrue(reason.contains("transfer texture"))
            XCTAssertTrue((error as NSError).localizedDescription.contains(String(describing: viewportID)))
        }
    }

    func testValidateRenderRequirementsFailsOnMissingResourceBeforeOtherFlags() {
        let viewportID = ViewportID()
        let node = ViewportRenderNode(viewportID: viewportID,
                                      resolvedRoute: graph.resolveRoute(for: .mpr(axis: .axial)),
                                      resourceHandle: nil)

        XCTAssertThrowsError(
            try graph.validateRenderRequirements(node: node,
                                                 datasetAvailable: true,
                                                 volumeTextureAvailable: true,
                                                 surfaceAvailable: true)
        ) { error in
            XCTAssertEqual(error as? RenderGraphError, .missingResourceHandle(viewportID))
            XCTAssertTrue((error as NSError).localizedDescription.contains(String(describing: viewportID)))
        }
    }

    func testViewportRenderNodeUsesResolvedRouteViewportType() {
        let route = graph.resolveRoute(for: .projection(mode: .mip))
        let node = ViewportRenderNode(viewportID: ViewportID(),
                                      resolvedRoute: route,
                                      resourceHandle: nil)

        XCTAssertEqual(node.viewportType, route.viewportType)
    }

    private func makeNode(viewportID: ViewportID,
                          viewportType: ViewportType) throws -> ViewportRenderNode {
        try graph.buildRenderNode(viewportID: viewportID,
                                  viewportType: viewportType,
                                  resourceHandle: VolumeResourceHandle(rawValue: UUID(),
                                                                      metadata: .init(resourceType: .volume,
                                                                                      debugLabel: nil,
                                                                                      estimatedBytes: 0,
                                                                                      pixelFormat: .invalid,
                                                                                      storageMode: .shared,
                                                                                      dimensions: .init(width: 0,
                                                                                                        height: 0,
                                                                                                        depth: 0))))
    }
}
